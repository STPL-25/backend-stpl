import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_trade_Dev',options:{trustServerCertificate:true,encrypt:false}}).connect();
const run = async (sp, o) => (await pool.request().input('jsonInput', sql.NVarChar(sql.MAX), JSON.stringify(o)).execute(sp)).recordset;
console.log(JSON.stringify(await run('sp_nt_ApproveServicePoCycle',{cycle_sno:1018,approval_stages:[],approved_by:'ED001',action:'forward'})));
console.log(JSON.stringify(await run('sp_approve_service_agreement',{agreement_sno:5062,approval_stages:[],approved_by:'ED001',action:'send_back',send_back_to:'x',comments:'y'})));
console.log(JSON.stringify(await run('sp_approve_service_agreement',{agreement_sno:5062,approval_stages:[],approved_by:'ED001',action:'bogus'})));
console.log(JSON.stringify((await pool.request().query(`select status,current_approver_id from service_po_cycle where cycle_sno=1018`)).recordset));
process.exit(0);
