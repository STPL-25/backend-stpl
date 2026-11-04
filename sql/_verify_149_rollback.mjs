// Applies 149, then its ROLLBACK script, inside one transaction that is always rolled back; checks the end state equals the start state.
import fs from "node:fs/promises";
import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv();
if (process.env.DATABASE !== "Non_trade_Dev") { console.error("Refusing: not Non_trade_Dev"); process.exit(1); }
const pool = await new sql.ConnectionPool({ user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD, server: process.env.SERVER, database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433, options: { trustServerCertificate: true }, requestTimeout: 120000, pool: { max: 1, min: 0 } }).connect();
const split = (s) => s.split(/^\s*GO\s*$/gim).map((b) => b.trim()).filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));
const up = split(await fs.readFile(new URL("./149_bank_file_format_master.sql", import.meta.url), "utf8"));
const down = split(await fs.readFile(new URL("./backups/bank_file_format_2026-11-03_ROLLBACK.sql", import.meta.url), "utf8"));
const state = async (r) => (await r.query(`SELECT OBJECT_ID('dbo.bank_file_format') t, OBJECT_ID('dbo.bank_file_format_column') t2, COL_LENGTH('dbo.payment_bank_master','file_format_sno') c,
  OBJECT_ID('dbo.sp_nt_GetBankFileFormatRecords') p, (SELECT CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.sp_nt_GetPaymentBankRecords')) LIKE '%file_format%' THEN 1 ELSE 0 END) mentions_format`)).recordset[0];
const tx = new sql.Transaction(pool); await tx.begin();
try {
  console.log("before   :", JSON.stringify(await state(new sql.Request(tx))));
  for (const b of up) await new sql.Request(tx).batch(b);
  console.log("after 149:", JSON.stringify(await state(new sql.Request(tx))));
  for (const b of down) await new sql.Request(tx).batch(b);
  console.log("after RB :", JSON.stringify(await state(new sql.Request(tx))));
} finally { await tx.rollback(); console.log("rolled back:", JSON.stringify(await state(pool.request()))); await pool.close(); }
