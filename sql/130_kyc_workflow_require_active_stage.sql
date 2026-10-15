-- ============================================================
-- 130_kyc_workflow_require_active_stage.sql
-- fn_scopeless_workflow_types (used by sp_InsertKYCData for KYC) only checked
-- approval_workflow_master.is_active and workflow_types.is_active. A workflow_types row whose
-- workflow_stage rows are all inactive ('N') was still picked, so KYCs were routed to a flow with
-- no usable approver. It now also requires at least one ACTIVE workflow_stage row.
-- If nothing qualifies it returns NULL and sp_InsertKYCData throws 50008
-- ("No active KYC approval workflow is configured.") instead of routing to a dead flow.
-- NOT yet applied anywhere. Dry-run first: SELECT dbo.fn_scopeless_workflow_types('KYC');
-- ============================================================
CREATE OR ALTER FUNCTION dbo.fn_scopeless_workflow_types (@entity VARCHAR(50))
RETURNS INT
AS
BEGIN
    RETURN (SELECT TOP 1 wt.workflow_types_id
            FROM dbo.workflow_types wt
            JOIN dbo.approval_workflow_master a ON a.workflow_id = wt.workflow_id
            WHERE a.entity_type = @entity
              AND a.is_active  = 'Y'
              AND wt.is_active = 'Y'
              AND EXISTS (SELECT 1 FROM dbo.workflow_stage s
                          WHERE s.workflow_types_id = wt.workflow_types_id AND s.is_active = 'Y')
            ORDER BY wt.workflow_types_id);
END;
GO
