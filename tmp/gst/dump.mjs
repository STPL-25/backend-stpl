import sql from 'mssql';
import fs from 'fs';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
for (const n of ['sp_nt_CreateSupplierQuotation','sp_nt_GetSupplierQuotations']) {
  const r = await pool.request().query(`select definition from sys.sql_modules where object_id=object_id('dbo.${n}')`);
  fs.writeFileSync(`tmp/gst/${n}.sql`, r.recordset[0]?.definition ?? 'MISSING');
}
const o = await pool.request().query(`select name from sys.objects where definition_dummy is null`).catch(()=>null);
const u = await pool.request().query(`select o.name from sys.sql_modules m join sys.objects o on o.object_id=m.object_id where m.definition like '%freight_charges%'`);
console.log(u.recordset.map(x=>x.name));
process.exit(0);
