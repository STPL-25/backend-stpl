import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_Trade',options:{trustServerCertificate:true,encrypt:false}}).connect();
console.log(JSON.stringify((await pool.request().query(`select instance_id,entity_ref_id,workflow_types_id,cycle_no,status,created_at from approval_instance order by 1`)).recordset));
console.log(JSON.stringify((await pool.request().query(`select log_id,instance_id,entity_ref_id,action,from_seq,to_seq,stage_name,acted_by,acted_as,acted_at,comments from approval_action_log order by log_id desc`)).recordset.slice(0,12),null,0));
console.log(JSON.stringify((await pool.request().query(`select pr_sno,pr_no,status,workflow_types_id,created_date from purchase_requisition where pr_sno in (1040,1041)`).catch(e=>({recordset:e.message}))).recordset));
const d=await pool.request().query(`select definition from sys.sql_modules where object_id=object_id('sp_nt_PrApprovalAct')`);
console.log(d.recordset[0].definition);
process.exit(0);
