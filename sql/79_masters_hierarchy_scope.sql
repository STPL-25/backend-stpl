-- ============================================================
-- Company/Division/Branch access scoping for the Masters generic CRUD
-- dispatch (backend-stpl/src/Masters/Routes/CommonMasterRoutes.js's
-- GET /:masterField, dispatched by CommonMasterRepo.storedProcedureMap).
-- Database: Non_trade_Dev (MSSQL)
--
-- Only the 5 masterFields whose rows actually carry a company/division/
-- branch identity get this treatment: CompanyMaster, DivisionMaster,
-- BranchMaster, DeptMaster, WarehouseLocationMaster. The other ~20 master
-- types dispatched through the same generic route (UomMaster, CategoryMaster,
-- ProductMaster, WorkflowMaster, etc.) are global reference data with no
-- org concept and are deliberately left untouched — see
-- [project-ecno-org-scope-and-grn-fifo] memory for the full triage.
--
-- Convention matches every other @HierarchyJson filter added this session:
-- an OPENJSON array of {com_sno, div_sno, brn_sno}, NULL = unfiltered (kept
-- for internal callers), empty array '[]' = sees nothing. The Node layer
-- (CommonMasterRepo.getAllCommonMasters) only attaches `hierarchy` for
-- these 5 masterFields — every other masterField keeps calling these SPs
-- with zero parameters exactly as before, so no other master type is
-- affected by this migration.
--
-- KNOWN LIMITATION: sp_nt_GetUserHierarchy (the source of every
-- @HierarchyJson value across this whole rollout) only returns
-- com_sno/div_sno/brn_sno — it drops dept_sno even though nt_user_
-- permissions_json.hierarchy_json can carry a dept_sno per row. So
-- DeptMaster filtering below can only narrow to "which branches", not
-- "which specific department within an allowed branch" — a department-
-- scoped permission grant is treated as full-branch access here. This is a
-- pre-existing gap in the shared hierarchy-resolution proc, not something
-- introduced by this file; fixing it means threading dept_sno through
-- sp_nt_GetUserHierarchy and every consumer, a larger follow-up.
-- ============================================================

CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetCompanyRecords]
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');

    BEGIN TRY
        SELECT v.*
        FROM vw_company_address v
        WHERE (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno') h
                WHERE h.com_sno = v.com_sno
            )
        );
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetDivisionsRecords]
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');

    BEGIN TRY
        SELECT v.*
        FROM vw_ActiveDivisions v
        WHERE (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno') h
                WHERE h.com_sno = v.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = v.div_sno)
            )
        );
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetBranchesRecords]
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');

    BEGIN TRY
        SELECT v.*
        FROM ActiveBranches v
        WHERE (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = v.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = v.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = v.brn_sno)
            )
        );
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetDeptRecords]
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');

    BEGIN TRY
        SELECT v.*
        FROM vw_ActiveDeptRecords v
        WHERE (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = v.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = v.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = v.brn_sno)
            )
        );
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

-- warehouse_location_master stores com_snos/div_snos/brn_snos as JSON
-- ARRAYS (one location can serve several companies/divisions/branches at
-- once) — a different shape from the single-value columns above, so the
-- match is "does any hierarchy row's com/div/brn appear in this location's
-- arrays" rather than a plain equality. A NULL/empty div_snos or brn_snos
-- array is treated as "not restricted at that level" (company- or
-- division-wide location), mirroring the div_sno/brn_sno IS NULL wildcard
-- used everywhere else in this rollout.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetWarehouseLocationRecords
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');

    SELECT
        l.location_sno,
        l.location_code,
        l.location_name,
        l.description,
        l.com_snos,
        l.div_snos,
        l.brn_snos,
        cn.com_names,
        dn.div_names,
        bn.brn_names,
        l.is_active,
        l.created_by,
        CONVERT(VARCHAR(30), l.created_at, 120)  AS created_at,
        l.modified_by,
        CONVERT(VARCHAR(30), l.modified_at, 120) AS modified_at
    FROM dbo.warehouse_location_master l
    OUTER APPLY (
        SELECT STRING_AGG(c.com_name, ', ') AS com_names
        FROM OPENJSON(l.com_snos) j
        JOIN dbo.company_master c ON c.com_sno = TRY_CAST(j.value AS INT)
    ) cn
    OUTER APPLY (
        SELECT STRING_AGG(d.div_name, ', ') AS div_names
        FROM OPENJSON(l.div_snos) j
        JOIN dbo.division_master d ON d.div_sno = TRY_CAST(j.value AS INT)
    ) dn
    OUTER APPLY (
        SELECT STRING_AGG(b.brn_name, ', ') AS brn_names
        FROM OPENJSON(l.brn_snos) j
        JOIN dbo.branch_master b ON b.brn_sno = TRY_CAST(j.value AS INT)
    ) bn
    WHERE l.is_active = 'Y'
      AND (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE EXISTS (
                    SELECT 1 FROM OPENJSON(l.com_snos) cj WHERE TRY_CAST(cj.value AS INT) = h.com_sno
                )
                AND (
                    h.div_sno IS NULL
                    OR l.div_snos IS NULL
                    OR NOT EXISTS (SELECT 1 FROM OPENJSON(l.div_snos))
                    OR EXISTS (SELECT 1 FROM OPENJSON(l.div_snos) dj WHERE TRY_CAST(dj.value AS INT) = h.div_sno)
                )
                AND (
                    h.brn_sno IS NULL
                    OR l.brn_snos IS NULL
                    OR NOT EXISTS (SELECT 1 FROM OPENJSON(l.brn_snos))
                    OR EXISTS (SELECT 1 FROM OPENJSON(l.brn_snos) bj WHERE TRY_CAST(bj.value AS INT) = h.brn_sno)
                )
            )
      )
    ORDER BY l.location_sno;
END;
GO
