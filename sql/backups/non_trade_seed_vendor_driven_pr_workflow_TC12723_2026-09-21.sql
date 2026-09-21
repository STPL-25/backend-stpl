-- Record of the seed applied to Non_Trade (PRODUCTION) on 2026-09-21. NOT for Non_trade_Dev: the org ids below are
-- Non_Trade's (com 1 / div 3 / brn 4 / dept 1 = TCS-Coimbatore Canteen). Idempotent.
--
-- What it does: registers the VendorDrivenPurchaseRequisition entity type (so the Approval Workflow screen's
-- "Entity Type" dropdown offers it) and creates a one-stage workflow whose approver is ecno TC12723
-- (canteen incharge; already the approver of Non_Trade's Canteen PR/PO workflows 26/29).
-- Applied via sp_nt_SaveFullWorkflow, exactly as the app does -> workflow_id 11, code
-- WF_VENDORDRIVENPURCHASEREQUISITION_001, workflow_types_id 33.
--
-- Rollback: soft-delete via the Approval Workflow screen, or:
--   UPDATE dbo.approval_workflow_master SET is_active='N' WHERE workflow_id=11;
--   UPDATE dbo.workflow_types SET is_active='N' WHERE workflow_types_id=33;

IF NOT EXISTS (SELECT 1 FROM dbo.entity_master WHERE entity_code = 'VendorDrivenPurchaseRequisition')
    INSERT INTO dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by)
    VALUES (N'Vendor Driven Purchase Requisition', N'VendorDrivenPurchaseRequisition',
            N'Supplier-first requisitions with commercial values and verification documents.', 'Y', N'system');
GO

IF NOT EXISTS (SELECT 1 FROM dbo.approval_workflow_master WHERE entity_type = 'VendorDrivenPurchaseRequisition')
BEGIN
    DECLARE @payload NVARCHAR(MAX) = N'{
      "workflow_name": "VendorDrivenPurchaseRequisition Approval Workflow",
      "entity_type": "VendorDrivenPurchaseRequisition",
      "description": "Vendor-driven (canteen) purchase requisition approval",
      "is_active": "Y", "created_by": "system",
      "workflow_types": [{
        "workflow_types_name": "Canteen - Vendor Driven PR", "workflow_types_description": "",
        "com_sno": 1, "div_sno": 3, "brn_sno": 4, "dept_sno": 1, "is_active": "Y",
        "stage_order_json": "[{\"approver_ecno\":\"TC12723\",\"stage\":\"Canteen Incharge\",\"required_approvals\":\"1\",\"is_mandatory\":\"Y\",\"escalation_hours\":\"24\",\"approver_condition\":\"\",\"next_approver_ecno\":\"\",\"can_forward\":\"Y\",\"can_backward\":\"N\",\"can_edit_data\":\"N\"}]"
      }]
    }';
    EXEC dbo.sp_nt_SaveFullWorkflow @jsonInput = @payload;
END
GO
