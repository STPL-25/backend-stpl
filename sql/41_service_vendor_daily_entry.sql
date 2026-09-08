-- ============================================================
-- service_vendor_daily_entry — Vendor Driven daily logging + consolidation
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : new backend-stpl/src/ServiceVendorEntry module
--
-- Why this is needed
-- ------------------
-- The Vendor Driven (VENDOR_BILL) Service PO flow (ServiceAgreementPage.tsx's
-- third tab, backed by sp_nt_CreateServicePO) was a single-sitting form: add
-- one or more items and submit once, immediately creating the PO. That does
-- not model a real Vendor Driven case the user described — e.g. a milk
-- vendor delivers daily, quantity/price entered each day, and only
-- periodically (a "consolidated date") are the accumulated daily entries
-- reviewed and selected to raise ONE PO.
--
-- This file adds a staging table for those daily entries plus the procs to
-- create one, list them, and atomically consolidate a selected set into a
-- real Service PO. It does NOT duplicate PO-creation logic — the actual PO
-- row is still created by the existing sp_nt_CreateServicePO, called from
-- Node (ServiceVendorEntryService#consolidate) exactly the same way the old
-- one-shot Vendor Driven submit already did. These procs only manage the
-- staging rows around that call:
--   1. sp_nt_LockServiceVendorEntriesForConsolidation — atomically flips
--      selected PENDING rows to PROCESSING and returns them, so two
--      concurrent consolidations can't both claim the same entry (classic
--      SELECT-then-UPDATE race, closed with UPDLOCK/HOLDLOCK + an OUTPUT
--      clause on one UPDATE statement).
--   2. Node builds the items[] array from the locked rows and calls the
--      existing ServicePOService.createServicePO (sp_nt_CreateServicePO).
--   3. sp_nt_FinalizeServiceVendorEntriesConsolidation on success (PROCESSING
--      -> CONSOLIDATED, records po_basic_sno), or
--      sp_nt_ReleaseServiceVendorEntriesLock on failure (PROCESSING back to
--      PENDING) — so a PO-creation failure never strands entries in limbo.
--
-- vendor_sno/service_sno FK targets match sp_nt_CreateServicePO's own
-- shape (kyc_basic_info.kyc_basic_info_sno, service_master.service_sno) and
-- service_agreement's vendor FK (10_service_agreement.sql) — same
-- conventions, not a new pattern.
-- ============================================================

-- ── service_vendor_daily_entry ──────────────────────────────────────────────

IF OBJECT_ID('dbo.service_vendor_daily_entry', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_vendor_daily_entry (
        entry_sno          INT IDENTITY(1,1) PRIMARY KEY,
        com_sno             INT           NOT NULL,
        div_sno             INT           NOT NULL,
        brn_sno             INT           NOT NULL,
        dept_sno            INT           NOT NULL,
        vendor_sno          INT           NOT NULL,
        service_sno         INT           NOT NULL,
        entry_date          DATE          NOT NULL,
        qty                 DECIMAL(18,4) NOT NULL,
        unit                INT           NULL,
        unit_price          DECIMAL(18,4) NOT NULL,
        total_amount        DECIMAL(18,4) NOT NULL,
        specification       NVARCHAR(500) NULL,
        remarks             NVARCHAR(500) NULL,
        -- PENDING (logged, not yet raised) -> PROCESSING (claimed by an
        -- in-flight consolidation) -> CONSOLIDATED (PO raised) | back to
        -- PENDING on failure. CANCELLED is a manual correction of a mistaken entry.
        status              VARCHAR(20)   NOT NULL DEFAULT 'PENDING',
        po_basic_sno        INT           NULL,
        created_by          VARCHAR(20)   NOT NULL,
        created_date        DATETIME      NOT NULL DEFAULT GETDATE(),
        consolidated_by     VARCHAR(20)   NULL,
        consolidated_date   DATETIME      NULL,
        is_active           CHAR(1)       NOT NULL DEFAULT 'Y',
        CONSTRAINT CK_service_vendor_daily_entry_status CHECK (status IN ('PENDING','PROCESSING','CONSOLIDATED','CANCELLED')),
        CONSTRAINT CK_service_vendor_daily_entry_qty CHECK (qty > 0),
        CONSTRAINT CK_service_vendor_daily_entry_price CHECK (unit_price >= 0),
        CONSTRAINT FK_service_vendor_daily_entry_vendor FOREIGN KEY (vendor_sno)
            REFERENCES dbo.kyc_basic_info (kyc_basic_info_sno),
        CONSTRAINT FK_service_vendor_daily_entry_service FOREIGN KEY (service_sno)
            REFERENCES dbo.service_master (service_sno),
        CONSTRAINT FK_service_vendor_daily_entry_uom FOREIGN KEY (unit)
            REFERENCES dbo.uom_master (uom_sno),
        CONSTRAINT FK_service_vendor_daily_entry_po FOREIGN KEY (po_basic_sno)
            REFERENCES dbo.po_request_info (po_basic_sno)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_service_vendor_daily_entry_vendor_status' AND object_id = OBJECT_ID('dbo.service_vendor_daily_entry'))
    CREATE INDEX IX_service_vendor_daily_entry_vendor_status
        ON dbo.service_vendor_daily_entry (vendor_sno, status, entry_date);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_service_vendor_daily_entry_scope' AND object_id = OBJECT_ID('dbo.service_vendor_daily_entry'))
    CREATE INDEX IX_service_vendor_daily_entry_scope
        ON dbo.service_vendor_daily_entry (com_sno, div_sno, brn_sno, dept_sno, status);
GO

-- ============================================================
-- sp_nt_CreateServiceVendorDailyEntry
-- @jsonInput: {com_sno,div_sno,brn_sno,dept_sno,vendor_sno,service_sno,
--              entry_date,qty,unit,unit_price,specification,remarks,created_by}
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateServiceVendorDailyEntry', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateServiceVendorDailyEntry;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceVendorDailyEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
    DECLARE @div_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
    DECLARE @brn_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
    DECLARE @dept_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
    DECLARE @vendor_sno     INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    DECLARE @service_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
    DECLARE @entry_date     DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.entry_date') AS DATE);
    DECLARE @qty            DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4));
    DECLARE @unit           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.unit') AS INT);
    DECLARE @unit_price     DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.unit_price') AS DECIMAL(18,4));
    DECLARE @specification  NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.specification');
    DECLARE @remarks        NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
    DECLARE @created_by     VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
       OR @vendor_sno IS NULL OR @service_sno IS NULL OR @entry_date IS NULL OR @created_by IS NULL
        THROW 54100, 'com_sno, div_sno, brn_sno, dept_sno, vendor_sno, service_sno, entry_date and created_by are required.', 1;

    IF @qty IS NULL OR @qty <= 0
        THROW 54102, 'qty must be greater than 0.', 1;

    IF @unit_price IS NULL OR @unit_price < 0
        THROW 54103, 'unit_price is required and cannot be negative.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND st.service_type_code = 'VENDOR_BILL' AND sm.is_active = 'Y'
    )
        THROW 54101, 'service_sno must reference an active Vendor-Bill-Driven service.', 1;

    DECLARE @total_amount DECIMAL(18,4) = @qty * @unit_price;

    INSERT INTO dbo.service_vendor_daily_entry (
        com_sno, div_sno, brn_sno, dept_sno, vendor_sno, service_sno,
        entry_date, qty, unit, unit_price, total_amount,
        specification, remarks, status, created_by, created_date, is_active
    )
    VALUES (
        @com_sno, @div_sno, @brn_sno, @dept_sno, @vendor_sno, @service_sno,
        @entry_date, @qty, @unit, @unit_price, @total_amount,
        @specification, @remarks, 'PENDING', @created_by, GETDATE(), 'Y'
    );

    DECLARE @entry_sno INT = SCOPE_IDENTITY();

    SELECT
        e.entry_sno, e.com_sno, e.div_sno, e.brn_sno, e.dept_sno,
        e.vendor_sno, k.company_name AS vendor_name,
        e.service_sno, sm.service_name,
        e.entry_date, e.qty, e.unit, um.uom_name AS unit_name, e.unit_price, e.total_amount,
        e.specification, e.remarks, e.status, e.created_by, e.created_date
    FROM dbo.service_vendor_daily_entry e
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = e.vendor_sno
    LEFT JOIN dbo.service_master sm ON sm.service_sno = e.service_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = e.unit
    WHERE e.entry_sno = @entry_sno;
END;
GO

-- ============================================================
-- sp_nt_GetServiceVendorDailyEntries
-- @jsonInput optional filters: {vendor_sno, service_sno, com_sno, div_sno,
--   brn_sno, dept_sno, status, date_from, date_to}
-- status not provided -> every row except CANCELLED (browsing default);
-- pass status explicitly (e.g. "PENDING") to narrow for the consolidation screen.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServiceVendorDailyEntries', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetServiceVendorDailyEntries;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceVendorDailyEntries
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @vendor_sno  INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    DECLARE @service_sno INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
    DECLARE @com_sno     INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
    DECLARE @div_sno     INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
    DECLARE @brn_sno     INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
    DECLARE @dept_sno    INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
    DECLARE @status      VARCHAR(20) = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @date_from   DATE        = TRY_CAST(JSON_VALUE(@jsonInput, '$.date_from') AS DATE);
    DECLARE @date_to     DATE        = TRY_CAST(JSON_VALUE(@jsonInput, '$.date_to') AS DATE);

    SELECT
        e.entry_sno, e.com_sno, e.div_sno, e.brn_sno, e.dept_sno,
        e.vendor_sno, k.company_name AS vendor_name,
        e.service_sno, sm.service_name,
        e.entry_date, e.qty, e.unit, um.uom_name AS unit_name, e.unit_price, e.total_amount,
        e.specification, e.remarks, e.status, e.po_basic_sno, p.po_df_no AS po_no,
        e.created_by, e.created_date, e.consolidated_by, e.consolidated_date
    FROM dbo.service_vendor_daily_entry e
    LEFT JOIN dbo.kyc_basic_info k    ON k.kyc_basic_info_sno = e.vendor_sno
    LEFT JOIN dbo.service_master sm   ON sm.service_sno = e.service_sno
    LEFT JOIN dbo.uom_master um       ON um.uom_sno = e.unit
    LEFT JOIN dbo.po_request_info p   ON p.po_basic_sno = e.po_basic_sno
    WHERE e.is_active = 'Y'
      AND (@vendor_sno IS NULL OR e.vendor_sno = @vendor_sno)
      AND (@service_sno IS NULL OR e.service_sno = @service_sno)
      AND (@com_sno IS NULL OR e.com_sno = @com_sno)
      AND (@div_sno IS NULL OR e.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR e.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR e.dept_sno = @dept_sno)
      AND (@date_from IS NULL OR e.entry_date >= @date_from)
      AND (@date_to IS NULL OR e.entry_date <= @date_to)
      AND (
            (@status IS NULL AND e.status <> 'CANCELLED')
            OR e.status = @status
          )
    ORDER BY e.entry_date DESC, e.entry_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_LockServiceVendorEntriesForConsolidation
-- @jsonInput: {entry_snos:[1,2,3], locked_by}
-- Atomically claims PENDING rows (PENDING -> PROCESSING) so two concurrent
-- consolidations can never both raise a PO from the same entry. Also
-- enforces every claimed row shares one vendor and one org scope, since a
-- single PO (po_request_info) can only carry one of each.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_LockServiceVendorEntriesForConsolidation', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_LockServiceVendorEntriesForConsolidation;
GO
CREATE PROCEDURE dbo.sp_nt_LockServiceVendorEntriesForConsolidation
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @entry_snos NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.entry_snos');
    DECLARE @locked_by  VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.locked_by');

    IF @entry_snos IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@entry_snos))
        THROW 54120, 'entry_snos must be a non-empty array.', 1;
    IF @locked_by IS NULL
        THROW 54121, 'locked_by is required.', 1;

    DECLARE @requestedCount INT = (SELECT COUNT(*) FROM OPENJSON(@entry_snos));

    DECLARE @locked TABLE (
        entry_sno INT, com_sno INT, div_sno INT, brn_sno INT, dept_sno INT,
        vendor_sno INT, service_sno INT, entry_date DATE, qty DECIMAL(18,4),
        unit INT, unit_price DECIMAL(18,4), total_amount DECIMAL(18,4),
        specification NVARCHAR(500), remarks NVARCHAR(500)
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE e
        SET status = 'PROCESSING'
        OUTPUT inserted.entry_sno, inserted.com_sno, inserted.div_sno, inserted.brn_sno, inserted.dept_sno,
               inserted.vendor_sno, inserted.service_sno, inserted.entry_date, inserted.qty,
               inserted.unit, inserted.unit_price, inserted.total_amount,
               inserted.specification, inserted.remarks
        INTO @locked
        FROM dbo.service_vendor_daily_entry e WITH (UPDLOCK, HOLDLOCK)
        WHERE e.entry_sno IN (SELECT TRY_CAST(value AS INT) FROM OPENJSON(@entry_snos))
          AND e.status = 'PENDING' AND e.is_active = 'Y';

        IF (SELECT COUNT(*) FROM @locked) <> @requestedCount
            THROW 54122, 'One or more selected entries are no longer available (already consolidated, cancelled, or claimed by another request). Reload and try again.', 1;

        IF (SELECT COUNT(DISTINCT vendor_sno) FROM @locked) > 1
            THROW 54123, 'All selected entries must belong to the same vendor.', 1;

        IF (SELECT COUNT(DISTINCT CAST(com_sno AS VARCHAR(20)) + '-' + CAST(div_sno AS VARCHAR(20)) + '-' + CAST(brn_sno AS VARCHAR(20)) + '-' + CAST(dept_sno AS VARCHAR(20))) FROM @locked) > 1
            THROW 54124, 'All selected entries must belong to the same company/division/branch/department.', 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT * FROM @locked ORDER BY entry_date, entry_sno;
END;
GO

-- ============================================================
-- sp_nt_FinalizeServiceVendorEntriesConsolidation
-- @jsonInput: {entry_snos:[...], po_basic_sno, consolidated_by}
-- Called after sp_nt_CreateServicePO succeeds for the locked entries.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_FinalizeServiceVendorEntriesConsolidation', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_FinalizeServiceVendorEntriesConsolidation;
GO
CREATE PROCEDURE dbo.sp_nt_FinalizeServiceVendorEntriesConsolidation
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @entry_snos    NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.entry_snos');
    DECLARE @po_basic_sno  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT);
    DECLARE @consolidated_by VARCHAR(20) = JSON_VALUE(@jsonInput, '$.consolidated_by');

    IF @entry_snos IS NULL OR @po_basic_sno IS NULL OR @consolidated_by IS NULL
        THROW 54130, 'entry_snos, po_basic_sno and consolidated_by are required.', 1;

    UPDATE dbo.service_vendor_daily_entry
    SET status = 'CONSOLIDATED', po_basic_sno = @po_basic_sno,
        consolidated_by = @consolidated_by, consolidated_date = GETDATE()
    WHERE entry_sno IN (SELECT TRY_CAST(value AS INT) FROM OPENJSON(@entry_snos))
      AND status = 'PROCESSING';

    SELECT @@ROWCOUNT AS updated_count;
END;
GO

-- ============================================================
-- sp_nt_ReleaseServiceVendorEntriesLock
-- @jsonInput: {entry_snos:[...]}
-- Rolls PROCESSING rows back to PENDING — used when the downstream
-- sp_nt_CreateServicePO call fails after entries were already locked.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ReleaseServiceVendorEntriesLock', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_ReleaseServiceVendorEntriesLock;
GO
CREATE PROCEDURE dbo.sp_nt_ReleaseServiceVendorEntriesLock
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @entry_snos NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.entry_snos');
    IF @entry_snos IS NULL
        THROW 54140, 'entry_snos is required.', 1;

    UPDATE dbo.service_vendor_daily_entry
    SET status = 'PENDING'
    WHERE entry_sno IN (SELECT TRY_CAST(value AS INT) FROM OPENJSON(@entry_snos))
      AND status = 'PROCESSING';

    SELECT @@ROWCOUNT AS updated_count;
END;
GO

-- ============================================================
-- sp_nt_CancelServiceVendorDailyEntry — correct a mistaken entry before it's
-- consolidated. @jsonInput: {entry_sno, cancelled_by}
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CancelServiceVendorDailyEntry', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CancelServiceVendorDailyEntry;
GO
CREATE PROCEDURE dbo.sp_nt_CancelServiceVendorDailyEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @entry_sno   INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.entry_sno') AS INT);
    DECLARE @cancelled_by VARCHAR(20) = JSON_VALUE(@jsonInput, '$.cancelled_by');

    IF @entry_sno IS NULL OR @cancelled_by IS NULL
        THROW 54150, 'entry_sno and cancelled_by are required.', 1;

    UPDATE dbo.service_vendor_daily_entry
    SET status = 'CANCELLED'
    WHERE entry_sno = @entry_sno AND status = 'PENDING';

    IF @@ROWCOUNT = 0
        THROW 54151, 'Entry not found or is no longer PENDING (already consolidated or cancelled).', 1;

    SELECT 'SUCCESS' AS result, @entry_sno AS entry_sno;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM sys.tables WHERE name = 'service_vendor_daily_entry';
--   SELECT name FROM sys.procedures WHERE name LIKE 'sp_nt_%ServiceVendor%';
--   EXEC dbo.sp_nt_CreateServiceVendorDailyEntry @jsonInput = N'{"com_sno":1,
--     "div_sno":1,"brn_sno":1,"dept_sno":1,"vendor_sno":1,"service_sno":<a
--     VENDOR_BILL service_sno>,"entry_date":"2026-09-01","qty":10,"unit":1,
--     "unit_price":50,"created_by":"system"}';
--   EXEC dbo.sp_nt_GetServiceVendorDailyEntries @jsonInput = N'{"status":"PENDING"}';
-- ============================================================
