-- ============================================================
-- Fix: department-level access grants were silently widened to full-branch
-- access, and inventory items never carried a department at all.
-- Database: Non_trade_Dev (MSSQL)
--
-- Root cause (KTM1006's "given access only to Canteen but sees all
-- inventory" report, 2026-09-15):
--
-- 1. sp_nt_GetUserHierarchy (the single shared source every @HierarchyJson
--    filter in this rollout reads from — see [project-ecno-org-scope-and-
--    grn-fifo] memory) only ever returned com_sno/div_sno/brn_sno. Even a
--    correctly department-scoped hierarchy_json row like {com:1,div:3,
--    brn:4,dept:16} came back as just {com:1,div:3,brn:4} — indistinguishable
--    from real full-branch access. Fixed here: dept_sno now included.
--    Safe/additive for every other already-scoped endpoint (PR/PO/
--    PurchaseTeam/TermsConditions/GRN/StockRequests/Masters) — their own
--    OPENJSON...WITH clauses don't project dept_sno, so the extra field is
--    silently ignored there; only a consumer that explicitly adds a
--    dept_sno column to its WITH clause (sp_nt_GetInventoryItems below)
--    actually gains department precision.
--
-- 2. Separately, UserRoleApprovalScreen.tsx's buildHierarchyPayload()
--    treats selectedCompanies/selectedDivisions/selectedBranches/
--    selectedDepartments as four INDEPENDENT arrays and writes one
--    hierarchy_json row per selected id at EVERY level, not just the
--    deepest one. Drilling down through the company/division/branch
--    pickers to reach a department (a natural interaction, since each
--    list is filtered by the parent's selection) checks each intermediate
--    level along the way, and each becomes its own full-width grant. This
--    is why KTM1006 ended up with three rows — {com:1}, {com:1,div:3},
--    {com:1,div:3,brn:4} — and no dept:16 row at all: the department step
--    was never actually reached/checked. Not fixed by this SQL file (it's
--    a frontend/UX issue) — KTM1006's bad rows are corrected by hand below,
--    and admins granting department-only access need to leave the
--    Company/Division/Branch pickers unchecked and select only the
--    Department, until that screen is reworked.
--
-- 3. Even with correct hierarchy_json, nt_inventory_items never had a
--    dept_sno populated on receipt — sp_nt_UpsertInventoryItemByProduct
--    (called from grn-service's receiveFromGRN, which DOES already
--    resolve dept_sno from the GRN's own org context) never accepted or
--    stored it. Fixed in grn-service/sql/34_inventory_dept_scope_fix.sql,
--    which also backfills the 3 existing Canteen items (Carrot/Tomato/
--    Onion, all received under dept_sno=16 per their real GRN history)
--    since they predate this fix and would otherwise stay invisible to a
--    correctly department-scoped user forever.
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetUserHierarchy
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX);
    SELECT TOP 1 @HierarchyJson = hierarchy_json
    FROM dbo.nt_user_permissions_json
    WHERE ecno = @Ecno AND is_active = 'Y'
    ORDER BY user_perm_json_sno DESC;

    SELECT com_sno, div_sno, brn_sno, dept_sno
    FROM OPENJSON(@HierarchyJson)
    WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno', dept_sno INT '$.dept_sno');
END;
GO

-- ── Data fix: KTM1006 was meant to have Canteen (dept_sno=16, under
-- com=1/div=3/brn=4) access only. Replaces the 3 accidental full-width
-- rows with the single correctly-scoped one. ──
UPDATE dbo.nt_user_permissions_json
SET hierarchy_json = '[{"com_sno":1,"div_sno":3,"brn_sno":4,"dept_sno":16}]',
    updated_date = GETDATE()
WHERE ecno = 'KTM1006' AND is_active = 'Y';
GO
