-- ============================================================
-- Service masters — service_type_master + service_master
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/Masters (generic /api/common_master/:masterField
--            pipeline), registered as master keys "ServiceTypeMaster" and
--            "ServiceMaster" — same shape as entity_master (see
--            backend-stpl/sql/04_entity_master.sql), which this file mirrors.
--
-- Why this is needed
-- ------------------
-- First piece of the Service Procurement feature (Service_Procurement_Flow.pdf):
-- every service PR line / Service PO needs to reference a service catalogue
-- entry, and every service needs to know which of the 3 billing patterns it
-- follows (Fixed Recurring / Variable Recurring / Vendor-Bill-Driven) plus its
-- recurrence cadence. service_type_master is a short, effectively-fixed list
-- (3 rows, seeded below); service_master is the open-ended catalogue, sized
-- and shaped like product_master's core columns (name/code/uom/active/audit)
-- but without product_master's category/subcategory batch-code-generation
-- machinery, which doesn't apply here.
--
-- UOM reuse: default_uom_sno points at the EXISTING dbo.uom_master (already
-- wired as "UomMaster" in CommonMasterRepo.js) — no separate service-UOM
-- table. New UOM rows for service billing (e.g. "Call-out", "Trip") are
-- seeded via the existing sp_nt_CreateUomRecords, not here.
--
-- Only GET-all and CREATE are wired for both masters, matching entity_master/
-- UomMaster/PriorityMaster's existing pattern in this app.
-- ============================================================

-- ── service_type_master ─────────────────────────────────────────────────────

IF OBJECT_ID('dbo.service_type_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_type_master (
        service_type_sno            INT IDENTITY(1,1) PRIMARY KEY,
        service_type_code           VARCHAR(30)   NOT NULL,
        service_type_name           NVARCHAR(100) NOT NULL,
        requires_ceiling_amount     BIT           NOT NULL DEFAULT 0,
        requires_variance_tolerance BIT           NOT NULL DEFAULT 0,
        is_active                   CHAR(1)       NOT NULL DEFAULT 'Y',
        created_by                  VARCHAR(20)   NULL,
        created_at                  DATETIME      NOT NULL DEFAULT GETDATE(),
        modified_by                 VARCHAR(20)   NULL,
        modified_at                 DATETIME      NULL,
        CONSTRAINT UQ_service_type_master_code UNIQUE (service_type_code)
    );
END;
GO

-- ── service_master ──────────────────────────────────────────────────────────

IF OBJECT_ID('dbo.service_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_master (
        service_sno              INT IDENTITY(1,1) PRIMARY KEY,
        service_name             NVARCHAR(150) NOT NULL,
        service_code              VARCHAR(50)   NOT NULL,
        service_type_sno          INT           NOT NULL,
        default_uom_sno           INT           NULL,
        sac_code                  VARCHAR(20)   NULL,
        is_recurring               BIT           NOT NULL DEFAULT 0,
        -- recurrence_cadence only meaningful when is_recurring = 1:
        -- DAILY | EVERY_N_DAYS | MONTHLY | QUARTERLY | HALF_YEARLY | YEARLY_FIXED_DATE
        recurrence_cadence         VARCHAR(20)   NULL,
        -- only used when recurrence_cadence = 'EVERY_N_DAYS' (e.g. milk billed every 10-15 days)
        recurrence_interval_days   INT           NULL,
        description                NVARCHAR(500) NULL,
        is_active                  CHAR(1)       NOT NULL DEFAULT 'Y',
        created_by                 VARCHAR(20)   NULL,
        created_at                 DATETIME      NOT NULL DEFAULT GETDATE(),
        modified_by                VARCHAR(20)   NULL,
        modified_at                DATETIME      NULL,
        CONSTRAINT UQ_service_master_code UNIQUE (service_code),
        CONSTRAINT FK_service_master_type FOREIGN KEY (service_type_sno)
            REFERENCES dbo.service_type_master (service_type_sno),
        CONSTRAINT FK_service_master_uom FOREIGN KEY (default_uom_sno)
            REFERENCES dbo.uom_master (uom_sno)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_service_master_type' AND object_id = OBJECT_ID('dbo.service_master'))
    CREATE INDEX IX_service_master_type ON dbo.service_master (service_type_sno);
GO

-- ── sp_nt_GetServiceTypeRecords ─────────────────────────────────────────────
IF OBJECT_ID('dbo.sp_nt_GetServiceTypeRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetServiceTypeRecords;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceTypeRecords
AS
BEGIN
    SET NOCOUNT ON;

    SELECT service_type_sno,
           service_type_code,
           service_type_name,
           requires_ceiling_amount,
           requires_variance_tolerance,
           is_active
    FROM dbo.service_type_master
    WHERE is_active = 'Y'
    ORDER BY service_type_sno;
END;
GO

-- ── sp_nt_CreateServiceTypeRecords ──────────────────────────────────────────
-- @jsonInput: {"service_type_code":"...", "service_type_name":"...",
--              "requires_ceiling_amount":0|1, "requires_variance_tolerance":0|1,
--              "created_by":"..."}
-- Admin-only escape hatch — the 3 rows seeded below cover every case the
-- design doc describes. Not expected to be used from the regular UI.
IF OBJECT_ID('dbo.sp_nt_CreateServiceTypeRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateServiceTypeRecords;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceTypeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @service_type_code           VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.service_type_code'),
            @service_type_name           NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.service_type_name'),
            @requires_ceiling_amount     BIT           = ISNULL(JSON_VALUE(@jsonInput, '$.requires_ceiling_amount'), 0),
            @requires_variance_tolerance BIT           = ISNULL(JSON_VALUE(@jsonInput, '$.requires_variance_tolerance'), 0),
            @created_by                  VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @service_type_code IS NULL OR @service_type_name IS NULL
    BEGIN
        THROW 50002, N'service_type_code and service_type_name are required.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.service_type_master WHERE service_type_code = @service_type_code)
    BEGIN
        THROW 50003, N'A service type with this code already exists.', 1;
        RETURN;
    END;

    INSERT INTO dbo.service_type_master (
        service_type_code, service_type_name, requires_ceiling_amount, requires_variance_tolerance, is_active, created_by
    )
    VALUES (
        @service_type_code, @service_type_name, @requires_ceiling_amount, @requires_variance_tolerance, 'Y', @created_by
    );

    SELECT SCOPE_IDENTITY()   AS service_type_sno,
           @service_type_code AS service_type_code,
           N'SUCCESS'         AS status,
           N'Service type created successfully.' AS message;
END;
GO

-- ── sp_nt_GetServiceRecords ─────────────────────────────────────────────────
-- @jsonInput optional: { service_type_sno }
IF OBJECT_ID('dbo.sp_nt_GetServiceRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetServiceRecords;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceRecords
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @service_type_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @service_type_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_type_sno') AS INT);

    SELECT
        sm.service_sno,
        sm.service_name,
        sm.service_code,
        sm.service_type_sno,
        st.service_type_code,
        st.service_type_name,
        sm.default_uom_sno,
        um.uom_name           AS default_uom_name,
        sm.sac_code,
        sm.is_recurring,
        sm.recurrence_cadence,
        sm.recurrence_interval_days,
        sm.description,
        sm.is_active
    FROM dbo.service_master sm
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.uom_master um     ON um.uom_sno = sm.default_uom_sno
    WHERE sm.is_active = 'Y'
      AND (@service_type_sno IS NULL OR sm.service_type_sno = @service_type_sno)
    ORDER BY sm.service_name;
END;
GO

-- ── sp_nt_CreateServiceRecords ──────────────────────────────────────────────
-- @jsonInput: {"service_name":"...", "service_code":"...", "service_type_sno":N,
--              "default_uom_sno":N|null, "sac_code":"..."|null,
--              "is_recurring":0|1, "recurrence_cadence":"..."|null,
--              "recurrence_interval_days":N|null, "description":"..."|null,
--              "created_by":"..."}
IF OBJECT_ID('dbo.sp_nt_CreateServiceRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateServiceRecords;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @service_name             NVARCHAR(150) = JSON_VALUE(@jsonInput, '$.service_name'),
            @service_code             VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.service_code'),
            @service_type_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_type_sno') AS INT),
            @default_uom_sno          INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.default_uom_sno') AS INT),
            @sac_code                 VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.sac_code'),
            @is_recurring             BIT           = ISNULL(JSON_VALUE(@jsonInput, '$.is_recurring'), 0),
            @recurrence_cadence       VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.recurrence_cadence'),
            @recurrence_interval_days INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_interval_days') AS INT),
            @description              NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.description'),
            @created_by               VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @service_name IS NULL OR @service_code IS NULL OR @service_type_sno IS NULL
    BEGIN
        THROW 50002, N'service_name, service_code and service_type_sno are required.', 1;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.service_type_master WHERE service_type_sno = @service_type_sno AND is_active = 'Y')
    BEGIN
        THROW 50003, N'service_type_sno does not reference an active service type.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.service_master WHERE service_code = @service_code)
    BEGIN
        THROW 50004, N'A service with this code already exists.', 1;
        RETURN;
    END;

    IF @is_recurring = 1 AND @recurrence_cadence IS NULL
    BEGIN
        THROW 50005, N'recurrence_cadence is required when is_recurring is set.', 1;
        RETURN;
    END;

    INSERT INTO dbo.service_master (
        service_name, service_code, service_type_sno, default_uom_sno, sac_code,
        is_recurring, recurrence_cadence, recurrence_interval_days, description,
        is_active, created_by
    )
    VALUES (
        @service_name, @service_code, @service_type_sno, @default_uom_sno, @sac_code,
        @is_recurring, @recurrence_cadence, @recurrence_interval_days, @description,
        'Y', @created_by
    );

    SELECT SCOPE_IDENTITY() AS service_sno,
           @service_code    AS service_code,
           N'SUCCESS'       AS status,
           N'Service created successfully.' AS message;
END;
GO

-- ── Seed the 3 billing-pattern service types ─────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.service_type_master)
BEGIN
    INSERT INTO dbo.service_type_master (
        service_type_code, service_type_name, requires_ceiling_amount, requires_variance_tolerance, is_active, created_by
    )
    VALUES
        (N'FIXED_RECURRING',    N'Fixed Recurring',      0, 0, 'Y', N'system'),
        (N'VARIABLE_RECURRING', N'Variable Recurring',   1, 1, 'Y', N'system'),
        (N'VENDOR_BILL',        N'Vendor-Bill-Driven',   0, 0, 'Y', N'system');
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.service_type_master ORDER BY service_type_sno;
--   SELECT name FROM sys.procedures WHERE name LIKE 'sp_nt_%Service%';
-- ============================================================
