import sql from 'mssql';
for (const db of ['Non_Trade','Non_trade_Dev']){
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
const d=(await pool.request().query(`select definition from sys.sql_modules where object_id=object_id('sp_nt_CreateSupplierQuotation')`)).recordset[0].definition;
console.log('==',db); console.log(d.split('\n').slice(118,137).join('\n'));
await pool.close();}
process.exit(0);
