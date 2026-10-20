import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
console.log(JSON.stringify((await pool.request().query(`select po_type, left(po_df_no,4) p, count(*) n from po_request_info where po_basic_sno in (1,26,1096,1097,1100,1102,70) group by po_type,left(po_df_no,4)`)).recordset));
process.exit(0);
