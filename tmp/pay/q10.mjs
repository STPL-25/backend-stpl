import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
console.log(JSON.stringify((await pool.request().query(`select top 3 po_item_sno,is_active,po_item_sno from po_item_details where po_basic_sno=1102`)).recordset));
process.exit(0);
