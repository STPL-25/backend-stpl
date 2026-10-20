import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const q=async(s)=>console.log(JSON.stringify((await pool.request().query(s)).recordset,null,0));
await q(`select top 5 po.po_basic_sno,po.po_df_no,po.vendor_sno,k.company_name from po_request_info po left join kyc_basic_info k on k.kyc_basic_info_sno=po.vendor_sno where k.company_name like '%moto%' or po.po_basic_sno in (select po_basic_sno from grn_basic_info where grn_basic_sno in (select top 3 grn_basic_sno from grn_basic_info order by grn_basic_sno desc)) order by po.po_basic_sno desc`);
await q(`select top 5 g.grn_basic_sno,g.po_basic_sno,g.status,g.is_active,g.created_date from grn_basic_info g order by g.grn_basic_sno desc`);
await q(`select top 5 invoice_sno,invoice_no,po_basic_sno,vendor_sno,invoice_amount from invoice_info order by invoice_sno desc`);
await q(`select top 5 * from sys.tables where name like '%vendor_bill%' or name like '%invoice%'`);
process.exit(0);
