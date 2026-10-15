import sql from 'mssql';
for (const db of ['Non_Trade','Non_trade_Dev']) {
  const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
  console.log('=====',db);
  for (const n of ['usp_InsertPurchaseRequest','sp_nt_ResolveWorkflow']) {
    const d=(await pool.request().query(`select definition from sys.sql_modules where object_id=object_id('${n}')`)).recordset[0]?.definition||'';
    const lines=d.split('\n'); 
    console.log('--',n,lines.length,'lines');
    lines.forEach((l,i)=>{ if(/workflow|is_active|current_approver|approver_ecno/i.test(l)) console.log(i+1+': '+l.trim().slice(0,200)); });
  }
  await pool.close();
}
process.exit(0);
