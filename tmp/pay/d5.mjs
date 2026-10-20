import sql from 'mssql'; import fs from 'node:fs';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const r = await pool.request().query(`select object_definition(object_id('dbo.sp_nt_CalcTDS')) d`); console.log(r.recordset[0].d);
const q=async(s)=>console.log(JSON.stringify((await pool.request().query(s)).recordset));
await q(`select (select string_agg(name,',') from sys.columns where object_id=object_id('kyc_basic_info') and (name like '%tds%' or name like '%pan%' or name like '%section%')) c`);
await q(`select * from tds_section_master where is_active='Y'`);
await q(`select top 3 tds_section_code from invoice_info where tds_section_code is not null`);
process.exit(0);
