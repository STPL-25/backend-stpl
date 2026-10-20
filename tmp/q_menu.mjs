import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const r=await pool.request().query(`select s.screen_name,s.comp,s.group_id,s.is_active from dbo.screens s where s.comp in ('ServicePoPage','ServicePoApprovalScreen') or s.comp like '%Invoice%' or s.comp like '%Payment%'`);
console.log(JSON.stringify(r.recordset));
const g=await pool.request().query(`select top 0 * from dbo.screens`); console.log(Object.keys(g.recordset.columns).join(','));
const t=await pool.request().query(`select name from sys.tables where name like '%group%'`); console.log(JSON.stringify(t.recordset));
process.exit(0);
