import sql from 'mssql';
import fs from 'node:fs';
import { configDotenv } from 'dotenv'; configDotenv();
const pool = await new sql.ConnectionPool({user:process.env.DB_USER||'admin',password:process.env.PASSWORD||'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
for (const n of ['sp_nt_SelectSupplierQuotation','sp_nt_GetSupplierQuotations','sp_nt_ApproveSupplierQuotation']) {
  const r = await pool.request().query(`select object_definition(object_id('dbo.${n}')) d`);
  fs.writeFileSync(`tmp/qsel/${n}.sql`, r.recordset[0].d ?? 'NULL');
}
const c = await pool.request().query(`select name from sys.procedures where object_definition(object_id) like '%is_selected%' order by name`);
console.log(c.recordset.map(x=>x.name).join('\n'));
const t = await pool.request().query(`select c.name, t.name tbl from sys.columns c join sys.tables t on t.object_id=c.object_id where c.name in ('is_selected','approval_stages','approver_condition') order by t.name`);
console.log(JSON.stringify(t.recordset));
process.exit(0);
