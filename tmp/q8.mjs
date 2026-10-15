import sql from 'mssql';
const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:'Non_Trade',options:{trustServerCertificate:true,encrypt:false}}).connect();
const q=async s=>JSON.stringify((await pool.request().query(s)).recordset);
console.log(await q(`select * from workflow_types where workflow_types_id in (82,60)`));
console.log(await q(`select stage_id,workflow_types_id,is_active,created_by,created_at,modified_by,modified_at,modified_data from workflow_stage where workflow_types_id in (82,60)`));
console.log(await q(`select workflow_types_id,count(*) n from pr_basic_info where workflow_types_id in (82,60) group by workflow_types_id`));
console.log((await pool.request().query(`select definition from sys.sql_modules where object_id=object_id('trg_pr_basic_info_approval_instance')`)).recordset[0].definition);
process.exit(0);
