import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const q=async s=>console.log(JSON.stringify((await pool.request().query(s)).recordset,null,0));
await q(`select * from service_po_invoice`);
await q(`select cycle_sno,agreement_sno,status,po_basic_sno from service_po_cycle where status='GENERATED'`);
await q(`select top 5 invoice_sno,invoice_no,invoice_type,po_basic_sno,match_status,net_payable from invoice_info order by 1 desc`);
await q(`select name from sys.columns where object_id=object_id('invoice_info')`);
await q(`select top 3 po_basic_sno,po_df_no,status from po_request_info order by 1 desc`);
process.exit(0);
