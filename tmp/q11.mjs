import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_Trade',options:{trustServerCertificate:true,encrypt:false}}).connect();
const d=(await pool.request().query(`select definition from sys.sql_modules where object_id=object_id('usp_InsertPurchaseRequest')`)).recordset[0].definition;
console.log(d.split('\n').slice(92,136).join('\n'));
console.log(JSON.stringify((await pool.request().query(`select definition from sys.sql_modules where object_id=object_id('vw_workflow_stages')`)).recordset[0].definition));
process.exit(0);
