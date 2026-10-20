import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const q=async(s)=>console.log(JSON.stringify((await pool.request().query(s)).recordset));
await q(`select t.name, c.name col from sys.tables t join sys.columns c on c.object_id=t.object_id where t.name in ('grn_basic_info','grn_item_details','po_request_info','po_item_details','po_items') order by t.name, c.column_id`);
await q(`select name from sys.tables where name like 'grn%' or name like 'po_%'`);
process.exit(0);
