import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const q=async(s)=>console.log(JSON.stringify((await pool.request().query(s)).recordset));
await q(`select c.name from sys.columns c where c.object_id=object_id('invoice_info')`);
await q(`select g.grn_no,g.status,i.prod_name,i.received_qty,i.net_cost,i.total_grn_cost,i.po_unit_price,i.tax_pct from grn_basic_info g join grn_item_details i on i.grn_basic_sno=g.grn_basic_sno where g.grn_basic_sno=41`);
process.exit(0);
