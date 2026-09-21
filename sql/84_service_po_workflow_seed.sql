-- ============================================================
-- 84_service_po_workflow_seed.sql
--
-- Seeds a starter ServicePO approval workflow, same shape/scope as the
-- existing ServiceAgreement one (workflow_types_id=30: com=1/div=1/brn=1/
-- dept=1, single "Manager Approval" stage, approver KTM1148) — needed
-- before sp_nt_ResolveServicePoWorkflow (sql/83) can resolve anything; until
-- this exists, every Fixed cycle auto-queue and every Unfixed entry
-- submission throws "No ServicePO workflow configuration found".
--
-- Done via direct SQL rather than through the ApprovalWorkflowManager.tsx
-- UI this would normally go through, purely to unblock end-to-end
-- verification of sql/83 without UI login access this session — same
-- approver as the sibling ServiceAgreement workflow (a reasonable,
-- low-risk default given they're closely related approvals), confirmed
-- with the user before running. An admin should review/reassign via the
-- normal UI whenever convenient.
--
-- Idempotent — skips if a ServicePO workflow already exists for this org
-- scope.
-- ============================================================

IF NOT EXISTS (
    SELECT 1 FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE wt.com_sno = 1 AND wt.div_sno = 1 AND wt.brn_sno = 1 AND wt.dept_sno = 1
      AND awm.entity_type = 'ServicePO'
)
BEGIN
    INSERT INTO dbo.approval_workflow_master (workflow_name, workflow_code, entity_type, description, is_active, created_by, created_at)
    VALUES (N'ServicePO Approval Workflow', N'WF_SERVICEPO_SEED', N'ServicePO', N'Starter workflow, same scope/approver as the ServiceAgreement workflow (workflow_id 25) — review via Approval Workflow Manager.', 'Y', N'system', GETDATE());

    DECLARE @new_workflow_id INT = SCOPE_IDENTITY();

    INSERT INTO dbo.workflow_types (workflow_types_name, workflow_id, workflow_name, is_active, brn_sno, dept_sno, com_sno, div_sno, workflow_types_description, created_by, created_at)
    VALUES (N'CBE3-IT-ServicePO', @new_workflow_id, N'ServicePO Approval Workflow', 'Y', 1, 1, 1, 1, N'SKTM-Coimbatore / Information Technology service PO cycles', N'system', GETDATE());

    DECLARE @new_workflow_types_id INT = SCOPE_IDENTITY();

    INSERT INTO dbo.workflow_stage (workflow_types_id, stage_order_json, is_active, created_by, created_at)
    VALUES (
        @new_workflow_types_id,
        N'[{"approver_ecno":"KTM1148","stage":"Manager Approval","required_approvals":"1","is_mandatory":"Y","escalation_hours":"24","approver_condition":"","next_approver_ecno":"","can_forward":"Y","can_backward":"N","can_edit_data":"N"}]',
        'Y', N'system', GETDATE()
    );
END;
GO
