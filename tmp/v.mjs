import sql from 'mssql';
for (const db of ['Non_Trade','Non_trade_Dev']){
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
const r=(await pool.request().query(`select o.name from sys.sql_modules m join sys.objects o on o.object_id=m.object_id where m.definition like '%act_ws%' or (o.name='sp_nt_PrApprovalAct' and m.definition like '%Never invent%') order by 1`)).recordset;
console.log(db, r.length, r.map(x=>x.name).join(', '));
const s=(await pool.request().query(`select (select count(*) from approval_instance) inst, (select count(*) from pr_basic_info where status='P') pending`)).recordset[0]; console.log(JSON.stringify(s));
await pool.close();}
process.exit(0);
