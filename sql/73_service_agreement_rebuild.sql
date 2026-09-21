-- ============================================================
-- Service Agreement rebuild — scoped: Agreement -> approval -> auto-PO
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Context
-- -------
-- The original Service Agreement feature (files 10-71 in this folder) was
-- fully removed on 2026-09-11 per user request, backed up to
-- sql/backups/pre_service_removal_2026-09-11/. This is a fresh, smaller
-- rebuild per a follow-up conversation, NOT a replay of the old incremental
-- chain — see backend-stpl/docs/service-agreement-approval-po-spec.md and
-- the old files (23/39/47/51 in particular) for design lineage, but this
-- file's schema/procs are written fresh and intentionally narrower:
--   - Two agreement types only: Fixed Recurring and Variable Recurring
--     ("Unfixed"). No third Vendor-Bill-Driven type.
--   - No ceiling_amount/variance_tolerance_pct model. A Variable/Unfixed
--     agreement just submits an approximate rate_amount + qty; the final
--     approver overwrites both with real values at the agreement's own
--     final approval stage (one-time, not a per-cycle re-approval).
--   - No Service Bill Request, Service Vendor Daily Entry, Service Vendor
--     KYC, or Service Entry (service GRN) modules — out of scope for this
--     pass.
--   - `qty` lives directly on service_agreement (the old design never
--     modeled it there, only implicitly defaulted to 1 per cycle).
--   - recurrence_cadence is master-driven (recurrence_cadence_master),
--     admin-extensible, with an explicit po_generation_day override for
--     month-based cadences and a notify_days_before lead time — both
--     apply identically to Fixed and Variable agreements, since a Variable
--     agreement behaves exactly like Fixed once its one-time value
--     finalization has happened at approval.
--   - The recurring engine still creates an internal, auto-approved PR row
--     per billing cycle before issuing the PO (audit-trail consistency with
--     the rest of the app, which always represents spend as PR->PO) — this
--     is invisible to users, never something anyone approves.
--
-- Idempotent throughout (IF NOT EXISTS / IF OBJECT_ID...DROP), matching this
-- repo's migration-file convention. Safe to re-run.
--
-- NOT YET RUN AGAINST THE LIVE DB — this repo has no migration runner, every
-- sql/*.sql file here is applied by hand against 10.0.21.8. Run this file,
-- in full, before any ServiceAgreement backend/frontend code will work.
-- ============================================================

-- ============================================================
-- 1) entity_master seed — required so an admin can configure an approval
--    workflow for entity_type='ServiceAgreement' via the existing
--    UserRoleApprovalScreen.tsx / approval_workflow_master mechanism.
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.entity_master WHERE entity_code = 'ServiceAgreement')
    INSERT INTO dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by)
    VALUES (N'Service Agreement', N'ServiceAgreement', N'Recurring service agreements (Fixed/Unfixed) that auto-raise POs', 'Y', N'system');
GO

-- ============================================================
-- 2) service_type_master + service_master — the service catalogue.
--    Two billing patterns only (see file header).
-- ============================================================
IF OBJECT_ID('dbo.service_type_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_type_master (
        service_type_sno  INT IDENTITY(1,1) PRIMARY KEY,
        service_type_code VARCHAR(30)   NOT NULL,
        service_type_name NVARCHAR(100) NOT NULL,
        is_active          CHAR(1)      NOT NULL DEFAULT 'Y',
        created_by         VARCHAR(20)  NULL,
        created_at         DATETIME     NOT NULL DEFAULT GETDATE(),
        modified_by        VARCHAR(20)  NULL,
        modified_at        DATETIME     NULL,
        CONSTRAINT UQ_service_type_master_code UNIQUE (service_type_code)
    );
END;
GO

IF OBJECT_ID('dbo.service_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_master (
        service_sno       INT IDENTITY(1,1) PRIMARY KEY,
        service_name      NVARCHAR(150) NOT NULL,
        service_code      VARCHAR(50)   NOT NULL,
        service_type_sno  INT           NOT NULL,
        default_uom_sno   INT           NULL,
        description       NVARCHAR(500) NULL,
        is_active         CHAR(1)       NOT NULL DEFAULT 'Y',
        created_by        VARCHAR(20)   NULL,
        created_at        DATETIME      NOT NULL DEFAULT GETDATE(),
        modified_by       VARCHAR(20)   NULL,
        modified_at       DATETIME      NULL,
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

IF OBJECT_ID('dbo.sp_nt_GetServiceTypeRecords', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceTypeRecords;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceTypeRecords
AS
BEGIN
    SET NOCOUNT ON;
    SELECT service_type_sno, service_type_code, service_type_name, is_active
    FROM dbo.service_type_master
    WHERE is_active = 'Y'
    ORDER BY service_type_sno;
END;
GO

IF OBJECT_ID('dbo.sp_nt_CreateServiceTypeRecords', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateServiceTypeRecords;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceTypeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 58001, N'Invalid JSON payload provided.', 1;

    DECLARE @service_type_code VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.service_type_code'),
            @service_type_name NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.service_type_name'),
            @created_by        VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @service_type_code IS NULL OR @service_type_name IS NULL
        THROW 58002, N'service_type_code and service_type_name are required.', 1;

    IF EXISTS (SELECT 1 FROM dbo.service_type_master WHERE service_type_code = @service_type_code)
        THROW 58003, N'A service type with this code already exists.', 1;

    INSERT INTO dbo.service_type_master (service_type_code, service_type_name, is_active, created_by)
    VALUES (@service_type_code, @service_type_name, 'Y', @created_by);

    SELECT SCOPE_IDENTITY() AS service_type_sno, @service_type_code AS service_type_code, N'SUCCESS' AS status;
END;
GO

IF OBJECT_ID('dbo.sp_nt_GetServiceRecords', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceRecords;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceRecords
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @service_type_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @service_type_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_type_sno') AS INT);

    SELECT sm.service_sno, sm.service_name, sm.service_code, sm.service_type_sno,
           st.service_type_code, st.service_type_name,
           sm.default_uom_sno, um.uom_name AS default_uom_name,
           sm.description, sm.is_active
    FROM dbo.service_master sm
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = sm.default_uom_sno
    WHERE sm.is_active = 'Y'
      AND (@service_type_sno IS NULL OR sm.service_type_sno = @service_type_sno)
    ORDER BY sm.service_name;
END;
GO

IF OBJECT_ID('dbo.sp_nt_CreateServiceRecords', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateServiceRecords;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 58004, N'Invalid JSON payload provided.', 1;

    DECLARE @service_name     NVARCHAR(150) = JSON_VALUE(@jsonInput, '$.service_name'),
            @service_code     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.service_code'),
            @service_type_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_type_sno') AS INT),
            @default_uom_sno  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.default_uom_sno') AS INT),
            @description      NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.description'),
            @created_by       VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @service_name IS NULL OR @service_code IS NULL OR @service_type_sno IS NULL
        THROW 58005, N'service_name, service_code and service_type_sno are required.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.service_type_master WHERE service_type_sno = @service_type_sno AND is_active = 'Y')
        THROW 58006, N'service_type_sno does not reference an active service type.', 1;

    IF EXISTS (SELECT 1 FROM dbo.service_master WHERE service_code = @service_code)
        THROW 58007, N'A service with this code already exists.', 1;

    INSERT INTO dbo.service_master (service_name, service_code, service_type_sno, default_uom_sno, description, is_active, created_by)
    VALUES (@service_name, @service_code, @service_type_sno, @default_uom_sno, @description, 'Y', @created_by);

    SELECT SCOPE_IDENTITY() AS service_sno, @service_code AS service_code, N'SUCCESS' AS status;
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.service_type_master)
    INSERT INTO dbo.service_type_master (service_type_code, service_type_name, is_active, created_by)
    VALUES (N'FIXED_RECURRING', N'Fixed', 'Y', N'system'),
           (N'VARIABLE_RECURRING', N'Unfixed', 'Y', N'system');
GO

-- ============================================================
-- 3) recurrence_cadence_master — admin-extensible billing cadence.
-- ============================================================
IF OBJECT_ID('dbo.recurrence_cadence_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.recurrence_cadence_master (
        recurrence_cadence_sno INT IDENTITY(1,1) PRIMARY KEY,
        cadence_code           VARCHAR(30)   NOT NULL,
        cadence_name           NVARCHAR(100) NOT NULL,
        interval_unit           VARCHAR(10)  NOT NULL, -- DAY | MONTH
        interval_value            INT        NOT NULL,
        description                NVARCHAR(200) NULL,
        is_active                   CHAR(1)   NOT NULL DEFAULT 'Y',
        created_by                   VARCHAR(20) NULL,
        created_at                    DATETIME  NOT NULL DEFAULT GETDATE(),
        modified_by                    VARCHAR(20) NULL,
        modified_at                     DATETIME NULL,
        CONSTRAINT UQ_recurrence_cadence_master_code UNIQUE (cadence_code),
        CONSTRAINT CK_recurrence_cadence_master_unit CHECK (interval_unit IN ('DAY','MONTH')),
        CONSTRAINT CK_recurrence_cadence_master_value CHECK (interval_value > 0)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.recurrence_cadence_master)
    INSERT INTO dbo.recurrence_cadence_master (cadence_code, cadence_name, interval_unit, interval_value, description, is_active, created_by)
    VALUES
        (N'FIFTEEN_DAYS', N'Every 15 Days',            'DAY',   15, N'Bills every 15 days from the agreement period start date', 'Y', N'system'),
        (N'MONTHLY',      N'Monthly',                  'MONTH',  1, N'Bills every month', 'Y', N'system'),
        (N'BIMONTHLY',    N'Bi-Monthly (Every 2 Months)', 'MONTH', 2, N'Bills every 2 months', 'Y', N'system'),
        (N'QUARTERLY',    N'Quarterly',                'MONTH',  3, N'Bills every 3 months', 'Y', N'system'),
        (N'ANNUAL',       N'Annual',                   'MONTH', 12, N'Bills once a year', 'Y', N'system');
GO

IF OBJECT_ID('dbo.sp_nt_GetRecurrenceCadenceRecords', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetRecurrenceCadenceRecords;
GO
CREATE PROCEDURE dbo.sp_nt_GetRecurrenceCadenceRecords
AS
BEGIN
    SET NOCOUNT ON;
    SELECT recurrence_cadence_sno, cadence_code, cadence_name, interval_unit, interval_value, description, is_active
    FROM dbo.recurrence_cadence_master
    WHERE is_active = 'Y'
    ORDER BY recurrence_cadence_sno;
END;
GO

IF OBJECT_ID('dbo.sp_nt_CreateRecurrenceCadenceRecords', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateRecurrenceCadenceRecords;
GO
CREATE PROCEDURE dbo.sp_nt_CreateRecurrenceCadenceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 58008, N'Invalid JSON payload provided.', 1;

    DECLARE @cadence_code   VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.cadence_code'),
            @cadence_name   NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.cadence_name'),
            @interval_unit  VARCHAR(10)   = UPPER(JSON_VALUE(@jsonInput, '$.interval_unit')),
            @interval_value INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.interval_value') AS INT),
            @description    NVARCHAR(200) = JSON_VALUE(@jsonInput, '$.description'),
            @created_by     VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @cadence_code IS NULL OR @cadence_name IS NULL OR @interval_unit IS NULL OR @interval_value IS NULL
        THROW 58009, N'cadence_code, cadence_name, interval_unit and interval_value are required.', 1;
    IF @interval_unit NOT IN ('DAY','MONTH') THROW 58010, N'interval_unit must be DAY or MONTH.', 1;
    IF @interval_value <= 0 THROW 58011, N'interval_value must be positive.', 1;
    IF EXISTS (SELECT 1 FROM dbo.recurrence_cadence_master WHERE cadence_code = @cadence_code)
        THROW 58012, N'A recurrence cadence with this code already exists.', 1;

    INSERT INTO dbo.recurrence_cadence_master (cadence_code, cadence_name, interval_unit, interval_value, description, is_active, created_by)
    VALUES (@cadence_code, @cadence_name, @interval_unit, @interval_value, @description, 'Y', @created_by);

    SELECT SCOPE_IDENTITY() AS recurrence_cadence_sno, @cadence_code AS cadence_code, N'SUCCESS' AS status;
END;
GO

-- ============================================================
-- 4) service_agreement + service_agreement_history
-- ============================================================
IF OBJECT_ID('dbo.service_agreement', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_agreement (
        agreement_sno           INT IDENTITY(1,1) PRIMARY KEY,
        agreement_no            VARCHAR(30)    NOT NULL,
        com_sno                 INT            NOT NULL,
        div_sno                 INT            NOT NULL,
        brn_sno                 INT            NOT NULL,
        dept_sno                INT            NOT NULL,
        service_sno              INT           NOT NULL,
        vendor_sno                INT          NOT NULL,
        qty                        DECIMAL(18,4) NOT NULL DEFAULT 1,
        rate_amount                 DECIMAL(18,2) NOT NULL,
        rate_uom_sno                 INT         NULL,
        recurrence_cadence_sno        INT        NOT NULL,
        po_generation_day               SMALLINT NULL,
        notify_days_before                SMALLINT NOT NULL DEFAULT 0,
        period_start_date                  DATE   NOT NULL,
        period_end_date                     DATE  NOT NULL,
        agreement_doc_url                    NVARCHAR(500) NOT NULL,
        remarks                                NVARCHAR(500) NULL,
        workflow_types_id                       INT NULL,
        current_approver_id                      VARCHAR(30) NULL,
        status                                    CHAR(1) NOT NULL DEFAULT 'P', -- P=Pending, A=Approved, R=Rejected, X=Expired
        is_active                                  CHAR(1) NOT NULL DEFAULT 'Y',
        created_by                                  VARCHAR(20) NULL,
        created_at                                   DATETIME NOT NULL DEFAULT GETDATE(),
        modified_by                                   VARCHAR(20) NULL,
        modified_at                                    DATETIME NULL,
        CONSTRAINT UQ_service_agreement_no UNIQUE (agreement_no),
        CONSTRAINT CK_service_agreement_status CHECK (status IN ('P','A','R','X')),
        CONSTRAINT CK_service_agreement_period CHECK (period_end_date > period_start_date),
        CONSTRAINT CK_service_agreement_po_generation_day CHECK (po_generation_day IS NULL OR po_generation_day BETWEEN 1 AND 31),
        CONSTRAINT CK_service_agreement_notify_days_before CHECK (notify_days_before >= 0),
        CONSTRAINT CK_service_agreement_qty CHECK (qty > 0),
        CONSTRAINT CK_service_agreement_rate CHECK (rate_amount > 0),
        CONSTRAINT FK_service_agreement_service FOREIGN KEY (service_sno) REFERENCES dbo.service_master (service_sno),
        CONSTRAINT FK_service_agreement_cadence FOREIGN KEY (recurrence_cadence_sno) REFERENCES dbo.recurrence_cadence_master (recurrence_cadence_sno)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_service_agreement_scope' AND object_id = OBJECT_ID('dbo.service_agreement'))
    CREATE INDEX IX_service_agreement_scope ON dbo.service_agreement (com_sno, div_sno, brn_sno, dept_sno, service_sno, status);
GO

IF OBJECT_ID('dbo.service_agreement_history', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_agreement_history (
        history_sno   INT IDENTITY(1,1) PRIMARY KEY,
        agreement_sno INT           NOT NULL,
        action_type   VARCHAR(20)   NOT NULL, -- SUBMITTED | RESUBMITTED | APPROVED | REJECTED | RATE_FINALIZED | EXPIRED
        status_by     VARCHAR(30)   NULL,
        comment       NVARCHAR(500) NULL,
        is_active     CHAR(1)       NOT NULL DEFAULT 'Y',
        created_at    DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_service_agreement_history_agreement FOREIGN KEY (agreement_sno) REFERENCES dbo.service_agreement (agreement_sno)
    );
END;
GO

-- ============================================================
-- 5) recurring PO-issue log + notification log — idempotency, one row per
--    (agreement_sno, billing_period_start).
-- ============================================================
IF OBJECT_ID('dbo.service_agreement_recurring_pr_log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_agreement_recurring_pr_log (
        log_sno              INT IDENTITY(1,1) PRIMARY KEY,
        agreement_sno        INT NOT NULL,
        billing_period_start DATE NOT NULL,
        status                VARCHAR(20) NOT NULL DEFAULT 'PENDING', -- PENDING|CREATED|FAILED|SKIPPED_MANUAL
        pr_basic_sno           INT NULL,
        pr_no                   VARCHAR(20) NULL,
        po_basic_sno             INT NULL,
        po_no                     VARCHAR(50) NULL,
        error_message              NVARCHAR(500) NULL,
        created_at                  DATETIME NOT NULL DEFAULT GETDATE(),
        modified_at                  DATETIME NULL,
        CONSTRAINT UQ_service_agreement_recurring_pr_log UNIQUE (agreement_sno, billing_period_start),
        CONSTRAINT FK_service_agreement_recurring_pr_log_agreement FOREIGN KEY (agreement_sno) REFERENCES dbo.service_agreement (agreement_sno)
    );
END;
GO

IF OBJECT_ID('dbo.service_agreement_notification_log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_agreement_notification_log (
        log_sno              INT IDENTITY(1,1) PRIMARY KEY,
        agreement_sno        INT NOT NULL,
        billing_period_start DATE NOT NULL,
        status                VARCHAR(20) NOT NULL DEFAULT 'PENDING', -- PENDING|SENT|FAILED
        notif_sno              INT NULL,
        error_message            NVARCHAR(500) NULL,
        created_at                DATETIME NOT NULL DEFAULT GETDATE(),
        modified_at                DATETIME NULL,
        CONSTRAINT UQ_service_agreement_notification_log UNIQUE (agreement_sno, billing_period_start),
        CONSTRAINT FK_service_agreement_notification_log_agreement FOREIGN KEY (agreement_sno) REFERENCES dbo.service_agreement (agreement_sno)
    );
END;
GO

-- ============================================================
-- 6) Defensive column guards on shared tables — these columns were added by
--    the original (removed) Service feature and, per its removal script's
--    own notes, were never dropped (only their FKs were). Guarded here in
--    case that's not true in this environment — cheap idempotent safety net.
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_request_info') AND name = 'service_type_sno')
    ALTER TABLE dbo.po_request_info ADD service_type_sno INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_item_details') AND name = 'service_sno')
    ALTER TABLE dbo.po_item_details ADD service_sno INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.pr_item_details') AND name = 'service_sno')
    ALTER TABLE dbo.pr_item_details ADD service_sno INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.pr_item_details') AND name = 'agreement_sno')
    ALTER TABLE dbo.pr_item_details ADD agreement_sno INT NULL;
GO

-- WITH NOCHECK: po_item_details/pr_item_details carry orphaned service_sno
-- values from before the 2026-09-11 removal (their old service_master rows
-- are gone, service_master was just recreated empty) — validating existing
-- rows against the fresh table would fail the whole migration for a
-- historical-data mismatch these FKs are not meant to fix. New rows are
-- still validated going forward (NOCHECK only skips the one-time backfill
-- check, not future inserts/updates).
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_po_item_details_service_sno')
    ALTER TABLE dbo.po_item_details WITH NOCHECK ADD CONSTRAINT FK_po_item_details_service_sno FOREIGN KEY (service_sno) REFERENCES dbo.service_master (service_sno);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_po_request_info_service_type')
    ALTER TABLE dbo.po_request_info WITH NOCHECK ADD CONSTRAINT FK_po_request_info_service_type FOREIGN KEY (service_type_sno) REFERENCES dbo.service_type_master (service_type_sno);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_pr_item_details_service_sno')
    ALTER TABLE dbo.pr_item_details WITH NOCHECK ADD CONSTRAINT FK_pr_item_details_service_sno FOREIGN KEY (service_sno) REFERENCES dbo.service_master (service_sno);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_pr_item_details_agreement')
    ALTER TABLE dbo.pr_item_details WITH NOCHECK ADD CONSTRAINT FK_pr_item_details_agreement FOREIGN KEY (agreement_sno) REFERENCES dbo.service_agreement (agreement_sno);
GO

-- ============================================================
-- 7) sp_nt_CreateServiceAgreement
-- @jsonInput: { com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
--   qty, rate_amount, rate_uom_sno?, recurrence_cadence_sno, po_generation_day?,
--   notify_days_before?, period_start_date, period_end_date, agreement_doc_url,
--   remarks?, created_by }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateServiceAgreement', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateServiceAgreement;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @com_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @service_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @vendor_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @qty                DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4));
        DECLARE @rate_amount        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @rate_uom_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_uom_sno') AS INT);
        DECLARE @recurrence_cadence_sno INT       = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_cadence_sno') AS INT);
        DECLARE @po_generation_day  SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_generation_day') AS SMALLINT);
        DECLARE @notify_days_before SMALLINT      = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.notify_days_before') AS SMALLINT), 0);
        DECLARE @period_start_date  DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url  NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @created_by         VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @service_sno IS NULL OR @vendor_sno IS NULL OR @created_by IS NULL
            THROW 58101, 'com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno and created_by are required.', 1;

        IF @qty IS NULL OR @qty <= 0
            THROW 58102, 'qty must be a positive quantity.', 1;

        IF @rate_amount IS NULL OR @rate_amount <= 0
            THROW 58103, 'rate_amount must be a positive amount (an approximate value is fine for an Unfixed agreement).', 1;

        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 58104, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;

        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 58105, 'agreement_doc_url is required — upload the agreement document before submitting.', 1;

        IF @recurrence_cadence_sno IS NULL
            THROW 58106, 'recurrence_cadence_sno is required — see sp_nt_GetRecurrenceCadenceRecords for valid options.', 1;

        DECLARE @interval_unit VARCHAR(10);
        SELECT @interval_unit = interval_unit FROM dbo.recurrence_cadence_master WHERE recurrence_cadence_sno = @recurrence_cadence_sno AND is_active = 'Y';
        IF @interval_unit IS NULL
            THROW 58107, 'recurrence_cadence_sno does not reference an active recurrence cadence.', 1;

        IF @interval_unit = 'MONTH'
        BEGIN
            IF @po_generation_day IS NULL OR @po_generation_day NOT BETWEEN 1 AND 31
                THROW 58108, 'po_generation_day (1-31) is required for a month-based recurrence cadence.', 1;
        END
        ELSE
            SET @po_generation_day = NULL;

        DECLARE @service_type_code VARCHAR(30);
        SELECT @service_type_code = st.service_type_code
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';

        IF @service_type_code IS NULL OR @service_type_code NOT IN ('FIXED_RECURRING', 'VARIABLE_RECURRING')
            THROW 58109, 'service_sno must reference an active Fixed or Unfixed service.', 1;

        -- ── Resolve the ServiceAgreement workflow for this org scope ───────
        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceAgreement';

        IF @workflow_types_id IS NULL
            THROW 58110, 'No ServiceAgreement workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key] = '0' AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 58111, 'No approver found for the first stage of the ServiceAgreement workflow.', 1;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(agreement_no, 4) AS INT)), 0) + 1
        FROM dbo.service_agreement WITH (UPDLOCK, HOLDLOCK)
        WHERE agreement_no LIKE 'AGR-' + @year + '-%';
        DECLARE @agreement_no VARCHAR(30) = 'AGR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.service_agreement (
            agreement_no, com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
            qty, rate_amount, rate_uom_sno, recurrence_cadence_sno, po_generation_day, notify_days_before,
            period_start_date, period_end_date, agreement_doc_url, remarks,
            workflow_types_id, current_approver_id, status, is_active, created_by
        )
        VALUES (
            @agreement_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @service_sno, @vendor_sno,
            @qty, @rate_amount, @rate_uom_sno, @recurrence_cadence_sno, @po_generation_day, @notify_days_before,
            @period_start_date, @period_end_date, @agreement_doc_url, @remarks,
            @workflow_types_id, @first_approver, 'P', 'Y', @created_by
        );

        DECLARE @agreement_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment)
        VALUES (@agreement_sno, 'SUBMITTED', @created_by, NULL);

        COMMIT TRANSACTION;

        SELECT @agreement_sno AS agreement_sno, @agreement_no AS agreement_no, 'SUCCESS' AS result,
               N'Service agreement submitted for approval.' AS message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- 8) sp_nt_UpdateServiceAgreement — edit + re-approval. Only when the
--    agreement is Approved or Rejected (not while a Pending approval is
--    already in flight). Resets to Pending and re-enters the workflow.
-- @jsonInput: same shape as create, PLUS agreement_sno and edited_by
--   (used as created_by would be).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_UpdateServiceAgreement', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_UpdateServiceAgreement;
GO
CREATE PROCEDURE dbo.sp_nt_UpdateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @agreement_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
        DECLARE @com_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @service_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @vendor_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @qty                DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4));
        DECLARE @rate_amount        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @rate_uom_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_uom_sno') AS INT);
        DECLARE @recurrence_cadence_sno INT       = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_cadence_sno') AS INT);
        DECLARE @po_generation_day  SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_generation_day') AS SMALLINT);
        DECLARE @notify_days_before SMALLINT      = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.notify_days_before') AS SMALLINT), 0);
        DECLARE @period_start_date  DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url  NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @edited_by          VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.edited_by');

        IF @agreement_sno IS NULL OR @edited_by IS NULL
            THROW 58120, 'agreement_sno and edited_by are required.', 1;

        DECLARE @current_status CHAR(1);
        SELECT @current_status = status FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno AND is_active = 'Y';
        IF @current_status IS NULL
            THROW 58121, 'Service agreement not found or inactive.', 1;
        IF @current_status NOT IN ('A', 'R')
            THROW 58122, 'Only an Approved or Rejected agreement can be edited (it is currently Pending approval).', 1;

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @service_sno IS NULL OR @vendor_sno IS NULL
            THROW 58123, 'com_sno, div_sno, brn_sno, dept_sno, service_sno and vendor_sno are required.', 1;
        IF @qty IS NULL OR @qty <= 0
            THROW 58124, 'qty must be a positive quantity.', 1;
        IF @rate_amount IS NULL OR @rate_amount <= 0
            THROW 58125, 'rate_amount must be a positive amount.', 1;
        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 58126, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;
        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 58127, 'agreement_doc_url is required.', 1;

        DECLARE @interval_unit VARCHAR(10);
        SELECT @interval_unit = interval_unit FROM dbo.recurrence_cadence_master WHERE recurrence_cadence_sno = @recurrence_cadence_sno AND is_active = 'Y';
        IF @interval_unit IS NULL
            THROW 58128, 'recurrence_cadence_sno does not reference an active recurrence cadence.', 1;
        IF @interval_unit = 'MONTH'
        BEGIN
            IF @po_generation_day IS NULL OR @po_generation_day NOT BETWEEN 1 AND 31
                THROW 58129, 'po_generation_day (1-31) is required for a month-based recurrence cadence.', 1;
        END
        ELSE
            SET @po_generation_day = NULL;

        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceAgreement';
        IF @workflow_types_id IS NULL
            THROW 58130, 'No ServiceAgreement workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id AND s.[key] = '0' AND s2.[key] = '0';
        IF @first_approver IS NULL
            THROW 58131, 'No approver found for the first stage of the ServiceAgreement workflow.', 1;

        UPDATE dbo.service_agreement
        SET com_sno = @com_sno, div_sno = @div_sno, brn_sno = @brn_sno, dept_sno = @dept_sno,
            service_sno = @service_sno, vendor_sno = @vendor_sno, qty = @qty, rate_amount = @rate_amount,
            rate_uom_sno = @rate_uom_sno, recurrence_cadence_sno = @recurrence_cadence_sno,
            po_generation_day = @po_generation_day, notify_days_before = @notify_days_before,
            period_start_date = @period_start_date, period_end_date = @period_end_date,
            agreement_doc_url = @agreement_doc_url, remarks = @remarks,
            workflow_types_id = @workflow_types_id, current_approver_id = @first_approver,
            status = 'P', modified_by = @edited_by, modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment)
        VALUES (@agreement_sno, 'RESUBMITTED', @edited_by, NULL);

        COMMIT TRANSACTION;

        SELECT @agreement_sno AS agreement_sno, 'SUCCESS' AS result, N'Service agreement updated and resubmitted for approval.' AS message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- 9) sp_nt_GetServiceAgreements — filtered list.
-- @jsonInput optional: { com_sno?, div_sno?, brn_sno?, dept_sno?, status? }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServiceAgreements', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceAgreements;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceAgreements
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL, @status CHAR(1) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @com_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        SET @status   = JSON_VALUE(@jsonInput, '$.status');
    END

    SELECT sa.agreement_sno, sa.agreement_no, sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
           sa.service_sno, sm.service_name, st.service_type_code, st.service_type_name,
           sa.vendor_sno, k.company_name AS vendor_name,
           sa.qty, sa.rate_amount, sa.rate_uom_sno, um.uom_name AS rate_uom_name,
           sa.recurrence_cadence_sno, rc.cadence_name, rc.interval_unit, rc.interval_value,
           sa.po_generation_day, sa.notify_days_before,
           sa.period_start_date, sa.period_end_date, sa.agreement_doc_url, sa.remarks,
           sa.current_approver_id, sa.status, sa.created_by, sa.created_at
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = sa.rate_uom_sno
    LEFT JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    WHERE sa.is_active = 'Y'
      AND (@com_sno IS NULL OR sa.com_sno = @com_sno)
      AND (@div_sno IS NULL OR sa.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR sa.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR sa.dept_sno = @dept_sno)
      AND (@status IS NULL OR sa.status = @status)
    ORDER BY sa.agreement_sno DESC;
END;
GO

-- ============================================================
-- 10) sp_nt_GetServiceAgreementsForApproval — logged-in approver's inbox.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServiceAgreementsForApproval', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceAgreementsForApproval;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceAgreementsForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT sa.agreement_sno, sa.agreement_no, sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
           sa.service_sno, sm.service_name, st.service_type_code, st.service_type_name,
           sa.vendor_sno, k.company_name AS vendor_name,
           sa.qty, sa.rate_amount, sa.rate_uom_sno, um.uom_name AS rate_uom_name,
           sa.recurrence_cadence_sno, rc.cadence_name,
           sa.po_generation_day, sa.notify_days_before,
           sa.period_start_date, sa.period_end_date, sa.agreement_doc_url, sa.remarks,
           sa.current_approver_id, sa.status, sa.created_by, sa.created_at,
           ws.stages_json AS stage_order_json
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = sa.rate_uom_sno
    LEFT JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    LEFT JOIN dbo.vw_workflow_stages ws ON ws.workflow_types_id = sa.workflow_types_id
    WHERE sa.is_active = 'Y' AND sa.status = 'P' AND sa.current_approver_id = @Ecno
    ORDER BY sa.agreement_sno DESC;
END;
GO

-- ============================================================
-- 11) sp_nt_GetApprovedVendorsForServicePicker — vendor picker.
--     NOTE: this exact name/shape is not incidental — backend-stpl's
--     CommonMasterRepo.js already has a generic "VendorMaster" common-master
--     key wired to this SP name (fieldMappings: label=company_name,
--     value=kyc_basic_info_sno, extra=[supp_code,email,mobile_number]). The
--     removal script dropped this SP (it originated from the old Service
--     migration set) without CommonMasterRepo.js being reverted, so
--     "VendorMaster" has been broken app-wide since the removal — recreating
--     it under its original name fixes that generic picker for every screen
--     that uses it, not just this one, and lets the Service Agreement form
--     use the standard useMasterOptions(["VendorMaster"]) hook instead of a
--     bespoke endpoint.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetApprovedVendorsForServicePicker', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetApprovedVendorsForServicePicker;
GO
CREATE PROCEDURE dbo.sp_nt_GetApprovedVendorsForServicePicker
AS
BEGIN
    SET NOCOUNT ON;
    SELECT kyc_basic_info_sno, company_name, supp_code, email, mobile_number
    FROM dbo.kyc_basic_info
    WHERE status = 'A' AND is_active = 'Y'
    ORDER BY company_name;
END;
GO

-- ============================================================
-- 12) sp_nt_DirectIssueServicePO — generic direct-issue PO creator, no
--     workflow/approval (mirrors the existing sp_nt_CreateCallOffPO
--     no-workflow precedent — an already-approved agreement doesn't need a
--     second procurement approval on every generated PO).
-- @jsonInput: { com_sno, div_sno, brn_sno, dept_sno, vendor_sno, pr_basic_sno,
--   pr_item_sno?, service_sno, qty, uom_sno?, unit_price, required_date?,
--   purpose?, issued_by? }
-- @silent: 1 = only set OUTPUT params, no SELECT (for nested calls).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_DirectIssueServicePO', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_DirectIssueServicePO;
GO
CREATE PROCEDURE dbo.sp_nt_DirectIssueServicePO
    @jsonInput NVARCHAR(MAX),
    @silent BIT = 0,
    @out_result VARCHAR(30) = NULL OUTPUT,
    @out_po_basic_sno INT = NULL OUTPUT,
    @out_po_no VARCHAR(50) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @com_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno     INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @vendor_sno   INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @pr_basic_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT);
        DECLARE @pr_item_sno  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_item_sno') AS INT);
        DECLARE @service_sno  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @qty          DECIMAL(18,4) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4)), 1);
        DECLARE @uom_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.uom_sno') AS INT);
        DECLARE @unit_price   DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.unit_price') AS DECIMAL(18,2));
        DECLARE @required_date DATE         = TRY_CAST(JSON_VALUE(@jsonInput, '$.required_date') AS DATE);
        DECLARE @purpose      VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.purpose');
        DECLARE @issued_by    VARCHAR(20)   = ISNULL(JSON_VALUE(@jsonInput, '$.issued_by'), 'SYSTEM');

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @vendor_sno IS NULL OR @pr_basic_sno IS NULL OR @service_sno IS NULL OR @unit_price IS NULL
            THROW 58201, 'com_sno, div_sno, brn_sno, dept_sno, vendor_sno, pr_basic_sno, service_sno and unit_price are required.', 1;

        DECLARE @service_type_sno INT;
        SELECT @service_type_sno = service_type_sno FROM dbo.service_master WHERE service_sno = @service_sno AND is_active = 'Y';
        IF @service_type_sno IS NULL
            THROW 58202, 'Unknown or inactive service_sno.', 1;

        DECLARE @net_cost DECIMAL(18,4) = @qty * @unit_price;

        BEGIN TRANSACTION;

        DECLARE @po_year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @po_seq  INT;
        SELECT @po_seq = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
        FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
        WHERE po_df_no LIKE 'SVO-' + @po_year + '-%';
        DECLARE @po_no VARCHAR(50) = 'SVO-' + @po_year + '-' + RIGHT('0000' + CAST(@po_seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.po_request_info (
            vendor_sno, brn_sno, dept_sno, com_sno, div_sno, budget_sno, budget_code, pr_basic_sno,
            po_date, required_date, purpose, terms_conditions, delivery_address,
            is_active, workflow_types_id, current_approver_id, status, po_df_no, service_type_sno
        )
        VALUES (
            @vendor_sno, @brn_sno, @dept_sno, @com_sno, @div_sno, NULL, NULL, @pr_basic_sno,
            CAST(GETDATE() AS DATE), ISNULL(@required_date, CAST(GETDATE() AS DATE)), @purpose, NULL, NULL,
            'Y', NULL, NULL, 'A', @po_no, @service_type_sno
        );
        DECLARE @po_basic_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.po_item_details (
            po_basic_sno, pr_item_sno, service_sno, prod_name, specification,
            qty, unit, unit_name, agreed_unit_price, total_cost, discount_pct, tax_pct, net_cost,
            remarks, po_section, created_by, created_date, is_active
        )
        SELECT
            @po_basic_sno, @pr_item_sno, @service_sno, sm.service_name, '',
            @qty, @uom_sno, um.uom_name, @unit_price, @net_cost, 0, 0, @net_cost,
            @purpose, 'SERVICE', @issued_by, GETDATE(), '1'
        FROM dbo.service_master sm
        LEFT JOIN dbo.uom_master um ON um.uom_sno = @uom_sno
        WHERE sm.service_sno = @service_sno;

        INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
        VALUES (@po_basic_sno, 'AUTO_ISSUED', @issued_by, N'Direct-issued from an approved Service Agreement, no separate PO approval required.', 'Y');

        COMMIT TRANSACTION;

        SET @out_result = 'SUCCESS';
        SET @out_po_basic_sno = @po_basic_sno;
        SET @out_po_no = @po_no;

        IF @silent = 0
            SELECT 'SUCCESS' AS result, @po_basic_sno AS po_basic_sno, @po_no AS po_no;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @out_result = 'ERROR';
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- 13) sp_nt_IssueRecurringServicePOCycle — one billing cycle: auto-creates
--     an auto-approved internal PR row (audit trail only, never a human
--     approval gate), then raises the PO via sp_nt_DirectIssueServicePO.
--     Idempotent per (agreement_sno, billing_period_start).
-- @jsonInput: { agreement_sno, billing_period_start, issued_by? }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_IssueRecurringServicePOCycle', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_IssueRecurringServicePOCycle;
GO
CREATE PROCEDURE dbo.sp_nt_IssueRecurringServicePOCycle
    @jsonInput NVARCHAR(MAX),
    @silent BIT = 0,
    @out_result VARCHAR(30) = NULL OUTPUT,
    @out_po_basic_sno INT = NULL OUTPUT,
    @out_po_no VARCHAR(50) = NULL OUTPUT,
    @out_pr_basic_sno INT = NULL OUTPUT,
    @out_pr_no VARCHAR(20) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @agreement_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
    DECLARE @billing_period_start DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.billing_period_start') AS DATE);
    DECLARE @issued_by VARCHAR(20) = ISNULL(JSON_VALUE(@jsonInput, '$.issued_by'), 'SYSTEM');

    BEGIN TRY
        IF @agreement_sno IS NULL OR @billing_period_start IS NULL
            THROW 58210, 'agreement_sno and billing_period_start are required.', 1;

        IF EXISTS (SELECT 1 FROM dbo.service_agreement_recurring_pr_log WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start)
        BEGIN
            SET @out_result = 'SKIPPED_ALREADY_CLAIMED';
            IF @silent = 0 SELECT @out_result AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start;
            RETURN;
        END

        DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @service_sno INT, @vendor_sno INT,
                @qty DECIMAL(18,4), @rate_amount DECIMAL(18,2), @rate_uom_sno INT, @agreement_no VARCHAR(30),
                @service_name NVARCHAR(150), @agr_status CHAR(1), @period_end DATE;

        SELECT @com_sno = sa.com_sno, @div_sno = sa.div_sno, @brn_sno = sa.brn_sno, @dept_sno = sa.dept_sno,
               @service_sno = sa.service_sno, @vendor_sno = sa.vendor_sno, @qty = sa.qty, @rate_amount = sa.rate_amount,
               @rate_uom_sno = sa.rate_uom_sno, @agreement_no = sa.agreement_no, @agr_status = sa.status,
               @period_end = sa.period_end_date, @service_name = sm.service_name
        FROM dbo.service_agreement sa
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        WHERE sa.agreement_sno = @agreement_sno;

        IF @agr_status IS NULL THROW 58211, 'Agreement not found.', 1;
        IF @agr_status <> 'A' THROW 58212, 'Agreement is not Approved.', 1;
        IF @billing_period_start > @period_end THROW 58213, 'billing_period_start is past the agreement period_end_date.', 1;

        -- Claim the slot before doing any real work, outside the main
        -- transaction, so it survives a rollback and guarantees idempotency
        -- even under a concurrent sweep.
        INSERT INTO dbo.service_agreement_recurring_pr_log (agreement_sno, billing_period_start, status)
        VALUES (@agreement_sno, @billing_period_start, 'PENDING');

        BEGIN TRANSACTION;

        DECLARE @default_priority_sno INT;
        SELECT TOP 1 @default_priority_sno = priority_sno
        FROM dbo.priority_master
        WHERE is_active = 'Y'
        ORDER BY CASE WHEN priority_name = 'Medium' THEN 0 ELSE 1 END, priority_sno;
        IF @default_priority_sno IS NULL
            THROW 58214, 'No active priority_master row found to assign to the auto-generated PR.', 1;

        DECLARE @current_year VARCHAR(10) = dbo.fn_GetFinancialYear(GETDATE());
        DECLARE @pr_prefix VARCHAR(20) = 'PR' + @current_year;
        DECLARE @pr_seq INT;
        SELECT @pr_seq = ISNULL(MAX(CASE WHEN pr_no LIKE @pr_prefix + '%' THEN TRY_CAST(SUBSTRING(pr_no, LEN(@pr_prefix) + 1, LEN(pr_no)) AS INT) ELSE 0 END), 0) + 1
        FROM dbo.pr_basic_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE @pr_prefix + '%';
        DECLARE @pr_no VARCHAR(20) = @pr_prefix + RIGHT('0000' + CAST(@pr_seq AS VARCHAR(4)), 4);

        -- Auto-approved: status='A', no workflow — the human decision
        -- already happened at agreement-approval time. Never shown to a
        -- user as something to approve.
        INSERT INTO dbo.pr_basic_info (
            pr_no, com_sno, div_sno, brn_sno, dept_sno, reg_date, required_date, priority_sno, purpose,
            is_active, created_by, created_date, workflow_types_id, current_approver_id, status
        )
        VALUES (
            @pr_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @billing_period_start, @billing_period_start, @default_priority_sno,
            N'Auto-generated recurring PR — Service Agreement ' + @agreement_no,
            'Y', @issued_by, GETDATE(), NULL, NULL, 'A'
        );
        DECLARE @pr_basic_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.pr_item_details (
            pr_no, pr_basic_sno, prod_sno, qty, unit, est_cost, total_cost, remarks, specification,
            item_type, service_sno, agreement_sno, is_active, created_by, created_date
        )
        VALUES (
            @pr_no, @pr_basic_sno, NULL, @qty, @rate_uom_sno, @rate_amount, @rate_amount * @qty, '', '',
            'service', @service_sno, @agreement_sno, 'Y', @issued_by, GETDATE()
        );
        DECLARE @pr_item_sno INT = SCOPE_IDENTITY();

        DECLARE @poJson NVARCHAR(MAX) = (
            SELECT @com_sno AS com_sno, @div_sno AS div_sno, @brn_sno AS brn_sno, @dept_sno AS dept_sno,
                   @vendor_sno AS vendor_sno, @pr_basic_sno AS pr_basic_sno, @pr_item_sno AS pr_item_sno,
                   @service_sno AS service_sno, @qty AS qty, @rate_uom_sno AS uom_sno, @rate_amount AS unit_price,
                   @period_end AS required_date, @issued_by AS issued_by,
                   (N'Recurring service PO — Agreement ' + @agreement_no + N' (' + @service_name + N'), period starting ' + CONVERT(VARCHAR(10), @billing_period_start, 120)) AS purpose
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        DECLARE @po_result VARCHAR(30), @po_basic_sno INT, @po_no VARCHAR(50);
        EXEC dbo.sp_nt_DirectIssueServicePO
            @jsonInput = @poJson, @silent = 1,
            @out_result = @po_result OUTPUT, @out_po_basic_sno = @po_basic_sno OUTPUT, @out_po_no = @po_no OUTPUT;

        UPDATE dbo.service_agreement_recurring_pr_log
        SET status = 'CREATED', pr_basic_sno = @pr_basic_sno, pr_no = @pr_no,
            po_basic_sno = @po_basic_sno, po_no = @po_no, modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start;

        COMMIT TRANSACTION;

        SET @out_result = 'SUCCESS';
        SET @out_po_basic_sno = @po_basic_sno;
        SET @out_po_no = @po_no;
        SET @out_pr_basic_sno = @pr_basic_sno;
        SET @out_pr_no = @pr_no;

        IF @silent = 0
            SELECT 'SUCCESS' AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start,
                   @pr_basic_sno AS pr_basic_sno, @pr_no AS pr_no, @po_basic_sno AS po_basic_sno, @po_no AS po_no;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        UPDATE dbo.service_agreement_recurring_pr_log
        SET status = 'FAILED', error_message = ERROR_MESSAGE(), modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start AND status = 'PENDING';

        SET @out_result = 'ERROR';
        IF @silent = 0 THROW;
    END CATCH
END;
GO

-- ============================================================
-- 14) sp_approve_service_agreement — multi-stage approve/reject, same
--     stage-progression shape as sp_approve_pr_datas. On final approval:
--     for an Unfixed (VARIABLE_RECURRING) agreement, requires
--     final_rate_amount/final_qty and overwrites the approximate values
--     (one-time only — see file header); then, only on a true first-ever
--     approval (no existing recurring-log rows — an edit's re-approval
--     doesn't double-issue), issues the first billing cycle immediately
--     rather than waiting for the next sweep.
-- @jsonInput: { agreement_sno, approved_by, comments, approval_stages,
--   action, final_rate_amount?, final_qty? }
-- ============================================================
IF OBJECT_ID('dbo.sp_approve_service_agreement', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_approve_service_agreement;
GO
CREATE PROCEDURE dbo.sp_approve_service_agreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF ISJSON(@jsonInput) = 0
        BEGIN
            RAISERROR('Invalid JSON format for @jsonInput', 16, 1);
            RETURN;
        END

        DECLARE @agreement_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT),
                @comments         VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages  NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by      VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action           VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action'),
                @final_rate_amount DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.final_rate_amount') AS DECIMAL(18,2)),
                @final_qty        DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.final_qty') AS DECIMAL(18,4));

        IF @agreement_sno IS NULL
        BEGIN
            RAISERROR('agreement_sno is required.', 16, 1);
            RETURN;
        END

        IF @action IS NULL OR LTRIM(RTRIM(LOWER(@action))) NOT IN ('approve', 'reject')
        BEGIN
            RAISERROR('Invalid action. Must be ''approve'' or ''reject''.', 16, 1);
            RETURN;
        END
        SET @action = LOWER(LTRIM(RTRIM(@action)));

        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
        BEGIN
            RAISERROR('Invalid or missing approval_stages in JSON', 16, 1);
            RETURN;
        END

        IF @approved_by IS NULL OR LTRIM(RTRIM(@approved_by)) = ''
        BEGIN
            RAISERROR('Approver EC number is required.', 16, 1);
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno AND is_active = 'Y')
        BEGIN
            RAISERROR('Service agreement not found or inactive.', 16, 1);
            RETURN;
        END

        CREATE TABLE #approval_stages (
            seq_no INT, approver_ecno VARCHAR(30), stage VARCHAR(100),
            required_approvals VARCHAR(10), is_mandatory CHAR(1), escalation_hours VARCHAR(10),
            approver_condition VARCHAR(200), next_approver_ecno VARCHAR(30),
            can_forward CHAR(1), can_backward CHAR(1), can_edit_data CHAR(1)
        );

        INSERT INTO #approval_stages (
            seq_no, approver_ecno, stage, required_approvals, is_mandatory,
            escalation_hours, approver_condition, next_approver_ecno,
            can_forward, can_backward, can_edit_data
        )
        SELECT
            CAST(ojBase.[key] AS INT),
            JSON_VALUE(ojBase.[value], '$.approver_ecno'),
            JSON_VALUE(ojBase.[value], '$.stage'),
            JSON_VALUE(ojBase.[value], '$.required_approvals'),
            JSON_VALUE(ojBase.[value], '$.is_mandatory'),
            JSON_VALUE(ojBase.[value], '$.escalation_hours'),
            JSON_VALUE(ojBase.[value], '$.approver_condition'),
            JSON_VALUE(ojBase.[value], '$.next_approver_ecno'),
            JSON_VALUE(ojBase.[value], '$.can_forward'),
            JSON_VALUE(ojBase.[value], '$.can_backward'),
            JSON_VALUE(ojBase.[value], '$.can_edit_data')
        FROM OPENJSON(@approval_stages) AS ojBase;

        IF @action = 'reject'
        BEGIN
            INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment)
            VALUES (@agreement_sno, 'REJECTED', @approved_by, @comments);

            UPDATE dbo.service_agreement SET status = 'R', current_approver_id = NULL WHERE agreement_sno = @agreement_sno;

            DROP TABLE #approval_stages;
            SELECT 'REJECTED' AS result, @agreement_sno AS agreement_sno, @approved_by AS rejected_by, GETDATE() AS rejected_on;
            RETURN;
        END

        DECLARE @next_current_approver VARCHAR(30);
        SELECT @next_current_approver = next_stage.approver_ecno
        FROM (
            SELECT approver_ecno, LEAD(approver_ecno, 1, NULL) OVER (ORDER BY seq_no) AS next_approver_ecno
            FROM #approval_stages
        ) current_stage
        LEFT JOIN #approval_stages next_stage ON next_stage.approver_ecno = current_stage.next_approver_ecno
        WHERE current_stage.approver_ecno = @approved_by;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment)
        VALUES (@agreement_sno, 'APPROVED', @approved_by, @comments);

        UPDATE dbo.service_agreement SET current_approver_id = @next_current_approver WHERE agreement_sno = @agreement_sno;

        DECLARE @auto_po_result VARCHAR(200) = NULL, @auto_po_basic_sno INT = NULL, @auto_po_no VARCHAR(50) = NULL,
                @auto_pr_basic_sno INT = NULL, @auto_pr_no VARCHAR(20) = NULL;

        IF @next_current_approver IS NULL
        BEGIN
            -- ── Final stage: for Unfixed, require + apply the one-time real value ──
            DECLARE @service_type_code VARCHAR(30), @period_start DATE, @old_rate DECIMAL(18,2), @old_qty DECIMAL(18,4);
            SELECT @service_type_code = st.service_type_code, @period_start = sa.period_start_date,
                   @old_rate = sa.rate_amount, @old_qty = sa.qty
            FROM dbo.service_agreement sa
            JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
            JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
            WHERE sa.agreement_sno = @agreement_sno;

            IF @service_type_code = 'VARIABLE_RECURRING'
            BEGIN
                IF @final_rate_amount IS NULL OR @final_rate_amount <= 0 OR @final_qty IS NULL OR @final_qty <= 0
                BEGIN
                    RAISERROR('This is an Unfixed agreement — final_rate_amount and final_qty are required to complete the final approval.', 16, 1);
                    RETURN;
                END

                UPDATE dbo.service_agreement SET rate_amount = @final_rate_amount, qty = @final_qty WHERE agreement_sno = @agreement_sno;

                INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment)
                VALUES (@agreement_sno, 'RATE_FINALIZED', @approved_by,
                        N'Rate ' + CAST(@old_rate AS VARCHAR(30)) + N' -> ' + CAST(@final_rate_amount AS VARCHAR(30))
                        + N', Qty ' + CAST(@old_qty AS VARCHAR(30)) + N' -> ' + CAST(@final_qty AS VARCHAR(30)));
            END

            UPDATE dbo.service_agreement SET status = 'A' WHERE agreement_sno = @agreement_sno;

            IF NOT EXISTS (SELECT 1 FROM dbo.service_agreement_recurring_pr_log WHERE agreement_sno = @agreement_sno)
            BEGIN
                DECLARE @first_billing_period_start DATE = CASE WHEN CAST(GETDATE() AS DATE) < @period_start THEN @period_start ELSE CAST(GETDATE() AS DATE) END;
                DECLARE @firstCycleJson NVARCHAR(MAX) = (
                    SELECT @agreement_sno AS agreement_sno, @first_billing_period_start AS billing_period_start, @approved_by AS issued_by
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
                );

                BEGIN TRY
                    EXEC dbo.sp_nt_IssueRecurringServicePOCycle
                        @jsonInput = @firstCycleJson, @silent = 1,
                        @out_result = @auto_po_result OUTPUT, @out_po_basic_sno = @auto_po_basic_sno OUTPUT, @out_po_no = @auto_po_no OUTPUT,
                        @out_pr_basic_sno = @auto_pr_basic_sno OUTPUT, @out_pr_no = @auto_pr_no OUTPUT;
                END TRY
                BEGIN CATCH
                    -- Do not fail the approval itself — service_agreement_recurring_pr_log
                    -- already has a FAILED row for ops to find and retry via a fresh sweep call.
                    SET @auto_po_result = 'ERROR: ' + ERROR_MESSAGE();
                END CATCH
            END
        END

        DROP TABLE #approval_stages;

        SELECT
            'SUCCESS' AS result, @agreement_sno AS agreement_sno, @approved_by AS approved_by, GETDATE() AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE') AS next_approver,
            @auto_po_result AS auto_po_result, @auto_po_basic_sno AS auto_po_basic_sno, @auto_po_no AS auto_po_no,
            @auto_pr_basic_sno AS auto_pr_basic_sno, @auto_pr_no AS auto_pr_no;
    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL DROP TABLE #approval_stages;
        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO

-- ============================================================
-- 15) sp_nt_ProcessDueRecurringServiceAgreements — sweep entry point.
--     Applies identically to Fixed and Unfixed (both are 'A' with a final
--     value by the time they can be due).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ProcessDueRecurringServiceAgreements', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ProcessDueRecurringServiceAgreements;
GO
CREATE PROCEDURE dbo.sp_nt_ProcessDueRecurringServiceAgreements
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @due TABLE (agreement_sno INT, billing_period_start DATE);

    INSERT INTO @due (agreement_sno, billing_period_start)
    SELECT sa.agreement_sno, @today
    FROM dbo.service_agreement sa
    JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    WHERE sa.status = 'A' AND sa.is_active = 'Y'
      AND @today BETWEEN sa.period_start_date AND sa.period_end_date
      AND (
            (rc.interval_unit = 'DAY' AND DATEDIFF(DAY, sa.period_start_date, @today) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NOT NULL
             AND DAY(@today) = CASE WHEN sa.po_generation_day > DAY(EOMONTH(@today)) THEN DAY(EOMONTH(@today)) ELSE sa.po_generation_day END
             AND DATEDIFF(MONTH, sa.period_start_date, @today) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NULL
             AND DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, @today) / rc.interval_value) * rc.interval_value, sa.period_start_date) = @today)
          )
      AND NOT EXISTS (SELECT 1 FROM dbo.service_agreement_recurring_pr_log l WHERE l.agreement_sno = sa.agreement_sno AND l.billing_period_start = @today);

    DECLARE @agreement_sno INT, @billing_period_start DATE;
    DECLARE @success_count INT = 0, @skipped_count INT = 0, @failed_count INT = 0;
    DECLARE @row_result VARCHAR(30), @row_po INT, @row_po_no VARCHAR(50), @row_pr INT, @row_pr_no VARCHAR(20), @rowJson NVARCHAR(MAX);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT agreement_sno, billing_period_start FROM @due;
    OPEN cur;
    FETCH NEXT FROM cur INTO @agreement_sno, @billing_period_start;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @rowJson = (SELECT @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start, 'SYSTEM' AS issued_by FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.sp_nt_IssueRecurringServicePOCycle
            @jsonInput = @rowJson, @silent = 1,
            @out_result = @row_result OUTPUT, @out_po_basic_sno = @row_po OUTPUT, @out_po_no = @row_po_no OUTPUT,
            @out_pr_basic_sno = @row_pr OUTPUT, @out_pr_no = @row_pr_no OUTPUT;

        IF @row_result = 'SUCCESS' SET @success_count = @success_count + 1;
        ELSE IF @row_result LIKE 'SKIPPED%' SET @skipped_count = @skipped_count + 1;
        ELSE SET @failed_count = @failed_count + 1;

        FETCH NEXT FROM cur INTO @agreement_sno, @billing_period_start;
    END
    CLOSE cur;
    DEALLOCATE cur;

    SELECT (SELECT COUNT(*) FROM @due) AS due_count, @success_count AS success_count, @skipped_count AS skipped_count, @failed_count AS failed_count;
END;
GO

-- ============================================================
-- 16) sp_nt_ExpireServiceAgreements — enforces "after the to-date, a new
--     agreement is required": flips Approved agreements past their
--     period_end_date to Expired, which drops them out of the sweep above.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ExpireServiceAgreements', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ExpireServiceAgreements;
GO
CREATE PROCEDURE dbo.sp_nt_ExpireServiceAgreements
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @expired TABLE (agreement_sno INT);

    UPDATE dbo.service_agreement
    SET status = 'X'
    OUTPUT inserted.agreement_sno INTO @expired
    WHERE status = 'A' AND is_active = 'Y' AND period_end_date < CAST(GETDATE() AS DATE);

    INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment)
    SELECT agreement_sno, 'EXPIRED', 'SYSTEM', N'Period end date passed — create a new agreement to continue this service.'
    FROM @expired;

    SELECT COUNT(*) AS expired_count FROM @expired;
END;
GO

-- ============================================================
-- 17) Notify-before sweep — one unified code path for both agreement types.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetAgreementsDueForNotification', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetAgreementsDueForNotification;
GO
CREATE PROCEDURE dbo.sp_nt_GetAgreementsDueForNotification
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @due TABLE (agreement_sno INT, due_date DATE);

    INSERT INTO @due (agreement_sno, due_date)
    SELECT sa.agreement_sno, DATEADD(DAY, sa.notify_days_before, @today)
    FROM dbo.service_agreement sa
    JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    WHERE sa.status = 'A' AND sa.is_active = 'Y' AND sa.notify_days_before > 0
      AND DATEADD(DAY, sa.notify_days_before, @today) BETWEEN sa.period_start_date AND sa.period_end_date
      AND (
            (rc.interval_unit = 'DAY' AND DATEDIFF(DAY, sa.period_start_date, DATEADD(DAY, sa.notify_days_before, @today)) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NOT NULL
             AND DAY(DATEADD(DAY, sa.notify_days_before, @today)) = CASE WHEN sa.po_generation_day > DAY(EOMONTH(DATEADD(DAY, sa.notify_days_before, @today))) THEN DAY(EOMONTH(DATEADD(DAY, sa.notify_days_before, @today))) ELSE sa.po_generation_day END
             AND DATEDIFF(MONTH, sa.period_start_date, DATEADD(DAY, sa.notify_days_before, @today)) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NULL
             AND DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, DATEADD(DAY, sa.notify_days_before, @today)) / rc.interval_value) * rc.interval_value, sa.period_start_date) = DATEADD(DAY, sa.notify_days_before, @today))
          )
      AND NOT EXISTS (SELECT 1 FROM dbo.service_agreement_notification_log l WHERE l.agreement_sno = sa.agreement_sno AND l.billing_period_start = DATEADD(DAY, sa.notify_days_before, @today));

    DECLARE @claimed TABLE (agreement_sno INT, due_date DATE);
    DECLARE @a_sno INT, @d_date DATE;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT agreement_sno, due_date FROM @due;
    OPEN cur;
    FETCH NEXT FROM cur INTO @a_sno, @d_date;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.service_agreement_notification_log (agreement_sno, billing_period_start, status)
            VALUES (@a_sno, @d_date, 'PENDING');
            INSERT INTO @claimed (agreement_sno, due_date) VALUES (@a_sno, @d_date);
        END TRY
        BEGIN CATCH
            -- Unique-key collision: another sweep already claimed this row. Skip it.
        END CATCH
        FETCH NEXT FROM cur INTO @a_sno, @d_date;
    END
    CLOSE cur;
    DEALLOCATE cur;

    SELECT sa.agreement_sno, sa.agreement_no, sa.created_by AS notify_ecno, sm.service_name,
           sa.rate_amount, sa.po_generation_day, sa.notify_days_before, c.due_date
    FROM @claimed c
    JOIN dbo.service_agreement sa ON sa.agreement_sno = c.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno;
END;
GO

IF OBJECT_ID('dbo.sp_nt_MarkAgreementNotificationSent', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_MarkAgreementNotificationSent;
GO
CREATE PROCEDURE dbo.sp_nt_MarkAgreementNotificationSent
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @agreement_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
    DECLARE @billing_period_start DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.billing_period_start') AS DATE);
    DECLARE @status VARCHAR(20) = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @notif_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.notif_sno') AS INT);
    DECLARE @error_message NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.error_message');

    IF @agreement_sno IS NULL OR @billing_period_start IS NULL OR @status NOT IN ('SENT', 'FAILED')
        THROW 58220, 'agreement_sno, billing_period_start and a valid status (SENT|FAILED) are required.', 1;

    UPDATE dbo.service_agreement_notification_log
    SET status = @status, notif_sno = @notif_sno, error_message = @error_message, modified_at = GETDATE()
    WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start;

    SELECT @@ROWCOUNT AS rows_updated;
END;
GO

-- ============================================================
-- 18) Sidebar registration — screens rows + grant helper (idempotent;
--     sp_nt_GrantScreenToUser reused as-is if it already exists live).
-- ============================================================
DECLARE @group_id           INT           = 2;
DECLARE @screen_code        VARCHAR(10)   = N'S17';
DECLARE @comp_img_value     NVARCHAR(100) = N'FileSignature';

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceAgreementPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service Agreements', @screen_code, 'ServiceAgreementPage', @comp_img_value, @group_id, 23, 'Y');

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceAgreementApprovalScreen')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service Agreement Approvals', @screen_code, 'ServiceAgreementApprovalScreen', @comp_img_value, @group_id, 24, 'Y');
GO

-- Reuses the exact sp_nt_GrantScreenToUser shape already introduced by the
-- original (removed) 14_service_agreement_screens.sql — that proc itself was
-- never in the removal script's drop list, so this is very likely a no-op
-- CREATE OR ALTER on an already-live object; written as a plain DROP+CREATE
-- (this file's own convention) purely for idempotent safety if it isn't.
IF OBJECT_ID('dbo.sp_nt_GrantScreenToUser', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GrantScreenToUser;
GO
CREATE PROCEDURE dbo.sp_nt_GrantScreenToUser
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ecno VARCHAR(50) = JSON_VALUE(@jsonInput, '$.ecno');
    DECLARE @screen_id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.screen_id') AS INT);
    DECLARE @permission_ids NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.permission_ids');

    IF @ecno IS NULL OR @screen_id IS NULL OR @permission_ids IS NULL
        THROW 58230, 'ecno, screen_id and permission_ids are required.', 1;

    DECLARE @user_perm_json_sno INT, @screens_json NVARCHAR(MAX);
    SELECT TOP 1 @user_perm_json_sno = user_perm_json_sno, @screens_json = RTRIM(screens_json)
    FROM dbo.nt_user_permissions_json
    WHERE ecno = @ecno AND is_active = 'Y'
    ORDER BY user_perm_json_sno DESC;

    IF @user_perm_json_sno IS NULL
        THROW 58231, 'No active nt_user_permissions_json row for this ecno.', 1;

    IF EXISTS (SELECT 1 FROM OPENJSON(@screens_json) WITH (screen_id INT '$.screen_id') WHERE screen_id = @screen_id)
    BEGIN
        SELECT 'ALREADY_GRANTED' AS result, @user_perm_json_sno AS user_perm_json_sno;
        RETURN;
    END

    DECLARE @newEntry NVARCHAR(MAX) = (SELECT @screen_id AS screen_id, JSON_QUERY(@permission_ids) AS permissions FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @updatedScreens NVARCHAR(MAX);
    IF @screens_json IS NULL OR @screens_json IN ('[]', '')
        SET @updatedScreens = '[' + @newEntry + ']';
    ELSE
        SET @updatedScreens = LEFT(@screens_json, LEN(@screens_json) - 1) + ',' + @newEntry + ']';

    UPDATE dbo.nt_user_permissions_json
    SET screens_json = @updatedScreens, updated_date = GETDATE()
    WHERE user_perm_json_sno = @user_perm_json_sno;

    SELECT 'GRANTED' AS result, @user_perm_json_sno AS user_perm_json_sno, @updatedScreens AS screens_json;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.service_type_master;
--   SELECT * FROM dbo.recurrence_cadence_master;
--   SELECT * FROM dbo.entity_master WHERE entity_code = 'ServiceAgreement';
--   SELECT * FROM dbo.screens WHERE comp LIKE 'ServiceAgreement%';
--   SELECT name FROM sys.procedures WHERE name LIKE '%Service%' OR name = 'sp_approve_service_agreement' ORDER BY name;
--
-- Then, required manual step (not automatable from this file):
--   Configure an approval workflow for entity_type='ServiceAgreement' at the
--   needed company/division/branch/department scope via the existing
--   UserRoleApprovalScreen.tsx admin UI, and grant the two new screens to the
--   relevant users via sp_nt_GrantScreenToUser.
-- ============================================================
