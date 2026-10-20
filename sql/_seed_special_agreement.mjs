// Run AFTER sql/133_special_agreement.sql:   cd backend-stpl && node sql/_seed_special_agreement.mjs
// Seeds a starter Special Agreement approval workflow and grants the two new screens, through the
// app's own procedures (same path as the Approval Workflows / Role Approval screens).
//   - workflow: single stage, approver KTM1148, scope 1/1/1/1 (like the other Service workflows) - change
//     the approver / add stages / add other branches on the Approval Workflows screen.
//   - grants: KTM1148 only (the verification account used across this project). Anyone else is granted
//     through Role Approval.
// Re-runnable: skips the workflow if one already exists, the grant proc is idempotent.
import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv();

const pool = await new sql.ConnectionPool({
  user: process.env.DB_USER,
  password: process.env.DB_USER_PASSWORD,
  server: process.env.SERVER,
  database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433,
  options: { trustServerCertificate: true, enableArithAbort: true },
  connectionTimeout: 15000,
  requestTimeout: 30000,
}).connect();
console.log("Database:", process.env.DATABASE);

const execJson = async (proc, payload) => {
  const r = pool.request();
  r.input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify(payload));
  return (await r.execute(proc)).recordset;
};

const existing = await pool.request().query(
  "SELECT 1 x FROM dbo.approval_workflow_master WHERE entity_type = 'SpecialAgreement' AND is_active = 'Y'");
if (existing.recordset.length) {
  console.log("Workflow already exists - skipped.");
} else {
  console.log(await execJson("sp_nt_SaveFullWorkflow", {
    workflow_name: "Special Agreement Approval",
    entity_type: "SpecialAgreement",
    description: "Approval of product rate agreements (Fixed / Unfixed)",
    is_active: "Y",
    created_by: "KTM1148",
    workflow_types: [{
      workflow_types_name: "Special Agreement - Head Office",
      workflow_types_description: "Single-stage approval",
      com_sno: 1, div_sno: 1, brn_sno: 1, dept_sno: 1,
      is_active: "Y",
      stage_order_json: JSON.stringify([{
        approver_ecno: "KTM1148", stage: "Manager Approval", required_approvals: "1", is_mandatory: "Y",
        escalation_hours: "24", can_forward: "Y", can_backward: "N", can_edit_data: "N",
      }]),
    }],
  }));
}

for (const comp of ["SpecialAgreementPage", "SpecialAgreementApprovalScreen"]) {
  const s = await pool.request().query(`SELECT screen_id FROM dbo.screens WHERE comp = '${comp}'`);
  const screen_id = s.recordset[0]?.screen_id;
  if (!screen_id) { console.log(`Screen ${comp} not found - did sql/133 run?`); continue; }
  console.log(comp, screen_id, await execJson("sp_nt_GrantScreenToUser", { ecno: "KTM1148", screen_id, permission_ids: [2, 3, 4, 5, 7, 8] }));
}
await pool.close();
