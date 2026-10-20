import sql from 'mssql'; import fs from 'node:fs';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
for (const n of ['sp_nt_ReleasePaymentNet','sp_nt_GetPaymentAdjustments']) {
 const r = await pool.request().query(`select object_definition(object_id('dbo.${n}')) d`);
 fs.writeFileSync(`tmp/pay/${n}.sql`, r.recordset[0].d);}
const q=async(s)=>console.log(JSON.stringify((await pool.request().query(s)).recordset));
for (const t of ['debit_note_info','debit_note','credit_note_info','supplier_advance','supplier_advances','tds_section_master','po_advance'])
  await q(`select '${t}' t, (select string_agg(name,',') from sys.columns where object_id=object_id('${t}')) c`);
await q(`select name from sys.tables where name like '%debit%' or name like '%credit%' or name like '%advance%' or name like '%tds%'`);
process.exit(0);
