-- ============================================================
-- entity_master — new master table for approval_workflow_master.entity_type
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/Masters (generic /api/common_master/:masterField
--            pipeline), registered as master key "EntityMaster"
--
-- Why this is needed
-- ------------------
-- approval_workflow_master.entity_type is free-text nvarchar with no backing
-- master table. The only place a canonical list of entity types existed was a
-- hardcoded array inside the frontend's Workflow Master admin screen
-- (Masters, PurchaseRequisition, PurchaseOrder, GRN, Payment, KYC). This adds
-- a real master table + get/create procedures, following the exact same
-- shape as the existing PriorityMaster (entity_sno/entity_name/entity_desc/
-- is_active), plus entity_code — the free-text value actually stored in
-- approval_workflow_master.entity_type (e.g. "KYC", "PurchaseRequisition").
--
-- entity_code is NOT a foreign key on approval_workflow_master.entity_type —
-- that column stays free text so existing rows are untouched. This table is
-- the recommended source going forward, not an enforced constraint.
--
-- Only GET-all and CREATE are wired (sp_nt_GetEntityRecords /
-- sp_nt_CreateEntityRecords), matching how PriorityMaster/UomMaster/etc.
-- already behave in this app today — update/delete for the generic master
-- pipeline has known pre-existing gaps (frontend URL + missing proc map
-- entries) that are out of scope here.
-- ============================================================

IF OBJECT_ID('dbo.entity_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.entity_master (
        entity_sno   INT IDENTITY(1,1) PRIMARY KEY,
        entity_name  NVARCHAR(100) NOT NULL,
        entity_code  NVARCHAR(50)  NOT NULL,
        entity_desc  NVARCHAR(500) NULL,
        is_active    CHAR(1)       NOT NULL DEFAULT 'Y',
        created_by   VARCHAR(20)   NULL,
        created_at   DATETIME      NOT NULL DEFAULT GETDATE(),
        modified_by  VARCHAR(20)   NULL,
        modified_at  DATETIME      NULL,
        CONSTRAINT UQ_entity_master_entity_code UNIQUE (entity_code)
    );
END;
GO

-- ── sp_nt_GetEntityRecords ────────────────────────────────────────────────
IF OBJECT_ID('dbo.sp_nt_GetEntityRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetEntityRecords;
GO
CREATE PROCEDURE dbo.sp_nt_GetEntityRecords
AS
BEGIN
    SET NOCOUNT ON;

    SELECT entity_sno,
           entity_name,
           entity_code,
           entity_desc,
           is_active
    FROM dbo.entity_master
    WHERE is_active = 'Y'
    ORDER BY entity_name;
END;
GO

-- ── sp_nt_CreateEntityRecords ─────────────────────────────────────────────
-- @jsonInput: {"entity_name":"KYC","entity_code":"KYC","entity_desc":"...",
--              "is_active":"Y","created_by":"1234"}
IF OBJECT_ID('dbo.sp_nt_CreateEntityRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateEntityRecords;
GO
CREATE PROCEDURE dbo.sp_nt_CreateEntityRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @entity_name NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.entity_name'),
            @entity_code NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.entity_code'),
            @entity_desc NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.entity_desc'),
            @is_active   CHAR(1)       = ISNULL(JSON_VALUE(@jsonInput, '$.is_active'), 'Y'),
            @created_by  VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @entity_name IS NULL OR @entity_code IS NULL
    BEGIN
        THROW 50002, N'entity_name and entity_code are required.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.entity_master WHERE entity_code = @entity_code)
    BEGIN
        THROW 50003, N'An entity with this code already exists.', 1;
        RETURN;
    END;

    INSERT INTO dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by)
    VALUES (@entity_name, @entity_code, @entity_desc, @is_active, @created_by);

    SELECT SCOPE_IDENTITY() AS entity_sno,
           @entity_name     AS entity_name,
           @entity_code     AS entity_code,
           N'SUCCESS'       AS status,
           N'Entity created successfully.' AS message;
END;
GO

-- ── Seed the 6 entity types already in use across the app ────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.entity_master)
BEGIN
    INSERT INTO dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by)
    VALUES
        (N'Masters',              N'Masters',              NULL, 'Y', N'system'),
        (N'Purchase Requisition', N'PurchaseRequisition',  NULL, 'Y', N'system'),
        (N'Purchase Order',       N'PurchaseOrder',        NULL, 'Y', N'system'),
        (N'GRN',                  N'GRN',                  NULL, 'Y', N'system'),
        (N'Payment',              N'Payment',               NULL, 'Y', N'system'),
        (N'KYC',                  N'KYC',                  NULL, 'Y', N'system');
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.entity_master ORDER BY entity_sno;
--   SELECT name FROM sys.procedures WHERE name IN ('sp_nt_GetEntityRecords','sp_nt_CreateEntityRecords');
-- ============================================================
