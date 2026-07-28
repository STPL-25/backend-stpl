-- ============================================================
-- Rollback for 02_workflow_update_delete_procs.sql
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- 02_workflow_update_delete_procs.sql creates ten procedures that did not
-- exist before and replaces one that did. This undoes both:
--
--   * drops the ten new procedures
--   * restores sp_nt_GetWorkflowMasters to its exact pre-change definition,
--     captured from sys.sql_modules before it was replaced
--
-- No table or data changes are involved either way — this file is only needed
-- if the new procedures have to be backed out.
-- ============================================================

-- ── Drop the procedures added by 02_workflow_update_delete_procs.sql ───────

IF OBJECT_ID('dbo.sp_nt_GetWorkflowByEntity',  'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetWorkflowByEntity;
IF OBJECT_ID('dbo.sp_nt_UpdateWorkflowMaster', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_UpdateWorkflowMaster;
IF OBJECT_ID('dbo.sp_nt_DeleteWorkflow',       'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_DeleteWorkflow;
IF OBJECT_ID('dbo.sp_nt_SaveWorkflowType',     'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_SaveWorkflowType;
IF OBJECT_ID('dbo.sp_nt_UpdateWorkflowType',   'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_UpdateWorkflowType;
IF OBJECT_ID('dbo.sp_nt_DeleteWorkflowType',   'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_DeleteWorkflowType;
IF OBJECT_ID('dbo.sp_nt_GetWorkflowStages',    'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetWorkflowStages;
IF OBJECT_ID('dbo.sp_nt_SaveWorkflowStage',    'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_SaveWorkflowStage;
IF OBJECT_ID('dbo.sp_nt_UpdateWorkflowStage',  'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_UpdateWorkflowStage;
IF OBJECT_ID('dbo.sp_nt_DeleteWorkflowStage',  'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_DeleteWorkflowStage;
GO

-- ── Restore sp_nt_GetWorkflowMasters to its original definition ────────────
-- Original body, verbatim: no is_active column and no WHERE clause.

IF OBJECT_ID('dbo.sp_nt_GetWorkflowMasters', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetWorkflowMasters;
GO

CREATE PROCEDURE sp_nt_GetWorkflowMasters
AS
BEGIN
    SET NOCOUNT ON;

   select workflow_id,workflow_code,workflow_name,entity_type,description from approval_workflow_master

END;
GO

-- ── Undo any soft deletes made through the delete procedures ───────────────
-- Deletes only set is_active = 'N'; nothing is removed. To bring one workflow
-- back, run this with its id:
--
--   DECLARE @workflow_id INT = 12;
--
--   UPDATE dbo.approval_workflow_master SET is_active = 'Y' WHERE workflow_id = @workflow_id;
--   UPDATE dbo.workflow_types           SET is_active = 'Y' WHERE workflow_id = @workflow_id;
--   UPDATE dbo.workflow_stage           SET is_active = 'Y'
--   WHERE workflow_types_id IN (SELECT workflow_types_id FROM dbo.workflow_types WHERE workflow_id = @workflow_id);
--
-- modified_at on the affected rows shows when the delete happened.
-- ============================================================
