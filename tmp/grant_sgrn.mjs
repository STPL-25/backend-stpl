import sql from 'mssql';
const db=process.argv[2];
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
const s=(await pool.request().query(`select screen_id,screen_name,comp from screens where comp in ('ServiceGrnPage','ServicePOPage','ServiceAgreementPage') or comp like 'Service%'`)).recordset;
console.log(db,s);
const u=(await pool.request().query(`select user_perm_json_sno,is_active,screens_json from nt_user_permissions_json where ecno='KTM1148'`)).recordset;
for(const r of u){console.log(r.user_perm_json_sno,r.is_active);try{const j=JSON.parse(r.screens_json.trim());console.log(j.filter(x=>s.some(y=>y.screen_id==x.screen_id)))}catch(e){console.log('parse',e.message)}}
process.exit(0);
