/**
 * Dry run of sql/149_bank_file_format_master.sql: applies it and checks the new procedures inside ONE transaction that is ALWAYS
 * rolled back, so nothing stays in the database. Run from backend-stpl:   node sql/_verify_149.mjs
 * Refuses to run against anything but Non_trade_Dev.
 */
import fs from "node:fs/promises";
import sql from "mssql";
import { configDotenv } from "dotenv";

configDotenv();
if (process.env.DATABASE !== "Non_trade_Dev") { console.error(`Refusing: DATABASE is ${process.env.DATABASE}, not Non_trade_Dev`); process.exit(1); }

const pool = await new sql.ConnectionPool({
  user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD, server: process.env.SERVER, database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433, options: { trustServerCertificate: true, enableArithAbort: true },
  connectionTimeout: 15000, requestTimeout: 120000, pool: { max: 1, min: 0 },
}).connect();

const script = await fs.readFile(new URL("./149_bank_file_format_master.sql", import.meta.url), "utf8");
const batches = script.split(/^\s*GO\s*$/gim).map((b) => b.trim()).filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));

const tx = new sql.Transaction(pool);
await tx.begin();
let pass = 0, fail = 0;
const ok = (name, cond, extra = "") => { (cond ? pass++ : fail++); console.log(`${cond ? "PASS" : "FAIL"}  ${name}${cond ? "" : "  " + extra}`); };
const call = (proc, obj) => new sql.Request(tx).input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify(obj)).execute(proc);
const rejects = async (name, proc, obj, code) => {
  try { await call(proc, obj); ok(name, false, "no error"); }
  catch (e) { ok(name, e.number === code, `got ${e.number}: ${e.message}`); }
};

try {
  for (const [i, b] of batches.entries()) {
    try { await new sql.Request(tx).batch(b); } catch (e) { console.error(`batch ${i + 1} failed: ${e.message}`); throw e; }
  }
  console.log(`applied ${batches.length} batches inside the transaction\n`);

  const q = async (text) => (await new sql.Request(tx).query(text)).recordset;
  const seed = (await q("SELECT format_sno FROM dbo.bank_file_format WHERE format_name = N'Standard 28-position (NEFT / RTGS)'"))[0];
  ok("built-in layout seeded", !!seed);
  ok("seeded layout has 28 columns", (await q(`SELECT COUNT(*) n FROM dbo.bank_file_format_column WHERE format_sno = ${seed.format_sno}`))[0].n === 28);
  ok("list shows column_count", (await call("sp_nt_GetBankFileFormatRecords", {})).recordset.find((r) => r.format_sno === seed.format_sno)?.column_count === 28);

  // format create / update
  const f = (await call("sp_nt_CreateBankFileFormatRecords", { format_name: "Test pipe bank", delimiter: "pipe", has_header: "Y", created_by: "TEST" })).recordset[0];
  ok("create format (defaults + upper-cased separator)", f.delimiter === "PIPE" && f.has_header === "Y" && f.line_ending === "LF" && f.quote_text === "N");
  await rejects("duplicate format name refused", "sp_nt_CreateBankFileFormatRecords", { format_name: "Test pipe bank" }, 59235);
  await rejects("bad separator refused", "sp_nt_CreateBankFileFormatRecords", { format_name: "X1", delimiter: "DOT" }, 59233);
  await rejects("bad line ending refused", "sp_nt_CreateBankFileFormatRecords", { format_name: "X2", line_ending: "CR" }, 59234);
  await rejects("name required", "sp_nt_CreateBankFileFormatRecords", { delimiter: "COMMA" }, 59231);
  const u = (await call("sp_nt_UpdateBankFileFormatRecords", { id: f.format_sno, line_ending: "crlf", remarks: "hello" })).recordset[0];
  ok("update format (partial)", u.line_ending === "CRLF" && u.remarks === "hello" && u.delimiter === "PIPE");
  const u2 = (await call("sp_nt_UpdateBankFileFormatRecords", { id: f.format_sno, remarks: "" })).recordset[0];
  ok("update can clear remarks", u2.remarks === null);
  await rejects("update unknown format", "sp_nt_UpdateBankFileFormatRecords", { id: 99999999, format_name: "Z" }, 59236);

  // columns
  const col = (over) => ({ format_sno: f.format_sno, created_by: "TEST", ...over });
  const c1 = (await call("sp_nt_CreateBankFileFormatColumnRecords", col({ position: 1, source_field: "account_no", header_text: "A/c" }))).recordset[0];
  ok("create column (upper-cased source, joined format name)", c1.source_field === "ACCOUNT_NO" && c1.format_name === "Test pipe bank");
  await rejects("same position twice refused", "sp_nt_CreateBankFileFormatColumnRecords", col({ position: 1, source_field: "AMOUNT" }), 59245);
  await rejects("unknown source refused", "sp_nt_CreateBankFileFormatColumnRecords", col({ position: 2, source_field: "NOPE" }), 59240);
  await rejects("FIXED without text refused", "sp_nt_CreateBankFileFormatColumnRecords", col({ position: 2, source_field: "FIXED" }), 59241);
  await rejects("padding without character refused", "sp_nt_CreateBankFileFormatColumnRecords", col({ position: 2, source_field: "AMOUNT", max_len: 10, pad_side: "L" }), 59243);
  await rejects("padding without max length refused", "sp_nt_CreateBankFileFormatColumnRecords", col({ position: 2, source_field: "AMOUNT", pad_side: "L", pad_char: "0" }), 59243);
  await rejects("bad date format refused", "sp_nt_CreateBankFileFormatColumnRecords", col({ position: 2, source_field: "PAYMENT_DATE", date_format: "MM/DD/YY" }), 59244);
  await rejects("position 0 refused", "sp_nt_CreateBankFileFormatColumnRecords", col({ position: 0, source_field: "AMOUNT" }), 59239);
  await rejects("unknown format refused", "sp_nt_CreateBankFileFormatColumnRecords", col({ format_sno: 99999999, position: 3, source_field: "AMOUNT" }), 59236);
  const c2 = (await call("sp_nt_CreateBankFileFormatColumnRecords", col({ position: 2, source_field: "AMOUNT", max_len: 12, pad_side: "l", pad_char: "0" }))).recordset[0];
  ok("create padded column", c2.pad_side === "L" && c2.pad_char === "0" && c2.max_len === 12);
  const c3 = (await call("sp_nt_CreateBankFileFormatColumnRecords", col({ position: 3, source_field: "PAYMENT_DATE", date_format: "yyyymmdd" }))).recordset[0];
  ok("create date column (date format upper-cased)", c3.date_format === "YYYYMMDD");
  const arr = (await call("sp_nt_CreateBankFileFormatColumnRecords", [col({ position: 4, source_field: "IFSC" }), col({ position: 5, source_field: "BLANK" })])).recordset;
  ok("create several columns in one call (Excel import)", arr.length === 2);
  const cu = (await call("sp_nt_UpdateBankFileFormatColumnRecords", { id: c2.column_sno, max_len: 15 })).recordset[0];
  ok("update column keeps padding", cu.max_len === 15 && cu.pad_side === "L" && cu.pad_char === "0");
  const cu2 = (await call("sp_nt_UpdateBankFileFormatColumnRecords", { id: c2.column_sno, pad_side: "" })).recordset[0];
  ok("clearing the pad side clears the pad character too", cu2.pad_side === null && cu2.pad_char === null);
  await rejects("update to a position another column has", "sp_nt_UpdateBankFileFormatColumnRecords", { id: c2.column_sno, position: 1 }, 59245);
  ok("column list is ordered and has the format name", (await call("sp_nt_GetBankFileFormatColumnRecords", {})).recordset.filter((r) => r.format_sno === f.format_sno).map((r) => r.position).join() === "1,2,3,4,5");
  await call("sp_nt_DeleteBankFileFormatColumnRecords", { id: arr[1].column_sno });
  ok("delete column (soft)", (await q(`SELECT is_active FROM dbo.bank_file_format_column WHERE column_sno = ${arr[1].column_sno}`))[0].is_active === "N");
  await call("sp_nt_CreateBankFileFormatColumnRecords", col({ position: 5, source_field: "BANK_NAME" }));
  ok("a deleted position can be used again", true);

  // Payment Bank master with a format
  const org = (await q("SELECT TOP 1 c.com_sno, d.div_sno, b.brn_sno FROM dbo.company_master c JOIN dbo.division_master d ON d.com_sno = c.com_sno AND ISNULL(d.is_active,'Y')='Y' JOIN dbo.branch_master b ON b.div_sno = d.div_sno AND ISNULL(b.is_active,'Y')='Y' ORDER BY c.com_sno"))[0];
  if (!org) throw new Error("no company/division/branch to attach a test bank account to");
  const bank = { ...org, profile_name: "ZZ Test acct", bank_name: "Test Bank", ac_holder_name: "TEST CO", ac_number: "99887766554433", ifsc: "TEST0000001", file_prefix: "ZZTEST", client_code: "ZZ1", file_code: 100, created_by: "TEST" };
  const pb = (await call("sp_nt_CreatePaymentBankRecords", { ...bank, file_format_sno: f.format_sno })).recordset[0];
  ok("payment bank created with a format", pb.file_format_sno === f.format_sno && pb.file_format_name === "Test pipe bank");
  ok("payment bank list shows the format name", (await call("sp_nt_GetPaymentBankRecords", {})).recordset.find((r) => r.payment_bank_sno === pb.payment_bank_sno)?.file_format_name === "Test pipe bank");
  await rejects("a format in use cannot be deleted", "sp_nt_DeleteBankFileFormatRecords", { id: f.format_sno }, 59237);
  const pu = (await call("sp_nt_UpdatePaymentBankRecords", { id: pb.payment_bank_sno, bank_name: "Renamed" })).recordset[0];
  ok("updating other fields keeps the format", pu.file_format_sno === f.format_sno && pu.bank_name === "Renamed");
  const pu2 = (await call("sp_nt_UpdatePaymentBankRecords", { id: pb.payment_bank_sno, file_format_sno: "" })).recordset[0];
  ok("a blank format goes back to the built-in layout", pu2.file_format_sno === null && pu2.file_format_name === null);
  const pu3 = (await call("sp_nt_UpdatePaymentBankRecords", { id: pb.payment_bank_sno, file_format_sno: String(seed.format_sno) })).recordset[0];
  ok("a format can be set on update", pu3.file_format_sno === seed.format_sno);
  await call("sp_nt_UpdatePaymentBankRecords", { id: pb.payment_bank_sno, file_format_sno: "" });
  await call("sp_nt_DeleteBankFileFormatRecords", { id: f.format_sno });
  ok("an unused format can be deleted (its columns go with it)", (await q(`SELECT COUNT(*) n FROM dbo.bank_file_format_column WHERE format_sno = ${f.format_sno} AND is_active = 'Y'`))[0].n === 0);

  // existing accounts untouched
  ok("existing payment bank rows still have no format", (await q("SELECT COUNT(*) n FROM dbo.payment_bank_master WHERE file_format_sno IS NOT NULL AND payment_bank_sno <> " + pb.payment_bank_sno))[0].n === 0);
} catch (e) {
  fail++;
  console.error("ERROR", e.message);
} finally {
  await tx.rollback();
  const left = (await pool.request().query("SELECT OBJECT_ID('dbo.bank_file_format') AS t, COL_LENGTH('dbo.payment_bank_master','file_format_sno') AS c")).recordset[0];
  console.log(`\nrolled back. bank_file_format table afterwards: ${left.t ?? "absent"}, payment_bank_master.file_format_sno: ${left.c ?? "absent"}`);
  console.log(`${pass} passed, ${fail} failed`);
  await pool.close();
  process.exit(fail ? 1 : 0);
}
