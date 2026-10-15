import sql from 'mssql';
for (const db of ['Non_trade_Dev','Non_Trade']) {
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
const r=(await pool.request().query(`select o.name,o.type,m.definition d from sys.sql_modules m join sys.objects o on o.object_id=m.object_id where (m.definition like '%workflow_types%' or m.definition like '%vw_workflow_stages%') and o.name not like 'sp_nt_%Workflow%' `)).recordset;
console.log('==',db);
for (const x of r){ const d=x.d; const hasWtActive=/wt\.is_active|workflow_types[^;]{0,300}is_active\s*=\s*'Y'/is.test(d); const hasViewOnly=/vw_workflow_stages/.test(d); console.log(x.name.padEnd(48), hasWtActive?'filters-active':'NO-ACTIVE-FILTER', hasViewOnly?'(uses view)':''); }
await pool.close(); }
process.exit(0);
