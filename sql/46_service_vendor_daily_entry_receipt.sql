-- ============================================================
-- service_vendor_daily_entry: today's receipt/bill upload for verification
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/ServiceVendorEntry module
--
-- Why this is needed
-- ------------------
-- service_vendor_daily_entry (41_service_vendor_daily_entry.sql) has zero
-- upload capability today — confirmed via full read, no doc_url/attachment
-- column anywhere and no multer wiring in ServiceVendorEntry.controller.js.
-- The user asked to attach today's receipt/bill when logging a Vendor Driven
-- daily entry, for verification. Purely additive: one nullable column, a v2
-- create proc that accepts it, a v2 get proc that returns it.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_vendor_daily_entry') AND name = 'receipt_doc_url')
    ALTER TABLE dbo.service_vendor_daily_entry ADD receipt_doc_url NVARCHAR(500) NULL;
GO

-- ============================================================
-- sp_nt_CreateServiceVendorDailyEntry v2 — adds required receipt_doc_url.
-- Everything else unchanged from v1 (41_service_vendor_daily_entry.sql),
-- same error codes for the unchanged checks.
-- @jsonInput adds: receipt_doc_url
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
    DECLARE @receipt_doc_url NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.receipt_doc_url');
    DECLARE @created_by     VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
       OR @vendor_sno IS NULL OR @service_sno IS NULL OR @entry_date IS NULL OR @created_by IS NULL
        THROW 54100, 'com_sno, div_sno, brn_sno, dept_sno, vendor_sno, service_sno, entry_date and created_by are required.', 1;

    IF @qty IS NULL OR @qty <= 0
        THROW 54102, 'qty must be greater than 0.', 1;

    IF @unit_price IS NULL OR @unit_price < 0
        THROW 54103, 'unit_price is required and cannot be negative.', 1;

    IF @receipt_doc_url IS NULL OR LTRIM(RTRIM(@receipt_doc_url)) = ''
        THROW 54104, 'receipt_doc_url is required — upload today''s receipt/bill before submitting.', 1;

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
        specification, remarks, receipt_doc_url, status, created_by, created_date, is_active
    )
    VALUES (
        @com_sno, @div_sno, @brn_sno, @dept_sno, @vendor_sno, @service_sno,
        @entry_date, @qty, @unit, @unit_price, @total_amount,
        @specification, @remarks, @receipt_doc_url, 'PENDING', @created_by, GETDATE(), 'Y'
    );

    DECLARE @entry_sno INT = SCOPE_IDENTITY();

    SELECT
        e.entry_sno, e.com_sno, e.div_sno, e.brn_sno, e.dept_sno,
        e.vendor_sno, k.company_name AS vendor_name,
        e.service_sno, sm.service_name,
        e.entry_date, e.qty, e.unit, um.uom_name AS unit_name, e.unit_price, e.total_amount,
        e.specification, e.remarks, e.receipt_doc_url, e.status, e.created_by, e.created_date
    FROM dbo.service_vendor_daily_entry e
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = e.vendor_sno
    LEFT JOIN dbo.service_master sm ON sm.service_sno = e.service_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = e.unit
    WHERE e.entry_sno = @entry_sno;
END;
GO

-- ============================================================
-- sp_nt_GetServiceVendorDailyEntries v2 — adds receipt_doc_url to the SELECT
-- list. Filter logic unchanged from v1 (41_service_vendor_daily_entry.sql).
-- @jsonInput optional filters: {vendor_sno, service_sno, com_sno, div_sno,
--   brn_sno, dept_sno, status, date_from, date_to}
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
        e.specification, e.remarks, e.receipt_doc_url, e.status, e.po_basic_sno, p.po_df_no AS po_no,
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
-- After running, confirm:
--   SELECT * FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_vendor_daily_entry') AND name = 'receipt_doc_url';
--   SELECT name FROM sys.procedures WHERE name IN ('sp_nt_CreateServiceVendorDailyEntry','sp_nt_GetServiceVendorDailyEntries');
-- ============================================================
