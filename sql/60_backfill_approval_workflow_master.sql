-- ============================================================
-- Backfill approval_workflow_master
-- Database: Non_trade_Dev (MSSQL)
--
-- approval_workflow_master (the entity_type registry that
-- usp_InsertPurchaseRequest / usp_InsertVendorDrivenPurchaseRequest /
-- sp_nt_CreateServicePO etc. all INNER JOIN against to resolve a workflow
-- for a given entity_type + org scope) was found completely empty on this
-- database — confirmed live, 0 rows — even though workflow_types/
-- workflow_stage already hold real, working-looking workflow rows
-- (PurchaseRequisition, PurchaseOrder, ServiceAgreement, ServicePO, etc.)
-- and workflow_code_sequence proves sp_nt_SaveFullWorkflow was genuinely
-- called many times historically (e.g. entity_type='PURCHASEREQUISITION'
-- last_seq=15). So approval_workflow_master was cleared/lost at some point
-- without workflow_types/workflow_stage being touched.
--
-- Net effect verified by reading usp_InsertPurchaseRequest's live body:
-- its workflow-resolution query REQUIRES a matching approval_workflow_master
-- row (INNER JOIN on workflow_id, filtered by entity_type) before it will
-- resolve a workflow_types_id at all — with the table empty, EVERY new
-- PR/PO/ServiceAgreement/etc. submission would throw "No workflow
-- configuration found" today. This is a pre-existing bug blocking normal
-- procurement, not something introduced by the Vendor-Driven PR feature —
-- but the new usp_InsertVendorDrivenPurchaseRequest proc (see
-- 61_vendor_driven_purchase_requisition.sql) uses the identical join
-- pattern, so it needs this fixed to work at all either way.
--
-- Backfills one approval_workflow_master row per distinct workflow_id
-- already referenced by workflow_types, inferring entity_type from the
-- existing workflow_name text (which already encodes it 1:1 today, e.g.
-- "ServiceAgreement Approval Workflow" -> entity_type='ServiceAgreement')
-- and matching entity_master.entity_code exactly. Idempotent — skips any
-- workflow_id that already has a row, safe to re-run.
-- ============================================================

SET IDENTITY_INSERT dbo.approval_workflow_master ON;

INSERT INTO dbo.approval_workflow_master (
    workflow_id, workflow_name, workflow_code, entity_type, description, is_active, created_by, created_at
)
SELECT
    src.workflow_id,
    src.workflow_name,
    'WF_LEGACY_' + CAST(src.workflow_id AS VARCHAR(10)),
    src.entity_type,
    'Backfilled from pre-existing workflow_types (approval_workflow_master was found empty live).',
    'Y',
    'system',
    GETDATE()
FROM (
    SELECT DISTINCT
        wt.workflow_id,
        wt.workflow_name,
        CASE wt.workflow_name
            WHEN 'PurchaseRequisition Approval Workflow' THEN 'PurchaseRequisition'
            WHEN 'PurchaseOrder Approval Workflow'        THEN 'PurchaseOrder'
            WHEN 'Masters Approval Workflow'               THEN 'Masters'
            WHEN 'KYC Approval Workflow'                   THEN 'KYC'
            WHEN 'ServiceAgreement Approval Workflow'      THEN 'ServiceAgreement'
            WHEN 'ServiceBillRequest Approval Workflow'    THEN 'ServiceBillRequest'
            WHEN 'ServiceVendorKYC Approval Workflow'      THEN 'ServiceVendorKYC'
            WHEN 'ServicePO Approval Workflow'             THEN 'ServicePO'
            ELSE NULL
        END AS entity_type
    FROM dbo.workflow_types wt
) src
WHERE src.entity_type IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM dbo.approval_workflow_master awm WHERE awm.workflow_id = src.workflow_id
  );

SET IDENTITY_INSERT dbo.approval_workflow_master OFF;
GO
