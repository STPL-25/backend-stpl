import fs from "node:fs/promises";
import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv();
const pool = await new sql.ConnectionPool({user:process.env.DB_USER,password:process.env.DB_USER_PASSWORD,server:process.env.SERVER,database:process.env.DATABASE,port:parseInt(process.env.DB_PORT)||1433,options:{trustServerCertificate:true}}).connect();
console.log(process.env.DATABASE);
for (const n of ["sp_nt_CreateSupplierQuotation","sp_nt_UpdateSupplierQuotation","sp_nt_GetSupplierQuotations","sp_nt_GetQuotationsForApproval"]) {
  const r = await pool.request().query(`SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.${n}')) d`);
  await fs.writeFile(`sql/backups/warranty_amc_2026-10-28/${n}.before.sql`, r.recordset[0].d ?? "");
  console.log(n, (r.recordset[0].d||"").length);
}
const c = await pool.request().query("select name from sys.columns where object_id=object_id('dbo.supplier_quotation_items')");
console.log(c.recordset.map(x=>x.name).join(","));
await pool.close();
