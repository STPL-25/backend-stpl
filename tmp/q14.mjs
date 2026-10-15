import sql from 'mssql';
const names=process.argv.slice(2);
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_Trade',options:{trustServerCertificate:true,encrypt:false}}).connect();
const r=(await pool.request().query(`select o.name,m.definition d from sys.sql_modules m join sys.objects o on o.object_id=m.object_id where m.definition like '%workflow_types%' or m.definition like '%vw_workflow_stages%'`)).recordset;
for (const x of r){ if(/^sp_nt_(Get|Resolve|Save|Delete|Update)Workflow|Approval|PrApproval/.test(x.name)&&!/Create|Submit|Direct|Issue/.test(x.name)) {}
 const L=x.d.split('\n'); const hits=[]; L.forEach((l,i)=>{ if(/workflow_types|vw_workflow_stages|workflow_stage/i.test(l)) hits.push(i); });
 if(!hits.length) continue;
 console.log('#####',x.name,'('+L.length+' lines)'); const shown=new Set();
 for(const h of hits) for(let k=Math.max(0,h-1);k<=Math.min(L.length-1,h+4);k++) if(!shown.has(k)){shown.add(k);console.log(String(k+1).padStart(4)+': '+L[k].replace(/\r/,'').slice(0,160));}
}
process.exit(0);
