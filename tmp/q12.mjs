import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
for (const n of ['sp_nt_GetWorkflowTypes','sp_nt_GetWorkflowStages','sp_nt_DeleteWorkflowType','sp_nt_DeleteWorkflowStage']) console.log('-----',n,'\n',(await pool.request().query(`select definition from sys.sql_modules where object_id=object_id('${n}')`)).recordset[0].definition);
process.exit(0);
