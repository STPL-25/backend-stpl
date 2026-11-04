import sql from "mssql"; import {configDotenv} from "dotenv"; configDotenv();
const p=await new sql.ConnectionPool({server:process.env.SERVER,database:process.env.DATABASE,user:process.env.DB_USER,password:process.env.DB_USER_PASSWORD,port:parseInt(process.env.DB_PORT)||1433,options:{encrypt:false,trustServerCertificate:true}}).connect();
const q=(await p.request().query("select top 1 sq_basic_sno,pr_basic_sno,pr_no,status from supplier_quotation_info where is_active=1 and status='P' and is_selected=0 order by 1 desc")).recordset[0];
console.log(q); if(!q) process.exit(0);
const it=(await p.request().query(`select top 1 pr_item_sno,prod_sno,unit,qty from supplier_quotation_items where sq_basic_sno=${q.sq_basic_sno} and is_active=1`)).recordset[0];
const tx=new sql.Transaction(p); await tx.begin();
try{
 const j=JSON.stringify({sq_basic_sno:q.sq_basic_sno,modified_by:'T',quotation_ref_no:'EDIT-TEST',quotation_date:'2026-10-28',items:[{...it,unit_price:5,discount_pct:0,tax_pct:18,total_amount:5*it.qty*1.18,delivery_days:3,remarks:'x'}]});
 const r=await new sql.Request(tx).input('jsonInput',sql.NVarChar(sql.MAX),j).execute('sp_nt_UpdateSupplierQuotation');
 console.log(r.recordset);
 const g=await new sql.Request(tx).input('pr_basic_sno',sql.Int,q.pr_basic_sno).input('pr_no',sql.VarChar(20),q.pr_no).execute('sp_nt_GetSupplierQuotations');
 const row=g.recordset.find(x=>x.sq_basic_sno===q.sq_basic_sno); console.log(row.quotation_ref_no,row.sq_items);
}catch(e){console.log('ERR',e.message)} finally{await tx.rollback();console.log('rolled back')}
process.exit(0)
