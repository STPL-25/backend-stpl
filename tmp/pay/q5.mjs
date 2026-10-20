import sql from 'mssql';
for (const db of ['Non_trade_Dev','Non_Trade']) {
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
const r=await pool.request().query(`select object_id('dbo.sp_nt_GetGrnPendingPayments') o`);
console.log(db, r.recordset[0].o);
if (r.recordset[0].o) console.log(JSON.stringify((await pool.request().execute('sp_nt_GetGrnPendingPayments')).recordset));
await pool.close();}
process.exit(0);
