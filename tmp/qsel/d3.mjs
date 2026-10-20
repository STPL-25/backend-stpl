import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
console.log(JSON.stringify((await pool.request().query(`select entity_type, count(*) n from workflow_master group by entity_type`)).recordset));
console.log(JSON.stringify((await pool.request().query(`select name from sys.procedures where name like '%orkflow%' order by name`)).recordset.map(x=>x.name)));
process.exit(0);
