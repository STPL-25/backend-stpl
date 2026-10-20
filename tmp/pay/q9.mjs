import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const q=async(s)=>console.log(JSON.stringify((await pool.request().query(s)).recordset));
await q(`select reason_type,count(*) n from debit_note_item_details group by reason_type`);
await q(`select top 4 debit_note_sno,qty,unit_price,amount,reason_type from debit_note_item_details`);
process.exit(0);
