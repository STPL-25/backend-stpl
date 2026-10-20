import sql from 'mssql';
for (const db of ['Non_trade_Dev','Non_Trade']){
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
console.log(db,(await pool.request().query(`select name from sys.objects where name in ('service_grn','sp_nt_CreateServiceGrn','sp_nt_GetPendingServiceGrnPOs','sp_nt_GetServiceGrns','sp_nt_GetServicePoDispatchInfo') union all select 'col:'+name from sys.columns where object_id=object_id('service_master') and name='incharge_ecno' union all select 'col:dispatch_type' from sys.columns where object_id=object_id('service_agreement') and name='dispatch_type'`)).recordset.map(r=>r.name));
}
process.exit(0);
