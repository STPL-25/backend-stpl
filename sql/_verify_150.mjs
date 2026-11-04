// Dry run of sql/150 (+ its rollback) inside ONE transaction that is always rolled back. Non_trade_Dev only.
import fs from "node:fs/promises"; import sql from "mssql"; import { configDotenv } from "dotenv"; configDotenv();
if (process.env.DATABASE !== "Non_trade_Dev") { console.error("Refusing: not Non_trade_Dev"); process.exit(1); }
const pool = await new sql.ConnectionPool({ user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD, server: process.env.SERVER, database: process.env.DATABASE, port: parseInt(process.env.DB_PORT) || 1433, options: { trustServerCertificate: true }, requestTimeout: 120000, pool: { max: 1, min: 0 } }).connect();
const split = (s) => s.split(/^\s*GO\s*$/gim).map((b) => b.trim()).filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));
const up = split(await fs.readFile(new URL("./150_payment_bank_format_required.sql", import.meta.url), "utf8"));
const down = split(await fs.readFile(new URL("./backups/payment_bank_format_required_2026-11-03_ROLLBACK.sql", import.meta.url), "utf8"));
const tx = new sql.Transaction(pool); await tx.begin();
let pass = 0, fail = 0; const ok = (n, c, x = "") => { c ? pass++ : fail++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${c ? "" : "  " + x}`); };
const q = async (t) => (await new sql.Request(tx).query(t)).recordset;
const call = (p, o) => new sql.Request(tx).input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify(o)).execute(p);
const rejects = async (n, p, o, code) => { try { await call(p, o); ok(n, false, "no error"); } catch (e) { ok(n, e.number === code, `${e.number} ${e.message}`); } };
try {
  const std = (await q("SELECT format_sno FROM dbo.bank_file_format WHERE format_name = N'Standard 28-position (NEFT / RTGS)'"))[0].format_sno;
  const before = (await q("SELECT COUNT(*) n FROM dbo.payment_bank_master WHERE is_active='Y' AND file_format_sno IS NULL"))[0].n;
  console.log("active accounts without a format before:", before);
  for (const b of up) await new sql.Request(tx).batch(b);
  ok("every active account now has a format", (await q("SELECT COUNT(*) n FROM dbo.payment_bank_master WHERE is_active='Y' AND file_format_sno IS NULL"))[0].n === 0);
  ok("backfilled accounts got the standard format", (await q(`SELECT COUNT(*) n FROM dbo.payment_bank_master WHERE modified_by='SQL150' AND file_format_sno <> ${std}`))[0].n === 0);
  const org = (await q("SELECT TOP 1 c.com_sno, d.div_sno, b.brn_sno FROM dbo.company_master c JOIN dbo.division_master d ON d.com_sno = c.com_sno AND ISNULL(d.is_active,'Y')='Y' JOIN dbo.branch_master b ON b.div_sno = d.div_sno AND ISNULL(b.is_active,'Y')='Y' ORDER BY c.com_sno"))[0];
  const mk = { ...org, profile_name: "ZZ new", bank_name: "B", ac_holder_name: "H", ac_number: "99887766554433", ifsc: "TEST0000001", file_prefix: "ZZ", client_code: "ZZ1", file_code: 100 };
  await rejects("a new account without a format is refused", "sp_nt_CreatePaymentBankRecords", mk, 59219);
  const c = (await call("sp_nt_CreatePaymentBankRecords", { ...mk, file_format_sno: std })).recordset[0];
  ok("a new account with a format is created", c.file_format_sno === std);
  await rejects("clearing the format is refused", "sp_nt_UpdatePaymentBankRecords", { id: c.payment_bank_sno, file_format_sno: "" }, 59219);
  const u = (await call("sp_nt_UpdatePaymentBankRecords", { id: c.payment_bank_sno, bank_name: "Renamed" })).recordset[0];
  ok("editing other fields keeps the format", u.file_format_sno === std && u.bank_name === "Renamed");
  for (const b of down) await new sql.Request(tx).batch(b);
  const r = (await call("sp_nt_UpdatePaymentBankRecords", { id: c.payment_bank_sno, file_format_sno: "" })).recordset[0];
  ok("after the rollback script the format can be cleared again", r.file_format_sno === null);
} catch (e) { fail++; console.error("ERROR", e.message); }
finally { await tx.rollback(); const a = (await pool.request().query("SELECT COUNT(*) n FROM dbo.payment_bank_master WHERE file_format_sno IS NOT NULL")).recordset[0].n; console.log(`rolled back; accounts with a format in the database now: ${a}`); console.log(`${pass} passed, ${fail} failed`); await pool.close(); process.exit(fail ? 1 : 0); }
