/**
 * Verifies the ROLLBACK scripts of backend sql/157 + grn sql/96 WITHOUT touching the database for good: apply both migrations,
 * roll them back, and compare with the original definitions (saved in the backups folders). Every case is its own transaction that
 * is always rolled back.   cd backend-stpl && node sql/_verify_157_rollback.mjs
 */
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sql from "mssql";
import { configDotenv } from "dotenv";

configDotenv({ quiet: true });
const here = path.dirname(fileURLToPath(import.meta.url));
if (!/dev/i.test(process.env.DATABASE ?? "")) { console.error(`Refusing to run: DATABASE is "${process.env.DATABASE}"`); process.exit(2); }
const pool = await new sql.ConnectionPool({
  user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD, server: process.env.SERVER,
  database: process.env.DATABASE, port: parseInt(process.env.DB_PORT) || 1433,
  options: { trustServerCertificate: true, enableArithAbort: true }, requestTimeout: 120000,
}).connect();
console.log(`Database: ${process.env.DATABASE} (every change is rolled back)\n`);

const batchesOf = (t) => t.split(/^\s*GO\s*$/gim).map((b) => b.trim()).filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));
const read = (...p) => fs.readFile(path.join(here, ...p), "utf8");
const A = batchesOf(await read("157_statutory_due_agreement.sql"));
const B = batchesOf(await fs.readFile(path.join(here, "..", "..", "grn-service", "sql", "96_statutory_agreement_dues.sql"), "utf8"));
const RA = batchesOf(await read("backups", "statutory_due_agreement_2026-11-07", "ROLLBACK.sql"));
const RB = batchesOf(await fs.readFile(path.join(here, "..", "..", "grn-service", "sql", "backups", "statutory_agreement_dues_2026-11-07", "ROLLBACK.sql"), "utf8"));
const origB = path.join(here, "backups", "statutory_due_agreement_2026-11-07");
const origG = path.join(here, "..", "..", "grn-service", "sql", "backups", "statutory_agreement_dues_2026-11-07");

let failures = 0;
const check = (ok, label, extra = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${label}${extra ? `  ${extra}` : ""}`); if (!ok) failures += 1; };
const norm = (t) => t.replace(/^﻿/, "").replace(/\r\n/g, "\n").replace(/CREATE\s+(OR\s+ALTER\s+)?PROCEDURE/i, "CREATE PROCEDURE").trim();

async function inTx(fn) {
  const tx = new sql.Transaction(pool);
  await tx.begin();
  const q = (t) => new sql.Request(tx).query(t);
  const sp = (name, json) => { const r = new sql.Request(tx); r.input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify(json)); return r.execute(name); };
  try { await fn({ q, sp }); } catch (e) { check(false, "unexpected error", e.message); } finally { try { await tx.rollback(); } catch { /* ended */ } }
}

const before = {};
for (const n of ["sp_nt_CreateServiceAgreement", "sp_nt_UpdateServiceAgreement", "sp_nt_SnapshotServiceAgreementVersion", "sp_nt_GetAgreementsDueForNotification", "sp_nt_GetStatutoryPayables", "sp_nt_CancelStatutoryPayable"]) {
  before[n] = (await pool.request().query(`SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.${n}')) d`)).recordset[0].d;
}
const state = async (q) => (await q(`SELECT
  (SELECT is_nullable FROM sys.columns WHERE object_id = OBJECT_ID('service_agreement') AND name = 'vendor_sno') AS vendor_nullable,
  (SELECT is_active FROM service_type_master WHERE service_type_code = 'STATUTORY') AS type_active,
  (SELECT COUNT(*) FROM service_master WHERE service_code IN ('STAT-PF','STAT-ESI','STAT-PT','STAT-PROP','STAT-EB')) AS due_services,
  (SELECT COUNT(*) FROM service_master WHERE service_code IN ('STAT-PF','STAT-ESI','STAT-PT','STAT-PROP','STAT-EB') AND is_active = 'Y') AS due_services_on,
  OBJECT_ID('dbo.statutory_agreement_cycle') AS cycle_t, OBJECT_ID('dbo.service_agreement_statutory_due') AS due_t,
  OBJECT_ID('dbo.sp_nt_SyncStatutoryAgreementDues') AS p1, OBJECT_ID('dbo.sp_nt_EnterStatutoryAgreementAmount') AS p2, OBJECT_ID('dbo.sp_nt_SkipStatutoryAgreementCycle') AS p3,
  OBJECT_ID('dbo.sp_nt_SaveServiceAgreementStatutoryDue') AS p4, OBJECT_ID('dbo.sp_nt_GetServiceAgreementStatutoryDues') AS p5,
  COL_LENGTH('dbo.statutory_payable', 'cycle_sno') AS cycle_col,
  (SELECT STRING_AGG(definition, ' ; ') FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID('statutory_payable') AND definition LIKE '%source_type%') AS source_ck`)).recordset[0];

await inTx(async ({ q }) => {
  const s0 = await state(q);
  for (const b of A) await q(b);
  for (const b of B) await q(b);
  const s1 = await state(q);
  check(s1.due_t !== null && s1.cycle_t !== null && s1.type_active === "Y" && s1.cycle_col !== null, "both migrations applied inside the transaction");
  for (const b of RB) await q(b);
  for (const b of RA) await q(b);
  const s2 = await state(q);
  check(s2.cycle_t === null && s2.due_t === null && !s2.p1 && !s2.p2 && !s2.p3 && !s2.p4 && !s2.p5, "tables and new procedures are gone");
  check(s2.cycle_col === null, "statutory_payable.cycle_sno is gone");
  check(s2.vendor_nullable === s0.vendor_nullable && s2.vendor_nullable === false, "service_agreement.vendor_sno is NOT NULL again");
  check(s2.type_active === s0.type_active && s2.type_active === "N", "STATUTORY type is off again");
  check(s2.due_services_on === 0 && s2.due_services === 5, "the 5 due services are switched off (kept, so nothing is deleted)", `(${s2.due_services} kept, ${s2.due_services_on} on)`);
  check(/TDS/.test(s2.source_ck) && /MANUAL/.test(s2.source_ck) && !/AGREEMENT/.test(s2.source_ck), "source_type check is back to TDS / MANUAL", s2.source_ck);
  for (const n of Object.keys(before)) {
    const now = (await q(`SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.${n}')) d`)).recordset[0].d;
    check(norm(now) === norm(before[n]), `${n} is exactly the original again`);
  }
  // the saved originals are the live ones (sanity: the backup files match what was live before the change)
  for (const [dir, n] of [[origB, "sp_nt_CreateServiceAgreement"], [origB, "sp_nt_SnapshotServiceAgreementVersion"], [origG, "sp_nt_GetStatutoryPayables"]]) {
    check(norm(await fs.readFile(path.join(dir, `${n}.sql`), "utf8")) === norm(before[n]), `backup file of ${n} equals the live definition`);
  }
  // re-applying after a rollback works (re-runnable)
  for (const b of A) await q(b);
  for (const b of B) await q(b);
  const s3 = await state(q);
  check(s3.due_t !== null && s3.cycle_t !== null && /AGREEMENT/.test(s3.source_ck) && !/tds_manual/i.test(s3.source_ck ?? "") , "re-applying after a rollback works", s3.source_ck);
});

// refusals
const fixture = async ({ q, sp }) => {
  for (const b of A) await q(b);
  for (const b of B) await q(b);
  const svc = (await q("SELECT service_sno s FROM service_master WHERE service_code = 'STAT-PF'")).recordset[0].s;
  const monthly = (await q("SELECT recurrence_cadence_sno r FROM recurrence_cadence_master WHERE cadence_code = 'MONTHLY'")).recordset[0].r;
  return (await sp("sp_nt_CreateServiceAgreement", {
    com_sno: 1, div_sno: 1, brn_sno: 1, dept_sno: 1, service_sno: svc, qty: 1, rate_amount: 100, recurrence_cadence_sno: monthly, po_generation_day: 5,
    period_start_date: "2026-11-01", period_end_date: "2027-10-31", created_by: "KTM1148", statutory_due: { kind: "OTHER", amount_type: "FIXED" },
  })).recordset[0];
};
await inTx(async ({ q, sp }) => {
  await fixture({ q, sp });
  try { for (const b of RB) await q(b); check(true, "grn rollback with no posted amounts runs (only a pending agreement exists)"); } catch (e) { check(false, "grn rollback", e.message); }
  try { for (const b of RA) await q(b); check(false, "backend rollback refused while a Statutory due agreement exists", "it ran"); }
  catch (e) { check(e.number === 58198, "backend rollback refused while a Statutory due agreement exists", `-> ${e.number}`); }
});
await inTx(async ({ q, sp }) => {
  await fixture({ q, sp });
  try { for (const b of RA) await q(b); check(false, "backend rollback refused while grn sql/96 is still applied", "it ran"); }
  catch (e) { check(e.number === 58197, "backend rollback refused while grn sql/96 is still applied (order)", `-> ${e.number}`); }
});
await inTx(async ({ q }) => {
  for (const b of A) await q(b);
  for (const b of B) await q(b);
  await q(`INSERT INTO statutory_payable (kind, source_type, com_sno, head_name, amount, due_date, created_by) VALUES ('OTHER', 'AGREEMENT', 1, 'x', 10, GETDATE(), 'test')`);
  try { for (const b of RB) await q(b); check(false, "grn rollback refused while an amount from an agreement exists", "it ran"); }
  catch (e) { check(e.number === 57285, "grn rollback refused while an amount from an agreement exists", `-> ${e.number}`); }
});

const after = await state((t) => pool.request().query(t));
check(after.due_t === null && after.cycle_t === null && after.type_active === "N", "after the run the database is exactly as before");
await pool.close();
console.log(failures ? `\n${failures} FAILED` : "\nAll checks passed");
process.exit(failures ? 1 : 0);
