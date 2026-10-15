import sql from 'mssql'; import fs from 'fs';
const apply = process.argv[2]==='apply';
const ACT = (wt, awm) => `AND ${wt}.is_active = 'Y' AND ${awm}.is_active = 'Y'
          AND EXISTS (SELECT 1 FROM dbo.workflow_stage act_ws WHERE act_ws.workflow_types_id = ${wt}.workflow_types_id AND act_ws.is_active = 'Y')`;
const patches = {
 usp_InsertPurchaseRequest: d => {
  let n=0;
  d = d.replace(/(AND\s+awm\.entity_type\s*=\s*dbo\.fn_resolve_approval_entity\('PurchaseRequisition',\s*'NORMAL'\))/, m=>{n++; return m+'\n  '+ACT('wt','awm');});
  d = d.replace(/AND\s+workflow_id\s*=\s*@workflow_id\s*;/, ()=>{n++; return `AND workflow_id=@workflow_id
          AND is_active = 'Y'
          AND EXISTS (SELECT 1 FROM dbo.workflow_stage act_ws WHERE act_ws.workflow_types_id = workflow_types.workflow_types_id AND act_ws.is_active = 'Y');`;});
  if(n!==2) throw new Error('usp_InsertPurchaseRequest n='+n); return d; },
 usp_InsertVendorDrivenPurchaseRequest: d => {
  let n=0;
  d = d.replace(/(AND\s+awm\.entity_type\s*=\s*dbo\.fn_resolve_approval_entity\('PurchaseRequisition',\s*'VENDOR_DRIVEN'\))\s*;/, (m,a)=>{n++; return a+'\n      '+ACT('wt','awm')+';';});
  if(n!==1) throw new Error('vendor n='+n); return d; },
 trg_pr_basic_info_approval_instance: d => {
  let n=0;
  d = d.replace(/ORDER BY w\.stage_id\)/, ()=>{n++; return "ORDER BY CASE WHEN w.is_active = 'Y' THEN 0 ELSE 1 END, w.stage_id)";});
  d = d.replace(/AND w\.is_active = 'Y' AND ISJSON/, ()=>{n++; return 'AND ISJSON';});
  if(n!==2) throw new Error('trg n='+n); return d; },
 sp_nt_PrApprovalAct: d => {
  const a = d.indexOf("SELECT TOP 1 @stages = stage_order_json FROM dbo.workflow_stage");
  const b = d.indexOf("SELECT TOP 1 @cur = CAST(s.[key] AS INT)");
  if(a<0||b<0||b<a) throw new Error('engine anchors');
  const repl = `-- Prefer the active chain; a workflow retired after this PR was raised still keeps its configured chain
            -- for the PR already in flight. Never invent a one-stage chain: that silently skipped later approvers.
            SELECT TOP 1 @stages = stage_order_json FROM dbo.workflow_stage
            WHERE workflow_types_id = @wf AND ISJSON(stage_order_json) = 1
            ORDER BY CASE WHEN is_active = 'Y' THEN 0 ELSE 1 END, stage_id;
            IF @stages IS NULL
                THROW 52006, N'No approval stages are configured for this requisition. Ask an administrator to check its workflow.', 1;

            `;
  return d.slice(0,a)+repl+d.slice(b); }
};
const out={};
for (const db of ['Non_trade_Dev','Non_Trade']) {
  if (db==='Non_Trade' && process.argv[3]!=='prod') continue;
  const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
  for (const [n,fn] of Object.entries(patches)) {
    let d=(await pool.request().query(`select definition from sys.sql_modules where object_id=object_id('${n}')`)).recordset[0].definition;
    if (/act_ws|ORDER BY CASE WHEN is_active/.test(d)) { console.log(db,n,'already patched'); continue; }
    const p = fn(d).replace(/CREATE\s+(PROCEDURE|TRIGGER)/i,'CREATE OR ALTER $1');
    out[n]=p;
    if (apply) { await pool.request().batch(p); console.log(db,n,'applied'); } else console.log(db,n,'patch ok (dry)');
  }
  await pool.close();
}
fs.mkdirSync('tmp/patched',{recursive:true}); for (const [n,p] of Object.entries(out)) fs.writeFileSync(`tmp/patched/${n}.sql`,p);
process.exit(0);
