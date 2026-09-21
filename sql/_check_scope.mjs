import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv();

const config = {
  user: process.env.DB_USER,
  password: process.env.DB_USER_PASSWORD,
  server: process.env.SERVER,
  database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433,
  options: { trustServerCertificate: true, enableArithAbort: true },
  connectionTimeout: 15000,
  requestTimeout: 30000,
  pool: { max: 2, min: 0, idleTimeoutMillis: 5000 },
};

const pool = await new sql.ConnectionPool(config).connect();

const exec = async (label, proc, filterFn) => {
  const r = await pool.request().execute(proc);
  const rows = filterFn ? r.recordset.filter(filterFn) : r.recordset;
  console.log(`\n--- ${label} (${r.recordset.length} total) ---`);
  console.table(rows.slice(0, 5));
};

const q = async (label, query) => {
  const r = await pool.request().query(query);
  console.log(`\n--- ${label} ---`);
  console.table(r.recordset);
};

await exec("CompanyMaster com_sno=14", "sp_nt_GetCompanyRecords", (r) => r.com_sno === 14);
await exec("DivisionMaster div_sno=14", "sp_nt_GetDivisionsRecords", (r) => r.div_sno === 14);
await exec("BranchMaster brn_sno=13", "sp_nt_GetBranchesRecords", (r) => r.brn_sno === 13);
await exec("DeptMaster dept_sno=15", "sp_nt_GetDeptRecords", (r) => r.dept_sno === 15);

await q("KTM1148 in nt_sign_up", "SELECT TOP 1 * FROM dbo.nt_sign_up WHERE ecno = 'KTM1148'");
await q("KTM1148 nt_user_permissions_json", "SELECT TOP 1 user_perm_json_sno, ecno, is_active FROM dbo.nt_user_permissions_json WHERE ecno = 'KTM1148' AND is_active = 'Y' ORDER BY user_perm_json_sno DESC");
await q("approved vendors", "SELECT TOP 3 kyc_basic_info_sno, company_name, supp_code FROM dbo.kyc_basic_info WHERE status = 'A' AND is_active = 'Y'");
await q("uom sample", "SELECT TOP 3 uom_sno, uom_name FROM dbo.uom_master WHERE is_active = 'Y'");

await pool.close();
