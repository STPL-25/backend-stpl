import sql from 'mssql';
for (const db of ['Non_Trade','Non_trade_Dev']) {
  const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
  console.log('=====',db);
  console.log(JSON.stringify((await pool.request().query(`select c.name,t.name tn from sys.columns c join sys.types t on t.user_type_id=c.user_type_id where object_id=object_id('approval_instance')`)).recordset.map(x=>x.name)));
  const r = await pool.request().query(`select top 15 * from approval_instance where entity_type like 'PR%' or entity_type like 'Purch%' order by 1 desc`);
  console.log(JSON.stringify(r.recordset.slice(0,3),null,0));
  await pool.close();
}
process.exit(0);
