import sql from 'mssql';
import fs from 'fs';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
for (const n of ['sp_nt_ApproveSupplierQuotation','sp_Save_PO_Request']) {
  const r = await pool.request().query(`select definition from sys.sql_modules where object_id=object_id('dbo.${n}')`);
  fs.writeFileSync(`tmp/gst/${n}.sql`, r.recordset[0].definition);
}
const u = await pool.request().query(`select o.name from sys.sql_modules m join sys.objects o on o.object_id=m.object_id where m.definition like '%po_item_details%' and o.type in ('P','V','FN','IF','TF') order by o.name`);
console.log(u.recordset.map(x=>x.name).join(', '));
process.exit(0);
