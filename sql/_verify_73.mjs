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

const q = async (label, query) => {
  const r = await pool.request().query(query);
  console.log(`\n--- ${label} ---`);
  console.table(r.recordset);
};

await q("service_type_master", "SELECT service_type_sno, service_type_code, service_type_name FROM dbo.service_type_master ORDER BY service_type_sno");
await q("recurrence_cadence_master", "SELECT recurrence_cadence_sno, cadence_code, interval_unit, interval_value FROM dbo.recurrence_cadence_master ORDER BY recurrence_cadence_sno");
await q("entity_master ServiceAgreement", "SELECT entity_sno, entity_code, entity_name FROM dbo.entity_master WHERE entity_code = 'ServiceAgreement'");
await q("screens", "SELECT screen_id, screen_name, comp, group_id, display_order FROM dbo.screens WHERE comp LIKE 'ServiceAgreement%'");
await q("procs", `
  SELECT name FROM sys.procedures
  WHERE OBJECT_ID(name) IN (
    OBJECT_ID('sp_nt_CreateServiceAgreement'), OBJECT_ID('sp_nt_UpdateServiceAgreement'),
    OBJECT_ID('sp_approve_service_agreement'), OBJECT_ID('sp_nt_GetServiceAgreements'),
    OBJECT_ID('sp_nt_GetServiceAgreementsForApproval'), OBJECT_ID('sp_nt_DirectIssueServicePO'),
    OBJECT_ID('sp_nt_IssueRecurringServicePOCycle'), OBJECT_ID('sp_nt_ProcessDueRecurringServiceAgreements'),
    OBJECT_ID('sp_nt_ExpireServiceAgreements'), OBJECT_ID('sp_nt_GetAgreementsDueForNotification'),
    OBJECT_ID('sp_nt_MarkAgreementNotificationSent'), OBJECT_ID('sp_nt_GetApprovedVendorsForServicePicker'),
    OBJECT_ID('sp_nt_GetServiceTypeRecords'), OBJECT_ID('sp_nt_CreateServiceTypeRecords'),
    OBJECT_ID('sp_nt_GetServiceRecords'), OBJECT_ID('sp_nt_CreateServiceRecords'),
    OBJECT_ID('sp_nt_GetRecurrenceCadenceRecords'), OBJECT_ID('sp_nt_CreateRecurrenceCadenceRecords'),
    OBJECT_ID('sp_nt_GrantScreenToUser')
  )
  ORDER BY name`);

// Existing org scope + workflow config to reuse for a test agreement, per
// the old system's precedent (com_sno=14/div_sno=14/brn_sno=13/dept_sno=15,
// approver KTM1148) — confirm it's still the live setup before assuming.
await q("existing workflow_types for ServiceAgreement entity", `
  SELECT wt.workflow_types_id, wt.com_sno, wt.div_sno, wt.brn_sno, wt.dept_sno, awm.entity_type, awm.workflow_id
  FROM dbo.workflow_types wt
  JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
  WHERE awm.entity_type = 'ServiceAgreement'`);

await pool.close();
