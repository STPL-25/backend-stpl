import sql from "mssql";import {configDotenv} from "dotenv";configDotenv();
const p=await new sql.ConnectionPool({server:process.env.DB_HOST,user:process.env.DB_USER,password:process.env.DB_PASS,database:process.env.DB_NAME,options:{encrypt:false,trustServerCertificate:true}}).connect();
const fks=(await p.request().query(`select child=object_name(parent_object_id), parent=object_name(referenced_object_id) from sys.foreign_keys`)).recordset;
const roots=['kyc_basic_info','service_vendor_kyc','po_request_info','supplier_quotation_info'];
const set=new Set(roots);let ch=true;
while(ch){ch=false;for(const f of fks)if(set.has(f.parent)&&!set.has(f.child)){set.add(f.child);ch=true}}
// order: delete child before parent
const order=[];const seen=new Set();
function visit(t){if(seen.has(t))return;seen.add(t);for(const f of fks)if(f.parent===t&&f.child!==t&&set.has(f.child))visit(f.child);order.push(t)}
[...set].forEach(visit);
for(const t of order){const c=(await p.request().query(`select count(*) c from [${t}]`)).recordset[0].c;console.log(t,c)}
const self=fks.filter(f=>f.child===f.parent&&set.has(f.child));console.log('self',self);
process.exit(0)
