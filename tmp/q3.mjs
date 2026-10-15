import sql from 'mssql';
for (const db of ['Non_Trade','Non_trade_Dev']) {
  const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
  console.log('=====',db);
  const r = await pool.request().query(`select instance_id,entity_ref_id,workflow_types_id,cycle_no,current_seq,status,created_at,updated_at,stages_json from approval_instance where stages_json like '%KTM1141%' and entity_type='PurchaseRequisition' order by 1 desc`);
  for (const x of r.recordset.slice(0,8)) { const st=JSON.parse(x.stages_json).map(s=>s.approver_ecno+'/'+s.required_approvals+(s.alternates?'+alt'+s.alternates:'')).join(' > '); console.log(x.instance_id,'PR',x.entity_ref_id,'wf',x.workflow_types_id,'cyc',x.cycle_no,'seq',x.current_seq,'st',x.status,x.updated_at.toISOString(),'|',st); }
  await pool.close();
}
process.exit(0);
