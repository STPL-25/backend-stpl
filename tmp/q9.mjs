import sql from 'mssql';
const defs={};
for (const db of ['Non_Trade','Non_trade_Dev']) {
  const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
  const r=await pool.request().query(`select o.name, m.definition from sys.sql_modules m join sys.objects o on o.object_id=m.object_id where m.definition like '%workflow_stage%' and o.type in ('P','TR','FN','IF','TF')`);
  defs[db]=Object.fromEntries(r.recordset.map(x=>[x.name,x.definition]));
  await pool.close();
}
const names=new Set([...Object.keys(defs.Non_Trade),...Object.keys(defs.Non_trade_Dev)]);
for(const n of [...names].sort()) console.log(n, defs.Non_Trade[n]===undefined?'ONLY-DEV':defs.Non_trade_Dev[n]===undefined?'ONLY-PROD':defs.Non_Trade[n]===defs.Non_trade_Dev[n]?'same':'DIFF');
process.exit(0);
