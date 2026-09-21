import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv();
const config = {
  user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD,
  server: process.env.SERVER, database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433,
  options: { trustServerCertificate: true, enableArithAbort: true },
  connectionTimeout: 15000, requestTimeout: 60000,
  pool: { max: 2, min: 0, idleTimeoutMillis: 5000 },
};
const pool = await new sql.ConnectionPool(config).connect();

const hist = await pool.request().query(`
  SELECT pr_basic_sno, status_by, status_date, commends, pr_edit_data
  FROM pr_history_data WHERE pr_basic_sno = 46 ORDER BY status_date
`);
console.log("PR 46 history:", hist.recordset);

const stages = await pool.request().query(`
  SELECT workflow_types_id, stage_order_json FROM workflow_stage WHERE workflow_types_id = 29 AND is_active='Y'
`);
console.log("\nWorkflow 29 stages:", stages.recordset);

const wf = await pool.request().query(`SELECT * FROM workflow_types WHERE workflow_types_id = 29`);
console.log("\nWorkflow 29 def:", wf.recordset);

await pool.close();
