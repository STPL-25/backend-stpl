import sql from 'mssql';
for (const db of ['Non_Trade','Non_trade_Dev']) {
  const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
  console.log('=====',db);
  console.log((await pool.request().query(`select name from sys.columns where object_id=object_id('workflow_stage')`)).recordset.map(x=>x.name).join(','));
  const r = await pool.request().query(`select ws.*, wt.workflow_types_name from workflow_stage ws join workflow_types wt on wt.workflow_types_id=ws.workflow_types_id where ws.stage_order_json like '%KTM1141%'`);
  for (const x of r.recordset) console.log(x.workflow_types_id, x.workflow_types_name, '\n', x.stage_order_json);
  await pool.close();
}
process.exit(0);
