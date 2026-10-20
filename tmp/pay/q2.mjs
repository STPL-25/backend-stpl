import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const q=async(s)=>console.log(JSON.stringify((await pool.request().query(s)).recordset));
await q(`select g.grn_basic_sno,g.po_basic_sno,g.status,po.po_df_no,po.vendor_sno from grn_basic_info g join po_request_info po on po.po_basic_sno=g.po_basic_sno where g.grn_basic_sno>=41`);
await q(`select top 3 name from sys.tables where name like 'grn%' or name like 'po_item%'`);
await q(`select i.invoice_sno,i.po_basic_sno from invoice_info i where i.po_basic_sno=1102`);
process.exit(0);
