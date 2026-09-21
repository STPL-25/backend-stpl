// One-off setup: configures a ServiceAgreement approval workflow, grants the
// two new screens, and seeds two test services (Fixed + Unfixed) so the
// rebuilt feature can be exercised end-to-end. Uses the real stored
// procedures (sp_nt_SaveFullWorkflow, sp_nt_GrantScreenToUser,
// sp_nt_CreateServiceRecords) — same path the actual admin UI screens use.
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

async function execJson(proc, payload) {
  const request = pool.request();
  request.input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify(payload));
  const result = await request.execute(proc);
  return result.recordset;
}

console.log("1) sp_nt_SaveFullWorkflow (ServiceAgreement, scope 14/14/13/15, KTM1148)");
const workflowPayload = {
  workflow_name: "Service Agreement Approval",
  entity_type: "ServiceAgreement",
  description: "Test workflow for the rebuilt Service Agreement feature",
  is_active: "Y",
  created_by: "KTM1148",
  workflow_types: [
    {
      workflow_types_name: "Service Agreement - EDP",
      workflow_types_description: "Single-stage approval",
      com_sno: 14, div_sno: 14, brn_sno: 13, dept_sno: 15,
      is_active: "Y",
      stage_order_json: JSON.stringify([
        { approver_ecno: "KTM1148", stage: "Manager Approval", required_approvals: "1", is_mandatory: "Y", can_forward: "Y", can_backward: "Y", can_edit_data: "Y" },
      ]),
    },
  ],
};
try {
  const r = await execJson("sp_nt_SaveFullWorkflow", workflowPayload);
  console.log(JSON.stringify(r, null, 2));
} catch (e) {
  console.error("sp_nt_SaveFullWorkflow failed:", e.message);
}

console.log("\n2) Grant screens 60/61 to KTM1148");
for (const screen_id of [60, 61]) {
  try {
    const r = await execJson("sp_nt_GrantScreenToUser", { ecno: "KTM1148", screen_id, permission_ids: [2, 3, 4, 5, 7, 8] });
    console.log(`  screen ${screen_id}:`, JSON.stringify(r));
  } catch (e) {
    console.error(`  screen ${screen_id} FAILED:`, e.message);
  }
}

console.log("\n3) Seed test services");
// service_type_sno 1 = FIXED_RECURRING, 2 = VARIABLE_RECURRING (confirmed via earlier verify query)
try {
  const r1 = await execJson("sp_nt_CreateServiceRecords", {
    service_name: "TEST — Office Rent", service_code: "TESTSVC-RENT", service_type_sno: 1,
    default_uom_sno: 1, description: "Test fixed-recurring service for rebuild verification", created_by: "KTM1148",
  });
  console.log("  Fixed service:", JSON.stringify(r1));
} catch (e) { console.error("  Fixed service FAILED:", e.message); }

try {
  const r2 = await execJson("sp_nt_CreateServiceRecords", {
    service_name: "TEST — Electricity", service_code: "TESTSVC-ELEC", service_type_sno: 2,
    default_uom_sno: 1, description: "Test unfixed-recurring service for rebuild verification", created_by: "KTM1148",
  });
  console.log("  Unfixed service:", JSON.stringify(r2));
} catch (e) { console.error("  Unfixed service FAILED:", e.message); }

await pool.close();
