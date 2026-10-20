import sql from 'mssql';
import fs from 'fs';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const r = await pool.request().query(`select definition from sys.sql_modules where object_id=object_id('dbo.sp_nt_GetPODetailForSupplier')`);
fs.writeFileSync(`tmp/gst/sp_nt_GetPODetailForSupplier.sql`, r.recordset[0].definition);
process.exit(0);
