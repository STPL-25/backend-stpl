import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const q=async s=>console.log(JSON.stringify((await pool.request().query(s)).recordset));
await q(`select object_id('sp_nt_SyncServicePoInvoicesToPayables') proc_id, col_length('service_po_invoice','payable_invoice_sno') col`);
await q(`select invoice_sno,cycle_sno,po_basic_sno,invoice_no,invoice_amount,payable_invoice_sno from service_po_invoice where is_active='Y' order by 1`);
await q(`select i.invoice_sno,i.invoice_no,i.vendor_invoice_no,i.po_basic_sno,i.invoice_amount,iad.invoice_alloc_sno,iad.release_amount from invoice_info i join invoice_allocation_details iad on iad.invoice_sno=i.invoice_sno where i.invoice_type='SERVICE'`);
process.exit(0);
