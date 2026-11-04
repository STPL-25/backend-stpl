// Applies 151 (twice), then its ROLLBACK script, inside one transaction that is always rolled back; checks the data at each step.
//   node sql/_verify_151.mjs      (run from the backend-stpl directory)
import fs from "node:fs/promises";
import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv({ quiet: true });
if (process.env.DATABASE !== "Non_trade_Dev") { console.error("Refusing: not Non_trade_Dev"); process.exit(1); }
const pool = await new sql.ConnectionPool({ user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD, server: process.env.SERVER, database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433, options: { trustServerCertificate: true }, requestTimeout: 120000, pool: { max: 1, min: 0 } }).connect();
const split = (s) => s.split(/^\s*GO\s*$/gim).map((b) => b.trim()).filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));
const up = split(await fs.readFile(new URL("./151_individual_master_screens.sql", import.meta.url), "utf8"));
const down = split(await fs.readFile(new URL("./backups/individual_master_screens_2026-11-04_ROLLBACK.sql", import.meta.url), "utf8"));

let failures = 0;
const check = (label, ok, extra = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${label}${extra ? "  " + extra : ""}`); if (!ok) failures++; };

// user row -> Map(screen_id -> sorted permission list)
const users = async (r) => {
  const rows = (await r.query("SELECT user_perm_json_sno AS id, screens_json FROM dbo.nt_user_permissions_json WHERE is_active = 'Y'")).recordset;
  return new Map(rows.map((x) => [x.id, new Map(JSON.parse(x.screens_json || "[]").map((e) => [e.screen_id, [...(e.permissions ?? [])].sort((a, b) => a - b).join(",")]))]));
};
const childRows = async (r) => (await r.query("SELECT screen_id, screen_name, comp, group_id, is_active, staff_only, parent_screen_id FROM dbo.screens WHERE comp LIKE 'masters.%' ORDER BY display_order")).recordset;

const tx = new sql.Transaction(pool); await tx.begin();
try {
  const R = () => new sql.Request(tx);
  const mastersId = (await R().query("SELECT screen_id FROM dbo.screens WHERE comp = 'masters'")).recordset[0].screen_id;

  const before = await users(R());
  check("before: no per-master rows yet", (await childRows(R())).length === 0);
  const holders = [...before].filter(([, m]) => (m.get(mastersId) ?? "") !== "");
  console.log(`before: ${before.size} active users, ${holders.length} hold "Masters" with permissions`);

  for (const b of up) await R().batch(b);

  const kids = await childRows(R());
  check("after 151: 32 per-master screen rows, all active", kids.length === 32 && kids.every((k) => k.is_active === "Y"));
  check("  names are unique", new Set(kids.map((k) => k.screen_name)).size === 32);
  check("  every name fits the matrix (<= 30 chars)", kids.every((k) => k.screen_name.length <= 30));
  check("  all parented to Masters and in one group", kids.every((k) => k.parent_screen_id === mastersId) && new Set(kids.map((k) => k.group_id)).size === 1);
  check("  staff_only on exactly Terms & Conditions + Product Stock Level",
    kids.filter((k) => k.staff_only === "Y").map((k) => k.comp).sort().join() === "masters.ProductStockLevelMaster,masters.TermsConditionsMaster");

  // every tile in the frontend list has a row
  const data = await fs.readFile(new URL("../../nt-frontend-stpl/src/FieldDatas/Data.tsx", import.meta.url), "utf8");
  const tileIds = [...data.slice(data.indexOf("const masterItems"), data.indexOf("];", data.indexOf("const masterItems")))
    .split("\n").filter((l) => !l.trim().startsWith("//")).join("\n").matchAll(/id: "([A-Za-z]+)"/g)].map((m) => m[1]);
  const have = new Set(kids.map((k) => k.comp.slice("masters.".length)));
  check(`  every Masters-grid tile has a screen row (${tileIds.length} tiles)`, tileIds.every((t) => have.has(t)) && tileIds.length === 32,
    tileIds.filter((t) => !have.has(t)).join(","));

  const grp = (await R().execute("sp_get_screen_groups_with_screens")).recordset.filter((r) => r.group_name === "Individual Masters");
  check("  matrix procedure lists them under 'Individual Masters'", grp.length === 32);

  const after = await users(R());
  let backfillOk = true, untouchedOk = true, bad = [];
  for (const [id, was] of before) {
    const now = after.get(id);
    const mp = was.get(mastersId) ?? "";
    if (mp === "") { if (now.size !== was.size) { untouchedOk = false; bad.push(id); } continue; }
    // original entries preserved, 32 new ones carrying the Masters permissions
    for (const [sid, p] of was) if (now.get(sid) !== p) { backfillOk = false; bad.push(id); }
    for (const k of kids) if (now.get(k.screen_id) !== mp) { backfillOk = false; bad.push(id); }
    if (now.size !== was.size + 32) { backfillOk = false; bad.push(id); }
  }
  check("backfill: each Masters holder gets the 32 rows with the same permissions, nothing else changed", backfillOk, bad.join());
  check("backfill: users without Masters are untouched", untouchedOk, bad.join());

  // sidebar procedure still works and now carries the rows
  const sample = holders[0] && (await R().query(`SELECT ecno, login_id FROM dbo.nt_user_permissions_json WHERE user_perm_json_sno = ${holders[0][0]}`)).recordset[0];
  if (sample) {
    const side = (await R().input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify({ ecno: sample.ecno ?? sample.login_id })).execute("sp_nt_GetUserScreensAndPermissionsJson")).recordset;
    const comps = new Set(side.map((r) => r.comp));
    check(`sidebar procedure for ${sample.ecno ?? sample.login_id} returns the per-master rows`, kids.every((k) => comps.has(k.comp) || k.staff_only === "Y"));
  }

  // idempotent
  for (const b of up) await R().batch(b);
  const again = await users(R());
  check("re-running 151 changes nothing", [...after].every(([id, m]) => [...m].every(([s, p]) => again.get(id).get(s) === p) && again.get(id).size === m.size) && (await childRows(R())).length === 32);

  for (const b of down) await R().batch(b);
  const back = await users(R());
  check("rollback: every user's grants equal the original", [...before].every(([id, m]) => back.get(id).size === m.size && [...m].every(([s, p]) => back.get(id).get(s) === p)));
  check("rollback: per-master rows and group switched off", (await childRows(R())).every((k) => k.is_active === "N")
    && (await R().query("SELECT is_active FROM dbo.screen_group WHERE group_name = N'Individual Masters'")).recordset[0].is_active === "N");
  const grpAfter = (await R().execute("sp_get_screen_groups_with_screens")).recordset.filter((r) => r.group_name === "Individual Masters");
  check("rollback: matrix procedure no longer lists them", grpAfter.length === 0);

  // and back on again
  for (const b of up) await R().batch(b);
  check("re-apply after rollback switches them back on", (await childRows(R())).every((k) => k.is_active === "Y"));
} finally {
  await tx.rollback();
  const left = (await pool.request().query("SELECT COUNT(*) n FROM dbo.screens WHERE comp LIKE 'masters.%'")).recordset[0].n;
  console.log(`rolled back; per-master rows left in the database: ${left}`);
  await pool.close();
}
console.log(failures ? `\n${failures} CHECK(S) FAILED` : "\nALL CHECKS PASSED");
process.exit(failures ? 1 : 0);
