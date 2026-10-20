import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const q=async(l,s)=>console.log(l,JSON.stringify((await pool.request().query(s)).recordset));
const r=await pool.request().input('jsonInput',sql.NVarChar,'{}').execute('sp_nt_GetPayableBillsNet');
console.log('payable rows',r.recordset.length);
console.log(JSON.stringify(r.recordset.filter(x=>x.bucket_type==='SERVICE').map(x=>({bill:x.bill_no,sup:x.supplier_invoice_no,po:x.po_no,vendor:x.vendor_name,amt:x.outstanding,grn:x.grn_state,hold2b:x.on_hold_2b}))));
await q('svc invoices',`select invoice_sno,cycle_sno,po_basic_sno,invoice_no,invoice_amount,payable_invoice_sno from service_po_invoice where is_active='Y' order by 1`);
await q('alloc sums',`select i.invoice_sno,i.invoice_amount,sum(iad.release_amount) rel from invoice_info i join invoice_allocation_details iad on iad.invoice_sno=i.invoice_sno where i.invoice_type='SERVICE' group by i.invoice_sno,i.invoice_amount`);
process.exit(0);
