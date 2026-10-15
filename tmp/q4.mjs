import sql from 'mssql';
for (const db of ['Non_Trade','Non_trade_Dev']) {
  const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
  console.log('=====',db);
  const t = await pool.request().query(`select t.name tbl, c.name col from sys.columns c join sys.tables t on t.object_id=c.object_id join sys.types ty on ty.user_type_id=c.user_type_id where ty.name in ('varchar','nvarchar') and (c.max_length=-1 or c.max_length>=14 or c.max_length=-1) and t.name like '%workflow%' or t.name like '%approv%'`);
  console.log(t.recordset.map(x=>x.tbl+'.'+x.col).join(', '));
  await pool.close();
}
process.exit(0);
