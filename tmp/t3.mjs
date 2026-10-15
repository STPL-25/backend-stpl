import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const q=async(s)=>(await pool.request().query(s)).recordset;
// pick a workflow with >=2 stages
const wt=(await q(`select top 1 wt.* from workflow_types wt join approval_workflow_master a on a.workflow_id=wt.workflow_id join workflow_stage s on s.workflow_types_id=wt.workflow_types_id and s.is_active='Y' where wt.is_active='Y' and a.is_active='Y' and a.entity_type=dbo.fn_resolve_approval_entity('PurchaseRequisition','NORMAL') and (select count(*) from openjson(s.stage_order_json))>=2`))[0];
console.log('wt',wt?.workflow_types_id);
if(!wt) process.exit(0);
const it=(await q(`select top 1 prod_sno from pr_item_details where prod_sno is not null`))[0];
const body={ecno:'TESTX',basicInfo:{com_sno:wt.com_sno,div_sno:wt.div_sno,brn_sno:wt.brn_sno,dept_sno:wt.dept_sno,req_date:'2026-10-13',required_date:'2026-10-30',priority_sno:1,purpose:'tx test'},items:[{prod_sno:it.prod_sno,unit_sno:1,qty:1,est_cost:1}]};
const tx=new sql.Transaction(pool); await tx.begin();
const R=()=>new sql.Request(tx);
try{
 const x=await R().output('pr_no',sql.VarChar(20)).input('jsonInput',sql.NVarChar(sql.MAX),JSON.stringify(body)).execute('usp_InsertPurchaseRequest'); const pr=x.output.pr_no;
 const inst=(await R().query(`select i.instance_id,i.status from approval_instance i join pr_basic_info p on p.pr_basic_sno=i.entity_ref_id where p.pr_no='${pr}'`)).recordset;
 console.log('PR',pr,'instance created by trigger:',JSON.stringify(inst));
 await R().query(`delete i from approval_instance i join pr_basic_info p on p.pr_basic_sno=i.entity_ref_id where p.pr_no='${pr}'; update workflow_stage set is_active='N' where workflow_types_id=${wt.workflow_types_id}`);
 const appr=(await R().query(`select current_approver_id a from pr_basic_info where pr_no='${pr}'`)).recordset[0].a;
 const y=await R().input('jsonInput',sql.NVarChar(sql.MAX),JSON.stringify({pr_no:pr,action:'approve',approved_by:appr,comments:'t'})).execute('sp_nt_PrApprovalAct');
 console.log('approve ->',JSON.stringify(y.recordset[0]));
 console.log('PR status after 1st approve:',JSON.stringify((await R().query(`select status,current_approver_id from pr_basic_info where pr_no='${pr}'`)).recordset));
}catch(e){console.log('ERR',e.message)}
try{await tx.rollback();}catch{}
console.log('leftover',JSON.stringify(await q(`select count(*) n from pr_basic_info where purpose='tx test'`)),JSON.stringify(await q(`select string_agg(is_active,',') s from workflow_stage where workflow_types_id=${wt.workflow_types_id}`)));
process.exit(0);
