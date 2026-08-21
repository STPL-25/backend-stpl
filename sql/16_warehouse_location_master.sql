-- ============================================================
-- Warehouse Location master — warehouse_location_master
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/Masters (generic /api/common_master/:masterField
--            pipeline), registered as master key "WarehouseLocationMaster".
--
-- Why this is needed
-- ------------------
-- Today there is no proper master for physical stock locations (racks,
-- bins, warehouses) — the only place "warehouse" exists is a free-text
-- VARCHAR(100) column on the Inventory item table in grn-service. This
-- master gives locations a real identity (code/name), and — since the same
-- physical location is very often shared across several companies /
-- divisions / branches (e.g. one warehouse serving 3 branches of the same
-- company) — lets one location row be scoped to MULTIPLE companies,
-- MULTIPLE divisions and MULTIPLE branches at once, instead of the usual
-- single com_sno/div_sno/brn_sno chain every other org-scoped master uses.
--
-- There is no many-to-many precedent anywhere in this codebase (no
-- junction/bridge tables, no JSON-array org-scope columns). Per product
-- decision, the multi-select is stored directly as JSON arrays on the
-- location row (com_snos/div_snos/brn_snos) rather than junction tables —
-- simpler schema, no joins needed for the common case, filtering is done
-- with OPENJSON where needed (see grn-service/sql/15_warehouse_location_grn_integration.sql,
-- which is the actual consumer: GRN item entry uses this master to record
-- which location received stock went into).
--
-- Scoping semantics: com_snos is mandatory (a location must belong to at
-- least one company). div_snos / brn_snos may be an empty array '[]',
-- meaning "not further restricted" within the selected companies /
-- divisions — e.g. a location with com_snos=[1], div_snos=[], brn_snos=[]
-- is valid for every division/branch under company 1.
--
-- Only GET-all and CREATE are wired, matching BankAccountTypeMaster/
-- PriorityMaster/UomMaster/ServiceTypeMaster's existing pattern (see
-- backend-stpl/sql/15_bank_account_type_master.sql). Update/Delete are
-- deliberately NOT added: the generic Masters grid's Edit/Delete buttons
-- (nt-frontend-stpl DynamicTable.tsx) call apiUpdateCommonMaster/
-- apiDeleteCommonMaster, which build URLs missing the "/common_master"
-- route prefix and (for Edit) the record id — a pre-existing bug that
-- means Edit/Delete are already broken for every master in this app, not
-- just this one. Wiring Update/Delete procedures here would be dead code
-- until that routing bug is fixed separately.
-- ============================================================

IF OBJECT_ID('dbo.warehouse_location_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.warehouse_location_master (
        location_sno   INT IDENTITY(1,1) PRIMARY KEY,
        location_code  VARCHAR(30)   NOT NULL,
        location_name  NVARCHAR(150) NOT NULL,
        description    NVARCHAR(255) NULL,
        -- JSON arrays of sno values, e.g. "[1,2,3]". com_snos must be
        -- non-empty (enforced in sp_nt_CreateWarehouseLocationRecords);
        -- div_snos/brn_snos default to "[]" meaning "not restricted".
        com_snos       NVARCHAR(MAX) NOT NULL,
        div_snos       NVARCHAR(MAX) NOT NULL DEFAULT '[]',
        brn_snos       NVARCHAR(MAX) NOT NULL DEFAULT '[]',
        is_active      CHAR(1)       NOT NULL DEFAULT 'Y',
        created_by     VARCHAR(20)   NULL,
        created_at     DATETIME      NOT NULL DEFAULT GETDATE(),
        modified_by    VARCHAR(20)   NULL,
        modified_at    DATETIME      NULL,
        CONSTRAINT UQ_warehouse_location_master_code UNIQUE (location_code),
        CONSTRAINT CK_warehouse_location_master_com_snos_json CHECK (ISJSON(com_snos) = 1),
        CONSTRAINT CK_warehouse_location_master_div_snos_json CHECK (ISJSON(div_snos) = 1),
        CONSTRAINT CK_warehouse_location_master_brn_snos_json CHECK (ISJSON(brn_snos) = 1)
    );
END;
GO

-- ── sp_nt_GetWarehouseLocationRecords ───────────────────────────────────────
-- com_snos/div_snos/brn_snos are returned as raw JSON text (for the
-- multi-select field to hold as a value); com_names/div_names/brn_names are
-- resolved, comma-separated display strings for the read-only grid columns.
IF OBJECT_ID('dbo.sp_nt_GetWarehouseLocationRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetWarehouseLocationRecords;
GO
CREATE PROCEDURE dbo.sp_nt_GetWarehouseLocationRecords
AS
BEGIN
    SET NOCOUNT ON;

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
    ORDER BY l.location_sno;
END;
GO

-- ── sp_nt_CreateWarehouseLocationRecords ────────────────────────────────────
-- @jsonInput: {"location_code":"...", "location_name":"...", "description":"...",
--              "com_snos":[1,2], "div_snos":[], "brn_snos":[], "created_by":"..."}
IF OBJECT_ID('dbo.sp_nt_CreateWarehouseLocationRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateWarehouseLocationRecords;
GO
CREATE PROCEDURE dbo.sp_nt_CreateWarehouseLocationRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @location_code NVARCHAR(30)  = JSON_VALUE(@jsonInput, '$.location_code'),
            @location_name NVARCHAR(150) = JSON_VALUE(@jsonInput, '$.location_name'),
            @description   NVARCHAR(255) = JSON_VALUE(@jsonInput, '$.description'),
            @com_snos      NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.com_snos'),
            @div_snos      NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.div_snos'),
            @brn_snos      NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.brn_snos'),
            @created_by    VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    SET @div_snos = ISNULL(@div_snos, N'[]');
    SET @brn_snos = ISNULL(@brn_snos, N'[]');

    IF @location_code IS NULL OR @location_name IS NULL
    BEGIN
        THROW 50002, N'location_code and location_name are required.', 1;
        RETURN;
    END;

    IF @com_snos IS NULL OR ISJSON(@com_snos) = 0 OR NOT EXISTS (SELECT 1 FROM OPENJSON(@com_snos))
    BEGIN
        THROW 50003, N'At least one company must be selected.', 1;
        RETURN;
    END;

    IF ISJSON(@div_snos) = 0 OR ISJSON(@brn_snos) = 0
    BEGIN
        THROW 50004, N'div_snos and brn_snos must be valid JSON arrays.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.warehouse_location_master WHERE location_code = @location_code)
    BEGIN
        THROW 50005, N'A warehouse location with this code already exists.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.warehouse_location_master WHERE location_name = @location_name)
    BEGIN
        THROW 50006, N'A warehouse location with this name already exists.', 1;
        RETURN;
    END;

    INSERT INTO dbo.warehouse_location_master (
        location_code, location_name, description, com_snos, div_snos, brn_snos, is_active, created_by
    )
    VALUES (
        @location_code, @location_name, @description, @com_snos, @div_snos, @brn_snos, 'Y', @created_by
    );

    SELECT SCOPE_IDENTITY() AS location_sno,
           @location_code   AS location_code,
           N'SUCCESS'       AS status,
           N'Warehouse location created successfully.' AS message;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.warehouse_location_master ORDER BY location_sno;
--   SELECT name FROM sys.procedures WHERE name LIKE 'sp_nt_%WarehouseLocation%';
-- ============================================================
