-- ============================================================
-- Company/Division/Branch access scoping — finish wiring an already
-- partially-built feature.
-- Database: Non_trade_Dev (MSSQL)
--
-- sp_nt_GetUserHierarchy, sp_get_pr_details_for_approval and
-- sp_nt_GetQuotationsForApproval already exist live with an @HierarchyJson
-- parameter (a prior, half-finished attempt at this same feature — no
-- matching Node code was ever committed). Those three needed NO SQL change,
-- only Node-side wiring (see backend-stpl/src/Middleware/hierarchyScope.js
-- and the PR/PO repository changes in this same commit).
--
-- sp_nt_GetApprovedPRsForPurchase also already has @HierarchyJson and uses
-- it correctly — its bug was purely on the Node side (PurchaseTeamRepository
-- wrapped it in a generic @jsonInput blob the SP never declared, so the
-- param was silently never bound). Also fixed in Node only, no SQL change.
--
-- This file's only actual schema/proc change: sp_nt_GetTermsConditionsRecords
-- had no scoping at all — every caller saw every company's T&C rows. Adding
-- the same optional @HierarchyJson pattern as the other procs above.
--
-- Convention (matches the existing procs, do not deviate): @HierarchyJson is
-- an OPENJSON array of {com_sno, div_sno, brn_sno}. NULL means "no filter"
-- (kept only for callers that intentionally want everything, e.g. future
-- admin tooling). The application layer is responsible for the actual
-- access-control default: an ecno with zero hierarchy_json rows must be
-- sent '[]' (an empty JSON array), never NULL, so EXISTS(...) is false for
-- every row and the caller sees nothing until an admin assigns them a
-- company/division/branch. See hierarchyScope.js for where that's enforced.
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetTermsConditionsRecords
    @HierarchyJson NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.tc_sno,
        t.tc_title,
        t.tc_text,
        t.com_sno,  c.com_name,
        t.div_sno,  d.div_name,
        t.brn_sno,  b.brn_name,
        t.dept_sno, dm.dept_name,
        t.is_default,
        t.is_active,
        t.created_by,
        CONVERT(VARCHAR(30), t.created_date, 120)  AS created_date,
        t.modified_by,
        CONVERT(VARCHAR(30), t.modified_date, 120) AS modified_date
    FROM dbo.terms_conditions_master t
    JOIN dbo.company_master  c  ON c.com_sno   = t.com_sno
    JOIN dbo.division_master d  ON d.div_sno   = t.div_sno
    JOIN dbo.branch_master   b  ON b.brn_sno   = t.brn_sno
    JOIN dbo.dept_master     dm ON dm.dept_sno = t.dept_sno
    WHERE t.is_active = 'Y'
      AND (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = t.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = t.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = t.brn_sno)
          )
      )
    ORDER BY c.com_name, d.div_name, b.brn_name, dm.dept_name, t.is_default DESC, t.tc_title;
END;
