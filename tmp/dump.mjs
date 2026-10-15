import sql from 'mssql'; import fs from 'fs';
const names=['usp_InsertPurchaseRequest','usp_InsertVendorDrivenPurchaseRequest','sp_nt_PrApprovalAct','trg_pr_basic_info_approval_instance','sp_nt_ResolveWorkflow','vw_workflow_stages','sp_InsertPurchaseRecords','sp_InserPurchaseRecords','fn_resolve_approval_entity'];
for (const db of ['Non_Trade','Non_trade_Dev']) {
  const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
  for (const n of names){ const r=(await pool.request().query(`select definition from sys.sql_modules where object_id=object_id('${n}')`)).recordset[0]; if(r) fs.writeFileSync(`sql/backups/inactive_workflow_fix_2026-10-13/${db}/${n}.sql`, r.definition); }
  await pool.close();
}
