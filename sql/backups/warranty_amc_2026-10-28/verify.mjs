import fs from "node:fs";
import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv();
const pool = await new sql.ConnectionPool({user:process.env.DB_USER,password:process.env.DB_USER_PASSWORD,server:process.env.SERVER,database:process.env.DATABASE,port:parseInt(process.env.DB_PORT)||1433,options:{trustServerCertificate:true}}).connect();
const script = fs.readFileSync("sql/144_quotation_item_additional_covers.sql","utf8");
const batches = script.split(/^\s*GO\s*$/gim).map(b=>b.trim()).filter(b=>b && !b.split("\n").every(l=>!l.trim()||l.trim().startsWith("--")));
const tx = new sql.Transaction(pool); await tx.begin();
try {
  for (const b of batches) await new sql.Request(tx).batch(b);
  console.log("compiled", batches.length, "batches");
  const q = await new sql.Request(tx).query("select top 1 sq_basic_sno, pr_basic_sno, pr_no from supplier_quotation_info where is_active=1 order by sq_basic_sno desc");
  const row = q.recordset[0]; console.log(row);
  if (row) {
    await new sql.Request(tx).query(`update supplier_quotation_items set additional_json=N'[{"type":"Warranty","years":2,"cost_type":"Free"}]' where sq_basic_sno=${row.sq_basic_sno}`);
    const r = await new sql.Request(tx).input("pr_basic_sno",sql.Int,row.pr_basic_sno).input("pr_no",sql.VarChar,row.pr_no).execute("sp_nt_GetSupplierQuotations");
    const it = JSON.parse(r.recordset.find(x=>x.sq_basic_sno===row.sq_basic_sno).sq_items)[0]; console.log("get:", JSON.stringify(it.additional));
  }
} catch(e){ console.log("ERR", e.message); } finally { try{await tx.rollback();}catch{} console.log("rolled back"); await pool.close(); }
