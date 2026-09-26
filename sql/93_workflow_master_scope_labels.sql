-- ============================================================
-- Approval Workflow list — division short name + branches per workflow
-- Database : Non_Trade / Non_trade_Dev (MSSQL, 10.0.21.8)
-- Used by  : GET /api/workflow_approval/getWorkflows -> Approval Workflows screen
--
-- Why
-- ---
-- The workflow dropdown showed "<workflow_name> (<workflow_code>)", e.g.
-- "PurchaseRequisition Approval Workflow (WF_PURCHASEREQUISITION_016)". Too long,
-- and three different PR workflows were all called the same thing, told apart only
-- by that code. The screen now builds a short label ("PR · TCS · TCS-Coimbatore",
-- or just "KYC") — but a workflow's division/branches live on its workflow_types
-- rows, not on approval_workflow_master, which is all this procedure returned.
--
-- What changed
-- ------------
-- sp_nt_GetWorkflowMasters returns two extra columns, both '|'-delimited so the
-- caller can shorten/join them however it likes:
--     division_short  distinct division prefixes of the workflow's ACTIVE types
--     branch_names    distinct branch names of the workflow's ACTIVE types
-- Existing columns, ordering and the is_active filter are unchanged, so nothing
-- else that reads this list (entity-type counts, the entity dropdown) is affected.
-- A workflow with no active types gets '' for both.
--
-- Rollback: sql/backups/pre_workflow_master_labels_2026-09-24_ROLLBACK.sql
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetWorkflowMasters
AS
BEGIN
    SET NOCOUNT ON;

    SELECT awm.workflow_id,
           awm.workflow_code,
           awm.workflow_name,
           awm.entity_type,
           awm.description,
           awm.is_active,
           ISNULL(scope.division_short, N'') AS division_short,
           ISNULL(scope.branch_names,   N'') AS branch_names
    FROM dbo.approval_workflow_master AS awm
    OUTER APPLY (
        SELECT
            (SELECT STRING_AGG(x.div_prefix, N'|') WITHIN GROUP (ORDER BY x.div_prefix)
             FROM (SELECT DISTINCT CAST(LTRIM(RTRIM(d.div_prefix)) AS NVARCHAR(50)) AS div_prefix
                   FROM dbo.workflow_types AS wt
                   JOIN dbo.division_master AS d ON d.div_sno = wt.div_sno
                   WHERE wt.workflow_id = awm.workflow_id
                     AND wt.is_active = 'Y'
                     AND NULLIF(LTRIM(RTRIM(d.div_prefix)), N'') IS NOT NULL) AS x) AS division_short,
            (SELECT STRING_AGG(y.brn_name, N'|') WITHIN GROUP (ORDER BY y.brn_name)
             FROM (SELECT DISTINCT CAST(LTRIM(RTRIM(b.brn_name)) AS NVARCHAR(200)) AS brn_name
                   FROM dbo.workflow_types AS wt
                   JOIN dbo.branch_master AS b ON b.brn_sno = wt.brn_sno
                   WHERE wt.workflow_id = awm.workflow_id
                     AND wt.is_active = 'Y'
                     AND NULLIF(LTRIM(RTRIM(b.brn_name)), N'') IS NOT NULL) AS y) AS branch_names
    ) AS scope
    WHERE awm.is_active = 'Y'
    ORDER BY awm.workflow_name;
END;
GO
