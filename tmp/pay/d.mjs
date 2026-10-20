import sql from 'mssql'; import fs from 'node:fs';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const r = await pool.request().query(`select object_definition(object_id('dbo.sp_nt_GetPayableBillsNet')) d`);
fs.writeFileSync('tmp/pay/sp.sql', r.recordset[0].d);
process.exit(0);
