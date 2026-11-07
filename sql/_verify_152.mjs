// Applies 152 (twice), checks the data and the dashboard procedure for several users, then applies the ROLLBACK script and checks
// that too - all inside ONE transaction that is always rolled back, so nothing is left behind.
//   node sql/_verify_152.mjs      (run from the backend-stpl directory)
import fs from "node:fs/promises";
import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv({ quiet: true });
if (process.env.DATABASE !== "Non_trade_Dev") { console.error("Refusing: not Non_trade_Dev"); process.exit(1); }
const pool = await new sql.ConnectionPool({ user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD, server: process.env.SERVER, database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433, options: { trustServerCertificate: true }, requestTimeout: 120000, pool: { max: 1, min: 0 } }).connect();
const split = (s) => s.split(/^\s*GO\s*$/gim).map((b) => b.trim()).filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));
const up = split(await fs.readFile(new URL("./152_org_access_dashboard.sql", import.meta.url), "utf8"));
const down = split(await fs.readFile(new URL("./backups/org_access_dashboard_2026-11-04_ROLLBACK.sql", import.meta.url), "utf8"));

let failures = 0;
const check = (label, ok, extra = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${label}${extra ? "  " + extra : ""}`); if (!ok) failures++; };

const permRows = async (r) => (await r.query("SELECT user_perm_json_sno AS id, ecno, login_id, hierarchy_json, screens_json, CONVERT(VARCHAR(30), updated_date, 126) AS upd FROM dbo.nt_user_permissions_json WHERE is_active = 'Y'")).recordset;
const callDash = async (R, actor) => {
  const rq = R(); rq.input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify({ ecno: actor }));
  const res = await rq.execute("sp_nt_GetOrgAccessDashboard");
  const [meta, nodes, nodeUsers, users, grants, unassigned] = res.recordsets;
  return { meta: meta[0], nodes, nodeUsers, users, grants, unassigned };
};

// ── independent re-implementation (JS) of "latest row per identity, overlap/cover" ──
const latestPerIdent = (rows) => {
  const m = new Map();
  for (const r of rows) { const id = r.ecno ?? r.login_id; if (!id) continue; const k = id.toLowerCase(); if (!m.has(k) || m.get(k).id < r.id) m.set(k, { ...r, ident: id }); }
  return [...m.values()];
};
const grantsOf = (row) => JSON.parse(row.hierarchy_json || "[]").filter((h) => h.com_sno != null).map((h) => ({
  com: +h.com_sno, div: h.div_sno == null ? null : +h.div_sno, brn: h.brn_sno == null ? null : +h.brn_sno, dept: h.dept_sno == null ? null : +h.dept_sno }));
const overlaps = (g, n) => g.com === n.com && (g.div == null || n.div == null || g.div === n.div) && (g.brn == null || n.brn == null || g.brn === n.brn) && (g.dept == null || n.dept == null || g.dept === n.dept);
const covers = (g, n) => g.com === n.com && (g.div == null || g.div === n.div) && (g.brn == null || g.brn === n.brn) && (g.dept == null || g.dept === n.dept);

const tx = new sql.Transaction(pool); await tx.begin();
try {
  const R = () => new sql.Request(tx);

  const before = await permRows(R());
  check("before: dashboard screen not present", (await R().query("SELECT 1 x FROM dbo.screens WHERE comp = 'OrgDashboard'")).recordset.length === 0);

  for (const b of up) await R().batch(b);
  for (const b of up) await R().batch(b);   // second run: must be a no-op

  const scr = (await R().query("SELECT screen_id, screen_name, comp, comp_img, group_id, display_order, is_active, staff_only FROM dbo.screens WHERE comp = 'OrgDashboard'")).recordset;
  check("after 152 (x2): exactly one Dashboard screen", scr.length === 1, JSON.stringify(scr));
  const S = scr[0];
  check("  active, icon LayoutDashboard, display_order 0, not staff-only", S.is_active === "Y" && S.comp_img === "LayoutDashboard" && S.display_order === 0 && S.staff_only === "N");
  const minOrder = (await R().query("SELECT MIN(display_order) m FROM dbo.screens WHERE is_active = 'Y' AND comp <> 'OrgDashboard'")).recordset[0].m;
  check(`  sorts before every other active screen (next lowest is ${minOrder})`, S.display_order < minOrder);
  const grp = (await R().query(`SELECT group_id, group_name FROM dbo.screen_group WHERE group_name = N'Dashboard'`)).recordset;
  check("  one 'Dashboard' group, and the screen belongs to it", grp.length === 1 && grp[0].group_id === S.group_id);

  const after = await permRows(R());
  const hasScr = (r) => JSON.parse(r.screens_json || "[]").filter((e) => e.screen_id === S.screen_id);
  check("every active user holds the screen exactly once, with View (2) only", after.every((r) => { const e = hasScr(r); return e.length === 1 && e[0].permissions.join() === "2"; }));
  const preserved = after.every((a) => { const b = before.find((x) => x.id === a.id); const keep = JSON.parse(a.screens_json).filter((e) => e.screen_id !== S.screen_id); return JSON.stringify(keep) === JSON.stringify(JSON.parse(b.screens_json || "[]")); });
  check("  every other screen entry is untouched", preserved);
  check("  hierarchy_json and updated_date are untouched", after.every((a) => { const b = before.find((x) => x.id === a.id); return a.hierarchy_json === b.hierarchy_json && a.upd === b.upd; }));

  // sidebar procedure: Dashboard first, in its own group
  for (const who of ["KTM1006", "KTM1004", "NSU00002"]) {
    const row = after.find((r) => (r.ecno ?? r.login_id)?.toLowerCase() === who.toLowerCase());
    if (!row) { console.log(`skip  sidebar for ${who}: no active row`); continue; }
    const rq = R(); rq.input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify({ ecno: who }));
    const sb = (await rq.execute("sp_nt_GetUserScreensAndPermissionsJson")).recordset;
    check(`sidebar for ${who}: first row is the Dashboard (group 'Dashboard')`, sb.length > 0 && sb[0].comp === "OrgDashboard" && sb[0].group_name === "Dashboard", sb[0] && `${sb[0].comp}/${sb[0].group_name}`);
    // the frontend lists groups in first-seen order, so the first-seen group must be the Dashboard group
    const firstGroup = sb[0]?.group_id; const seen = []; for (const r of sb) if (!seen.includes(r.group_id)) seen.push(r.group_id);
    check(`  ${who}: the Dashboard group is listed first`, seen[0] === S.group_id && firstGroup === S.group_id);
  }

  // ── the dashboard procedure vs. an independent computation ──
  const latest = latestPerIdent(after);
  const nodesAll = [
    ...(await R().query("SELECT com_sno com, NULL div, NULL brn, NULL dept, com_name nm, is_active a FROM dbo.company_master")).recordset.map((r) => ({ ...r, lvl: "company" })),
    ...(await R().query("SELECT com_sno com, div_sno div, NULL brn, NULL dept, div_name nm, is_active a FROM dbo.division_master")).recordset.map((r) => ({ ...r, lvl: "division" })),
    ...(await R().query("SELECT com_sno com, div_sno div, brn_sno brn, NULL dept, brn_name nm, is_active a FROM dbo.branch_master")).recordset.map((r) => ({ ...r, lvl: "branch" })),
    ...(await R().query("SELECT com_sno com, div_sno div, brn_sno brn, dept_sno dept, dept_name nm, is_active a FROM dbo.dept_master")).recordset.map((r) => ({ ...r, lvl: "department" })),
  ];
  const key = (n) => `${n.lvl}:${n.com}:${n.div ?? ""}:${n.brn ?? ""}:${n.dept ?? ""}`;
  const isAdminJs = async (row) => {
    const ra = (await R().query("SELECT screen_id FROM dbo.screens WHERE comp = 'RoleApproval'")).recordset[0]?.screen_id;
    return JSON.parse(row.screens_json || "[]").some((e) => e.screen_id === ra && e.permissions.includes(2));
  };

  for (const who of ["KTM1006", "KTM1004", "KTM1148", "NSU00002", "SNV11056"]) {
    const me = latest.find((r) => r.ident.toLowerCase() === who.toLowerCase());
    if (!me) { console.log(`skip  dashboard for ${who}: no active row`); continue; }
    const d = await callDash(R, who);
    const myG = grantsOf(me);
    const admin = await isAdminJs(me);
    const vis = nodesAll.filter((n) => myG.some((g) => overlaps(g, n)));
    const visIdents = latest.filter((p) => p.ident.toLowerCase() === who.toLowerCase() || (admin && grantsOf(p).some((g) => myG.some((m) => overlaps(m, { com: g.com, div: g.div, brn: g.brn, dept: g.dept })))));
    const visIdentSet = new Set(visIdents.filter((p) => grantsOf(p).length > 0).map((p) => p.ident.toLowerCase()));

    check(`${who}: is_admin = ${admin}`, !!d.meta.is_admin === admin);
    check(`${who}: sees exactly the overlapping org nodes (${vis.length})`, d.nodes.length === vis.length && d.nodes.every((n) => vis.some((v) => key({ ...v }) === `${n.node_level}:${n.com_sno}:${n.div_sno ?? ""}:${n.brn_sno ?? ""}:${n.dept_sno ?? ""}`)));
    check(`${who}: sees the right users (${visIdentSet.size})`, d.users.length === visIdentSet.size && d.users.every((u) => visIdentSet.has(u.ident.toLowerCase())),
      `got ${d.users.map((u) => u.ident).join()}`);
    if (!admin) check(`${who}: non-admin sees only themselves`, d.users.length <= 1 && d.users.every((u) => u.is_me === 1) && d.unassigned.length === 0);

    let countsOk = true, why = "";
    for (const n of d.nodes) {
      const nn = { com: n.com_sno, div: n.div_sno, brn: n.brn_sno, dept: n.dept_sno };
      const reaching = [...visIdentSet].filter((id) => grantsOf(latest.find((p) => p.ident.toLowerCase() === id)).some((g) => overlaps(g, nn)));
      const full = reaching.filter((id) => grantsOf(latest.find((p) => p.ident.toLowerCase() === id)).some((g) => covers(g, nn)));
      if (n.users_total !== reaching.length || n.users_full !== full.length) { countsOk = false; why = `${n.node_level} ${n.node_name}: got ${n.users_total}/${n.users_full}, want ${reaching.length}/${full.length}`; break; }
      const pairs = d.nodeUsers.filter((p) => p.node_id === n.node_id);
      if (pairs.length !== reaching.length) { countsOk = false; why = `pairs for ${n.node_name}`; break; }
      if (n.in_my_access !== (myG.some((g) => covers(g, nn)) ? 1 : 0)) { countsOk = false; why = `in_my_access ${n.node_name}`; break; }
    }
    check(`${who}: users_total / users_full / in_my_access match the independent calculation`, countsOk, why);
    check(`${who}: grants listed = distinct hierarchy rows of the visible users`,
      d.grants.length === [...visIdentSet].reduce((s, id) => s + new Set(grantsOf(latest.find((p) => p.ident.toLowerCase() === id)).map((g) => `${g.com}|${g.div}|${g.brn}|${g.dept}`)).size, 0));
    console.log(`      ${who}: ${d.nodes.length} nodes, ${d.users.length} users, ${d.grants.length} grants, ${d.unassigned.length} unassigned, screens ${d.meta.my_screen_count}, name "${d.meta.my_name}", now ${d.meta.server_now}`);
  }

  // unknown identity -> nothing, no error
  const none = await callDash(R, "NO_SUCH_USER");
  check("unknown identity: fail-closed (no nodes, no users, not admin)", none.nodes.length === 0 && none.users.length === 0 && !none.meta.is_admin);
  const blank = await callDash(R, "");
  check("blank identity: fail-closed", blank.nodes.length === 0 && blank.users.length === 0 && !blank.meta.is_admin);

  // redundant grants are flagged, not dropped
  const k = await callDash(R, "KTM1148");
  const redundant = k.grants.filter((g) => g.ident === "KTM1148" && g.is_effective === 0);
  console.log(`      KTM1148: ${k.grants.filter((g) => g.ident === "KTM1148").length} grants, ${redundant.length} flagged covered-by-broader`);
  check("KTM1148 (company-wide grant + narrower rows): narrower rows flagged is_effective = 0", redundant.length > 0 && k.grants.filter((g) => g.ident === "KTM1148" && g.node_level === "company").every((g) => g.is_effective === 1));

  // ── rollback script ──
  for (const b of down) await R().batch(b);
  for (const b of down) await R().batch(b);   // idempotent
  check("after ROLLBACK: screen, group and procedure are gone",
    (await R().query("SELECT 1 x FROM dbo.screens WHERE comp = 'OrgDashboard'")).recordset.length === 0
    && (await R().query("SELECT 1 x FROM dbo.screen_group WHERE group_name = N'Dashboard'")).recordset.length === 0
    && (await R().query("SELECT OBJECT_ID('dbo.sp_nt_GetOrgAccessDashboard') o")).recordset[0].o === null);
  const restored = await permRows(R());
  check("after ROLLBACK: every user's screens are back to what they were", restored.every((a) => { const b = before.find((x) => x.id === a.id); return JSON.stringify(JSON.parse(a.screens_json || "[]")) === JSON.stringify(JSON.parse(b.screens_json || "[]")); }));
} catch (e) {
  failures++; console.log("ERROR  ", e.message);
} finally {
  await tx.rollback();
  console.log("\n(transaction rolled back - nothing was changed)");
}
const left = (await pool.request().query("SELECT (SELECT COUNT(*) FROM dbo.screens WHERE comp = 'OrgDashboard') s, OBJECT_ID('dbo.sp_nt_GetOrgAccessDashboard') p")).recordset[0];
console.log(`after rollback, in the database: screen rows = ${left.s}, procedure = ${left.p === null ? "absent" : "PRESENT"}`);
await pool.close();
console.log(failures ? `\n${failures} FAILURE(S)` : "\nALL CHECKS PASSED");
process.exit(failures ? 1 : 0);
