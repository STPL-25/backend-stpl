import fs from "node:fs/promises";
import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv({ quiet: true });
const pool = await new sql.ConnectionPool({
  user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD,
  server: process.env.SERVER, database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433,
  options: { trustServerCertificate: true }, connectionTimeout: 15000, requestTimeout: 60000,
}).connect();
const script = await fs.readFile("sql/141_user_home_org.sql", "utf8");
const batches = script.split(/^\s*GO\s*$/gim).map(b => b.trim()).filter(b => b && !b.split("\n").every(l => !l.trim() || l.trim().startsWith("--")));
const tx = new sql.Transaction(pool);
await tx.begin();
const run = async (t, inputs = {}) => { const r = new sql.Request(tx); for (const [k, v] of Object.entries(inputs)) r.input(k, sql.NVarChar(sql.MAX), v); return r; };
try {
  for (const b of batches) await (await run()).batch(b);
  console.log("applied", batches.length, "batches (in tx)");
  const list = (await (await run()).query("EXEC dbo.sp_nt_GetUserHomeOrgList")).recordset;
  console.table(list.map(r => ({ ecno: r.ecno, hr_dept: r.hr_dept, hr_branch: r.hr_branch, mapped: r.is_mapped, sug: r.sug_dept_sno })));
  const ok = await (await run("", { j: JSON.stringify({ ecno: "KTM1006", dept_sno: 1 }) })).query("EXEC dbo.sp_nt_SetUserHomeOrg @jsonInput=@j");
  console.log("set ok:", ok.recordset);
  console.log("login view:", (await (await run()).query("SELECT ecno,com_name,div_name,brn_name,dept_name FROM vw_Sign_Up WHERE ecno='KTM1006'")).recordset);
  for (const [label, j] of [["inactive dept", { ecno: "KTM1006", dept_sno: 3 }], ["no user", { ecno: "NOPE", dept_sno: 1 }], ["no dept", { ecno: "KTM1006" }]]) {
    try { await (await run("", { j: JSON.stringify(j) })).query("EXEC dbo.sp_nt_SetUserHomeOrg @jsonInput=@j"); console.log(label, "-> NO ERROR (bad)"); }
    catch (e) { console.log(label, "->", e.message); }
  }
  console.log("screen:", (await (await run()).query("SELECT screen_name,comp,group_id,display_order FROM dbo.screens WHERE comp='UserHomeOrgPage'")).recordset);
} finally {
  await tx.rollback().catch(() => {});
  console.log("ROLLED BACK; proc exists after rollback:", (await pool.request().query("SELECT OBJECT_ID('sp_nt_SetUserHomeOrg') x")).recordset[0].x);
  await pool.close();
}
