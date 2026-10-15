import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const q=async(r,s)=>(await r.query(s)).recordset;
const tx=new sql.Transaction(pool); await tx.begin();
try{
 const r=()=>new sql.Request(tx);
 const wt=(await q(r(),`select top 1 wt.* from workflow_types wt join approval_workflow_master a on a.workflow_id=wt.workflow_id join workflow_stage s on s.workflow_types_id=wt.workflow_types_id and s.is_active='Y' where wt.is_active='Y' and a.is_active='Y' and a.entity_type=dbo.fn_resolve_approval_entity('PurchaseRequisition','NORMAL')`))[0];
 const it=(await q(r(),`select top 1 prod_sno, 1 as unit_sno from pr_item_details where prod_sno is not null`))[0];
 console.log('wt',wt.workflow_types_id,wt.workflow_types_name);
 const body={ecno:'TESTX',basicInfo:{com_sno:wt.com_sno,div_sno:wt.div_sno,brn_sno:wt.brn_sno,dept_sno:wt.dept_sno,req_date:'2026-10-13',required_date:'2026-10-30',priority_sno:1,purpose:'tx test'},items:[{prod_sno:it.prod_sno,unit_sno:it.unit_sno,qty:1,est_cost:1}]};
 const call=async()=>{ try{ const x=await r().output('pr_no',sql.VarChar(20)).input('jsonInput',sql.NVarChar(sql.MAX),JSON.stringify(body)).execute('usp_InsertPurchaseRequest'); return 'OK '+JSON.stringify(x.output); }catch(e){return 'ERR '+e.message;} };
 console.log('active  ->',await call());
 await q(r(),`update workflow_stage set is_active='N' where workflow_types_id=${wt.workflow_types_id}`);
 console.log('stage inactive ->',await call());
 await q(r(),`update workflow_stage set is_active='Y' where workflow_types_id=${wt.workflow_types_id}; update workflow_types set is_active='N' where workflow_types_id=${wt.workflow_types_id}`);
 console.log('type inactive ->',await call());
}finally{ await tx.rollback(); console.log('rolled back'); }
process.exit(0);
