import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const q=async(s)=>(await pool.request().query(s)).recordset;
const wt=(await q(`select top 1 wt.* from workflow_types wt join approval_workflow_master a on a.workflow_id=wt.workflow_id join workflow_stage s on s.workflow_types_id=wt.workflow_types_id and s.is_active='Y' where wt.is_active='Y' and a.is_active='Y' and a.entity_type=dbo.fn_resolve_approval_entity('PurchaseRequisition','NORMAL')`))[0];
const it=(await q(`select top 1 prod_sno from pr_item_details where prod_sno is not null`))[0];
const body={ecno:'TESTX',basicInfo:{com_sno:wt.com_sno,div_sno:wt.div_sno,brn_sno:wt.brn_sno,dept_sno:wt.dept_sno,req_date:'2026-10-13',required_date:'2026-10-30',priority_sno:1,purpose:'tx test'},items:[{prod_sno:it.prod_sno,unit_sno:1,qty:1,est_cost:1}]};
for (const [label,pre] of [['stage inactive',`update workflow_stage set is_active='N' where workflow_types_id=${wt.workflow_types_id}`],['type inactive',`update workflow_types set is_active='N' where workflow_types_id=${wt.workflow_types_id}`]]) {
  const tx=new sql.Transaction(pool); await tx.begin(); let res;
  try{ await new sql.Request(tx).query(pre);
    const x=await new sql.Request(tx).output('pr_no',sql.VarChar(20)).input('jsonInput',sql.NVarChar(sql.MAX),JSON.stringify(body)).execute('usp_InsertPurchaseRequest'); res='OK '+x.output.pr_no;
  }catch(e){res='ERR '+e.message;} try{await tx.rollback();}catch{}
  console.log(label,'->',res);
}
console.log('state after:',JSON.stringify(await q(`select (select is_active from workflow_types where workflow_types_id=${wt.workflow_types_id}) t,(select string_agg(is_active,',') from workflow_stage where workflow_types_id=${wt.workflow_types_id}) s,(select count(*) from pr_basic_info where purpose='tx test') leftover`)));
process.exit(0);
