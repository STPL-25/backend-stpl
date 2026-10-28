import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv({ quiet: true });
const pool = await new sql.ConnectionPool({
  user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD,
  server: process.env.SERVER, database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433,
  options: { trustServerCertificate: true }, connectionTimeout: 15000,
}).connect();
const q = async (t) => { try { return (await pool.request().query(t)).recordset; } catch (e) { return e.message; } };
console.log("sp_nt_sign_up:", (await q(`SELECT OBJECT_DEFINITION(OBJECT_ID('sp_nt_sign_up')) d`))[0]?.d);
console.log("dept_master:", await q(`SELECT dept_sno,com_sno,div_sno,brn_sno,dept_name,dept_code,is_active FROM dept_master ORDER BY brn_sno,dept_name`));
console.log("branches:", await q(`SELECT brn_sno,com_sno,div_sno,brn_name,brn_prefix FROM ActiveBranches ORDER BY brn_sno`));
console.log("HR distinct dept/branch of signed-up users:", await q(`SELECT DISTINCT dept, branch FROM nt_sign_up`));
await pool.close();
