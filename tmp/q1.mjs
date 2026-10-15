import sql from 'mssql';
for (const db of ['Non_Trade','Non_trade_Dev']) {
  const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
  console.log('=====',db);
  const r = await pool.request().query(`select name from sys.procedures where name like '%PR%' and (name like '%pprov%') order by name`);
  console.log(r.recordset.map(x=>x.name).join(', '));
  const r2 = await pool.request().query(`select top 5 * from sys.tables where name like '%approval%' or name like '%pr_%'`);
  console.log((await pool.request().query(`select name from sys.tables where name like '%pprov%' or name like '%purchase_req%' order by name`)).recordset.map(x=>x.name).join(', '));
  await pool.close();
}
process.exit(0);
