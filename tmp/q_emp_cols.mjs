import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv();
const pool = await new sql.ConnectionPool({
  user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD,
  server: process.env.SERVER, database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433,
  options: { trustServerCertificate: true }, connectionTimeout: 15000,
}).connect();
console.log("DB:", process.env.DATABASE);
const q = async (t) => { try { return (await pool.request().query(t)).recordset; } catch (e) { return e.message; } };
console.log("vw_verified_employees cols:", await q(`SELECT c.name, ty.name t FROM sys.columns c JOIN sys.types ty ON ty.user_type_id=c.user_type_id WHERE object_id=OBJECT_ID('vw_verified_employees')`));
console.log("nt_sign_up cols:", await q(`SELECT c.name FROM sys.columns c WHERE object_id=OBJECT_ID('nt_sign_up')`));
console.log("view def:", await q(`SELECT LEFT(OBJECT_DEFINITION(OBJECT_ID('vw_verified_employees')),1500) d`));
console.log("sp_nt_Login:", await q(`SELECT OBJECT_DEFINITION(OBJECT_ID('sp_nt_Login')) d`));
await pool.close();
