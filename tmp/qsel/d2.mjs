import sql from 'mssql'; import fs from 'node:fs';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
for (const n of ['sp_nt_GetSupplierQuotationsForApproval','sp_nt_GetQuotationsForApproval','sp_nt_CreateSupplierQuotation']) {
  const r = await pool.request().query(`select object_definition(object_id('dbo.${n}')) d`);
  fs.writeFileSync(`tmp/qsel/${n}.sql`, r.recordset[0].d ?? 'NULL');
}
process.exit(0);
