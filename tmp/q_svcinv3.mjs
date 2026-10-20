import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const d=(await pool.request().query(`select OBJECT_DEFINITION(OBJECT_ID('sp_nt_GetPayableBillsNet')) d`)).recordset[0].d;
import fs from 'fs'; fs.writeFileSync('tmp/live_net.sql', d);
console.log(d.length);
process.exit(0);
