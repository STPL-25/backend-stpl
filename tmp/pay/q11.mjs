import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const r=(await pool.request().input('jsonInput',sql.NVarChar(sql.MAX),JSON.stringify({include_billed:true})).execute('sp_nt_GetGrnPendingPayments')).recordset;
console.log(r.length, JSON.stringify(r.filter(x=>x.has_invoice).slice(0,3).map(x=>[x.po_no,x.has_invoice,x.net_payable])));
process.exit(0);
