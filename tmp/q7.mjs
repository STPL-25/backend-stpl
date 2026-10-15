import sql from 'mssql';
for (const db of ['Non_Trade','Non_trade_Dev']) {
  const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
  console.log('=====',db);
  console.log('stages wf82/60/30:',JSON.stringify((await pool.request().query(`select stage_id,workflow_types_id,is_active,ISJSON(stage_order_json) j,len(stage_order_json) l from workflow_stage where workflow_types_id in (82,60,30)`)).recordset));
  console.log('triggers:',JSON.stringify((await pool.request().query(`select t.name, o.name tbl, t.is_disabled from sys.triggers t join sys.objects o on o.object_id=t.parent_id where o.name in ('pr_basic_info','workflow_stage','approval_instance')`)).recordset));
  console.log('PR rows:',JSON.stringify((await pool.request().query(`select top 4 pr_basic_sno,pr_no,status,workflow_types_id,current_approver_id,created_date from pr_basic_info order by pr_basic_sno desc`)).recordset));
  await pool.close();
}
process.exit(0);
