import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv();
const pool = await new sql.ConnectionPool({
  user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD,
  server: process.env.SERVER, database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433,
  options: { trustServerCertificate: true, enableArithAbort: true },
  connectionTimeout: 15000, requestTimeout: 60000,
  pool: { max: 2, min: 0, idleTimeoutMillis: 5000 },
}).connect();

const r1 = await pool.request().query(`SELECT * FROM dbo.service_vendor_kyc`);
console.log("service_vendor_kyc:", JSON.stringify(r1.recordset, null, 2));

const r2 = await pool.request().query(`SELECT * FROM dbo.service_vendor_kyc_history ORDER BY history_sno`);
console.log("service_vendor_kyc_history:", JSON.stringify(r2.recordset, null, 2));

const r3 = await pool.request().query(`SELECT * FROM dbo.kyc_basic_info WHERE supp_code LIKE 'SVK-%'`);
console.log("kyc_basic_info (SVK-provisioned):", JSON.stringify(r3.recordset, null, 2));

await pool.close();
process.exit(0);
