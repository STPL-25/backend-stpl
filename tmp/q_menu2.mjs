import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const r=await pool.request().query(`select * from screen_group where group_id in (2,9,11) or screen_group_id in (2,9,11)`).catch(async e=>(await pool.request().query(`select * from screen_group`)));
console.log(JSON.stringify(r.recordset));
process.exit(0);
