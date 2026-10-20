import sql from 'mssql';
for (const db of ['Non_Trade','Non_trade_Dev']) {
  const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
  const r=(await pool.request().query(`select object_id('sp_nt_SyncServicePoInvoicesToPayables') p, col_length('service_po_invoice','payable_invoice_sno') c, (select count(*) from invoice_info where invoice_type='SERVICE') svc_inv`)).recordset;
  console.log(db, JSON.stringify(r));
  await pool.close();
}
process.exit(0);
