-- ============================================================
-- Fix: non-staff approvers (e.g. IA001) saw an EMPTY PO approval screen.
-- Database: Non_Trade + Non_trade_Dev (MSSQL)
--
-- Root cause (reported 2026-09-24, IA001 "no details shown" on PO Approvals):
--
-- Every org-scoped GET endpoint runs the attachHierarchyScope middleware,
-- which calls sp_nt_GetUserHierarchy(@Ecno = req.user_ecno) and hands the
-- result to the endpoint's SP as @HierarchyJson. For a non-staff login,
-- req.user_ecno is the LOGIN ID ("IA001") — getEcnoFromUser falls back to
-- login_id, see project-nonstaff-dashboard-merge — but non-staff permission
-- rows in nt_user_permissions_json are keyed by login_id with ecno = NULL
-- (32_nonstaff_role_approval.sql). sp_nt_GetUserHierarchy only matched
-- `ecno = @Ecno`, so it returned zero rows for every non-staff user.
--
-- The middleware is deliberately fail-closed: no rows -> hierarchyJson = []
-- (never NULL, since NULL means "no filter"). sp_nt_GetQuotationsForApproval
-- then evaluates EXISTS(SELECT 1 FROM OPENJSON('[]') ...) = false for every
-- row and returns nothing — even though IA001 has a pending quotation
-- (PR26270016-1) assigned to them. Verified live: the same SP with
-- @HierarchyJson = NULL or IA001's real hierarchy returns that row; with
-- '[]' it returns 0.
--
-- Same latent defect affected every other hierarchy-scoped endpoint for any
-- non-staff user (PR approvals, masters, inventory, GRN, ...): they were all
-- silently seeing nothing. This one shared read fixes them all.
--
-- Fix: fall back to the login_id-keyed row when no staff (ecno) row exists.
-- A staff ecno match always wins (ORDER BY), and the login_id branch is
-- restricted to rows where ecno IS NULL so it can never pick up a staff
-- user's row. Return shape is unchanged (com_sno, div_sno, brn_sno,
-- dept_sno), so no consumer changes.
--
-- Re-runnable (CREATE OR ALTER). Rollback:
-- backups/nonstaff_hierarchy_2026-09-24_ROLLBACK.sql
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetUserHierarchy
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX);
    SELECT TOP 1 @HierarchyJson = hierarchy_json
    FROM dbo.nt_user_permissions_json
    WHERE is_active = 'Y'
      AND (ecno = @Ecno OR (ecno IS NULL AND login_id = @Ecno))
    ORDER BY CASE WHEN ecno = @Ecno THEN 0 ELSE 1 END,
             user_perm_json_sno DESC;

    SELECT com_sno, div_sno, brn_sno, dept_sno
    FROM OPENJSON(@HierarchyJson)
    WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno', dept_sno INT '$.dept_sno');
END;
GO
