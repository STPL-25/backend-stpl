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
console.log("vw_Sign_Up def:", (await q(`SELECT OBJECT_DEFINITION(OBJECT_ID('vw_Sign_Up')) d`))[0]?.d);
console.log("counts:", await q(`SELECT COUNT(*) n, SUM(CASE WHEN dept_sno IS NULL THEN 1 ELSE 0 END) nodept, SUM(CASE WHEN com_sno IS NULL THEN 1 ELSE 0 END) nocom FROM nt_sign_up`));
console.log("compare (app dept vs HR dept):", await q(`
SELECT TOP 60 s.ecno, s.dept_sno, s.brn_sno, s.div_sno, s.com_sno, s.dept AS signup_dept_txt, s.branch AS signup_branch_txt,
       e.dept AS hr_dept, e.BRANCH AS hr_branch
FROM nt_sign_up s LEFT JOIN vw_verified_employees e ON e.ecno = s.ecno
ORDER BY s.ecno`));
console.log("dept master cols:", await q(`SELECT c.name FROM sys.columns c WHERE object_id=OBJECT_ID('dept_master') OR object_id=OBJECT_ID('nt_dept_master')`));
console.log("dept-ish tables:", await q(`SELECT name FROM sys.tables WHERE name LIKE '%dept%'`));
await pool.close();
