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
console.log(await q(`SELECT screen_id,screen_name,screen_code,comp,comp_img,group_id,display_order,is_active FROM dbo.screens WHERE comp IN ('RoleApproval','ApprovalRoutingPage','ApprovalWorkflowPage')`));
console.log("branch_master cols:", (await q(`SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('branch_master')`)).map(r=>r.name).join(","));
console.log("division_master cols:", (await q(`SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('division_master')`)).map(r=>r.name).join(","));
console.log("company_master cols:", (await q(`SELECT name FROM sys.columns WHERE object_id=OBJECT_ID('company_master')`)).map(r=>r.name).join(","));
await pool.close();
