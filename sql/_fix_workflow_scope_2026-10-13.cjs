// Fix workflow_types scope drift (division/branch disagree with branch master), move a PR type that was saved
// under a KYC workflow, retire a duplicate-scope row. Run: node sql/_fix_workflow_scope_2026-10-13.cjs <DB> [--apply]
const sql=require("mssql"); const fs=require("fs");
require("dotenv").config();
const db=process.argv[2], apply=process.argv.includes("--apply");
(async()=>{
const pool=await new sql.ConnectionPool({user:process.env.DB_USER,password:process.env.DB_USER_PASSWORD,server:process.env.SERVER,database:db,port:1433,options:{trustServerCertificate:true}}).connect();
const Q=async(r,s)=>(await r.query(s)).recordset;
const tx=new sql.Transaction(pool); await tx.begin(); const r=new sql.Request(tx);
const MISMATCH=`select wt.workflow_types_id id, wt.workflow_id, wt.com_sno, wt.div_sno, wt.brn_sno, wt.dept_sno,
   eb.brn_sno new_brn, b.div_sno new_div, b.com_sno new_com
 from workflow_types wt
 left join dept_master d on d.dept_sno=wt.dept_sno
 cross apply (select coalesce(d.brn_sno, wt.brn_sno) brn_sno) eb
 join branch_master b on b.brn_sno=eb.brn_sno
 where wt.is_active='Y' and (wt.brn_sno<>eb.brn_sno or wt.div_sno<>b.div_sno or wt.com_sno<>b.com_sno)`;
const rows=await Q(r,MISMATCH);
const extraIds = db==="Non_Trade" ? [60,81] : [];
const ids=[...new Set([...rows.map(x=>x.id),...extraIds])];
const before = ids.length ? {
  workflow_types: await Q(r,`select * from workflow_types where workflow_types_id in (${ids.join(",")})`),
  workflow_stage: await Q(r,`select * from workflow_stage where workflow_types_id in (${ids.join(",")})`),
  workflow_master: db==="Non_trade_Dev" ? await Q(r,`select * from approval_workflow_master where workflow_id=44`) : [] } : {};
fs.writeFileSync(`sql/backups/pre_workflow_scope_fix_${db}_2026-10-13.json`, JSON.stringify(before,null,1));
console.log(db,"to realign:",JSON.stringify(rows));
await r.query(`update wt set wt.brn_sno=eb.brn_sno, wt.div_sno=b.div_sno, wt.com_sno=b.com_sno, wt.modified_at=getdate(), wt.modified_by='scope-fix'
 from workflow_types wt left join dept_master d on d.dept_sno=wt.dept_sno cross apply (select coalesce(d.brn_sno, wt.brn_sno) brn_sno) eb
 join branch_master b on b.brn_sno=eb.brn_sno
 where wt.is_active='Y' and (wt.brn_sno<>eb.brn_sno or wt.div_sno<>b.div_sno or wt.com_sno<>b.com_sno)`);
if(db==="Non_Trade"){
  // PR type saved under a KYC-entity workflow -> move to the PR workflow 17 so PR routing can find it
  console.log("move 60:",(await r.query(`update workflow_types set workflow_id=17, workflow_name=(select left(workflow_name,50) from approval_workflow_master where workflow_id=17), modified_at=getdate(), modified_by='scope-fix' where workflow_types_id=60 and workflow_id=18`)).rowsAffected);
  // duplicate scope 1/1/1/6 (wf17 type 81 vs wf20 type 82): retire 81 + its stages, keep 82
  console.log("retire 81:",(await r.query(`update workflow_stage set is_active='N', modified_at=getdate(), modified_by='scope-fix' where workflow_types_id=81 and is_active='Y'; update workflow_types set is_active='N', modified_at=getdate(), modified_by='scope-fix' where workflow_types_id=81 and is_active='Y'`)).rowsAffected);
} else {
  console.log("rename wf44:",(await r.query(`update approval_workflow_master set workflow_name='Service Agreement Approval Workflow', modified_at=getdate() where workflow_id=44 and entity_type='ServiceAgreement' and workflow_name like 'Purchaseorder%'; update workflow_types set workflow_name='Service Agreement Approval Workflow' where workflow_id=44`)).rowsAffected);
}
const left=await Q(r,MISMATCH);
const dup=await Q(r,`select wt.com_sno,wt.div_sno,wt.brn_sno,wt.dept_sno,a.entity_type,count(*) c from workflow_types wt join approval_workflow_master a on a.workflow_id=wt.workflow_id where wt.is_active='Y' and a.is_active='Y' and wt.dept_sno is not null group by wt.com_sno,wt.div_sno,wt.brn_sno,wt.dept_sno,a.entity_type having count(*)>1`);
console.log("remaining mismatches:",left.length,"overlaps(same entity+scope):",JSON.stringify(dup));
if(apply && left.length===0){await tx.commit();console.log("COMMITTED");} else {await tx.rollback();console.log(apply?"ROLLED BACK (check failed)":"DRY RUN - rolled back");}
await pool.close();
})().catch(e=>{console.error(e);process.exit(1)});
