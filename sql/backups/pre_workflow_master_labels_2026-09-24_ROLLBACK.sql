-- ROLLBACK for sql/93_workflow_master_scope_labels.sql
-- Restores sp_nt_GetWorkflowMasters to the definition that was live on BOTH
-- Non_Trade and Non_trade_Dev on 2026-09-24 (identical on both, 317 chars).
-- Run: node sql/run_sql.mjs sql/backups/pre_workflow_master_labels_2026-09-24_ROLLBACK.sql
-- The extra columns (division_short, branch_names) are additive, so the frontend
-- keeps working after a rollback — it just falls back to the entity name.

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetWorkflowMasters
AS
BEGIN
    SET NOCOUNT ON;

    SELECT workflow_id,
           workflow_code,
           workflow_name,
           entity_type,
           description,
           is_active
    FROM dbo.approval_workflow_master
    WHERE is_active = 'Y'
    ORDER BY workflow_name;
END;
GO
