-- ============================================================
-- Service Vendor KYC — GST auto-fetch fields, bank details, Payment Mode
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/ServiceVendorKyc, nt-frontend-stpl
--            ServiceVendorKycPage.tsx / FieldDatas/ServiceVendorKycData.tsx
--
-- Why this is needed
-- ------------------
-- The main/goods vendor KYC (kyc_basic_info via KycEntry.tsx) already has:
-- (1) GST auto-fetch — enter a GSTIN, apiGetGSTNDetails (an internal SOAP
--     service, no external credentials) returns legal_name/trade_name/
--     status/etc., which the form then lets the user apply; (2) a full bank
--     account section (ac_holder_name/ac_number/ac_type/ifsc/bank_name/
--     bank_branch_name/bank_address). service_vendor_kyc (this repo's
--     separate onboarding flow for SERVICE vendors, sql/43_service_vendor_kyc.sql)
--     has neither. This adds both, plus a new "Payment Mode" concept
--     (Bank Transfer / Cash / UPI-App) that didn't exist anywhere before —
--     the vendor's preferred payment method captured at onboarding, distinct
--     from grn-service's payment_info.mode (which records how one specific
--     payment transaction was actually executed: NEFT/RTGS/Cheque/Cash/
--     UPI/DD). Named preferred_payment_mode, not payment_mode/mode, to avoid
--     confusion with that unrelated column.
--
-- Scope cut: unlike goods KYC, this stores a SINGLE primary bank account as
-- flat columns on service_vendor_kyc itself (no array/child table) — service
-- vendors are simpler entities and multi-account wasn't asked for. Also:
-- sp_approve_service_vendor_kyc's provisioning INSERT into kyc_basic_info
-- is deliberately left untouched — kyc_basic_info has no bank columns in
-- this repo either (the goods-KYC bank data lives behind an uncommitted
-- legacy SP, sp_InsertKYCData, of unknown shape), so these new fields stay
-- on service_vendor_kyc only rather than guessing at that schema.
-- ============================================================

-- ── service_vendor_kyc: GST-fetch-derived fields ────────────────────────────
IF COL_LENGTH('dbo.service_vendor_kyc', 'legal_name') IS NULL
    ALTER TABLE dbo.service_vendor_kyc ADD legal_name NVARCHAR(200) NULL;
GO
IF COL_LENGTH('dbo.service_vendor_kyc', 'trade_name') IS NULL
    ALTER TABLE dbo.service_vendor_kyc ADD trade_name NVARCHAR(200) NULL;
GO
IF COL_LENGTH('dbo.service_vendor_kyc', 'gst_status') IS NULL
    ALTER TABLE dbo.service_vendor_kyc ADD gst_status VARCHAR(50) NULL;
GO
IF COL_LENGTH('dbo.service_vendor_kyc', 'gst_blk_status') IS NULL
    ALTER TABLE dbo.service_vendor_kyc ADD gst_blk_status VARCHAR(50) NULL;
GO
IF COL_LENGTH('dbo.service_vendor_kyc', 'date_of_reg') IS NULL
    ALTER TABLE dbo.service_vendor_kyc ADD date_of_reg VARCHAR(20) NULL;
GO

-- ── service_vendor_kyc: bank details (single primary account) ──────────────
IF COL_LENGTH('dbo.service_vendor_kyc', 'ac_holder_name') IS NULL
    ALTER TABLE dbo.service_vendor_kyc ADD ac_holder_name NVARCHAR(100) NULL;
GO
IF COL_LENGTH('dbo.service_vendor_kyc', 'ac_number') IS NULL
    ALTER TABLE dbo.service_vendor_kyc ADD ac_number VARCHAR(30) NULL;
GO
IF COL_LENGTH('dbo.service_vendor_kyc', 'ac_type') IS NULL
    ALTER TABLE dbo.service_vendor_kyc ADD ac_type VARCHAR(50) NULL;
GO
IF COL_LENGTH('dbo.service_vendor_kyc', 'ifsc') IS NULL
    ALTER TABLE dbo.service_vendor_kyc ADD ifsc VARCHAR(15) NULL;
GO
IF COL_LENGTH('dbo.service_vendor_kyc', 'bank_name') IS NULL
    ALTER TABLE dbo.service_vendor_kyc ADD bank_name NVARCHAR(100) NULL;
GO
IF COL_LENGTH('dbo.service_vendor_kyc', 'bank_branch_name') IS NULL
    ALTER TABLE dbo.service_vendor_kyc ADD bank_branch_name NVARCHAR(100) NULL;
GO
IF COL_LENGTH('dbo.service_vendor_kyc', 'bank_address') IS NULL
    ALTER TABLE dbo.service_vendor_kyc ADD bank_address NVARCHAR(500) NULL;
GO

-- ── service_vendor_kyc: Payment Mode ────────────────────────────────────────
IF COL_LENGTH('dbo.service_vendor_kyc', 'preferred_payment_mode') IS NULL
    ALTER TABLE dbo.service_vendor_kyc ADD preferred_payment_mode VARCHAR(30) NULL;
GO

-- ============================================================
-- payment_mode_master — new, minimal Get+Create master (same shape as
-- bank_account_type_master, sql/15_bank_account_type_master.sql)
-- ============================================================
IF OBJECT_ID('dbo.payment_mode_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.payment_mode_master (
        payment_mode_sno   INT IDENTITY(1,1) PRIMARY KEY,
        payment_mode_code  VARCHAR(20)  NOT NULL UNIQUE,
        payment_mode_name  VARCHAR(50)  NOT NULL,
        is_active           CHAR(1)      NOT NULL DEFAULT 'Y',
        created_date         DATE         NOT NULL DEFAULT GETDATE(),
        created_by            VARCHAR(20)  NULL,
        modified_date          DATE         NULL,
        modified_by             VARCHAR(20)  NULL
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.payment_mode_master WHERE payment_mode_code = 'BANK_TRANSFER')
    INSERT INTO dbo.payment_mode_master (payment_mode_code, payment_mode_name, is_active, created_by)
    VALUES ('BANK_TRANSFER', 'Bank Transfer', 'Y', 'system');
GO
IF NOT EXISTS (SELECT 1 FROM dbo.payment_mode_master WHERE payment_mode_code = 'CASH')
    INSERT INTO dbo.payment_mode_master (payment_mode_code, payment_mode_name, is_active, created_by)
    VALUES ('CASH', 'Cash', 'Y', 'system');
GO
IF NOT EXISTS (SELECT 1 FROM dbo.payment_mode_master WHERE payment_mode_code = 'UPI_APP')
    INSERT INTO dbo.payment_mode_master (payment_mode_code, payment_mode_name, is_active, created_by)
    VALUES ('UPI_APP', 'UPI / Payment App', 'Y', 'system');
GO

IF OBJECT_ID('dbo.sp_nt_GetPaymentModeRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPaymentModeRecords;
GO
CREATE PROCEDURE dbo.sp_nt_GetPaymentModeRecords
AS
BEGIN
    SET NOCOUNT ON;
    SELECT payment_mode_sno, payment_mode_code, payment_mode_name, is_active
    FROM dbo.payment_mode_master
    WHERE is_active = 'Y'
    ORDER BY payment_mode_sno;
END;
GO

IF OBJECT_ID('dbo.sp_nt_CreatePaymentModeRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreatePaymentModeRecords;
GO
CREATE PROCEDURE dbo.sp_nt_CreatePaymentModeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @payment_mode_code NVARCHAR(20) = JSON_VALUE(@jsonInput, '$.payment_mode_code'),
            @payment_mode_name NVARCHAR(50) = JSON_VALUE(@jsonInput, '$.payment_mode_name'),
            @created_by        VARCHAR(20)  = JSON_VALUE(@jsonInput, '$.created_by');

    IF @payment_mode_code IS NULL OR @payment_mode_name IS NULL
       OR LTRIM(RTRIM(@payment_mode_code)) = '' OR LTRIM(RTRIM(@payment_mode_name)) = ''
    BEGIN
        THROW 59001, N'payment_mode_code and payment_mode_name are required.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.payment_mode_master WHERE payment_mode_code = @payment_mode_code)
    BEGIN
        THROW 59002, N'A payment mode with this code already exists.', 1;
        RETURN;
    END;

    INSERT INTO dbo.payment_mode_master (payment_mode_code, payment_mode_name, is_active, created_by)
    VALUES (UPPER(@payment_mode_code), @payment_mode_name, 'Y', @created_by);

    SELECT SCOPE_IDENTITY() AS payment_mode_sno, UPPER(@payment_mode_code) AS payment_mode_code,
           @payment_mode_name AS payment_mode_name, N'SUCCESS' AS status;
END;
GO

-- ============================================================
-- sp_nt_CreateServiceVendorKyc v2 — accepts + persists the new fields.
-- Everything else preserved byte-for-byte from the live v1 definition.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateServiceVendorKyc', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateServiceVendorKyc;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceVendorKyc
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
        DECLARE @company_name       NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.company_name');
        DECLARE @contact_person     NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.contact_person');
        DECLARE @email              NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.email');
        DECLARE @mobile_number      VARCHAR(15)   = JSON_VALUE(@jsonInput, '$.mobile_number');
        DECLARE @business_type      NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.business_type');
        DECLARE @is_gst_avail       CHAR(1)       = ISNULL(JSON_VALUE(@jsonInput, '$.is_gst_avail'), 'N');
        DECLARE @gst_no             VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.gst_no');
        DECLARE @is_msme_avail      CHAR(1)       = ISNULL(JSON_VALUE(@jsonInput, '$.is_msme_avail'), 'N');
        DECLARE @msme_no            VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.msme_no');
        DECLARE @pan_no             VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.pan_no');
        DECLARE @supplier_cat_code  VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.supplier_cat_code');
        DECLARE @document           NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.document');
        DECLARE @remarks            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @created_by         VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

        -- GST-fetch-derived (optional — only present when the caller applied
        -- an auto-fetched result before submitting)
        DECLARE @legal_name       NVARCHAR(200) = JSON_VALUE(@jsonInput, '$.legal_name');
        DECLARE @trade_name       NVARCHAR(200) = JSON_VALUE(@jsonInput, '$.trade_name');
        DECLARE @gst_status       VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.gst_status');
        DECLARE @gst_blk_status   VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.gst_blk_status');
        DECLARE @date_of_reg      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.date_of_reg');

        -- Bank details (required, mirrors goods-KYC's BANK_REQUIRED set)
        DECLARE @ac_holder_name   NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.ac_holder_name');
        DECLARE @ac_number        VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.ac_number');
        DECLARE @ac_type          VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.ac_type');
        DECLARE @ifsc             VARCHAR(15)   = JSON_VALUE(@jsonInput, '$.ifsc');
        DECLARE @bank_name        NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.bank_name');
        DECLARE @bank_branch_name NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.bank_branch_name');
        DECLARE @bank_address     NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.bank_address');

        DECLARE @preferred_payment_mode VARCHAR(30) = JSON_VALUE(@jsonInput, '$.preferred_payment_mode');

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @created_by IS NULL
            THROW 58001, 'com_sno, div_sno, brn_sno, dept_sno and created_by are required.', 1;

        IF @company_name IS NULL OR LTRIM(RTRIM(@company_name)) = ''
            THROW 58002, 'company_name is required.', 1;

        IF @contact_person IS NULL OR LTRIM(RTRIM(@contact_person)) = ''
            THROW 58003, 'contact_person is required.', 1;

        IF @mobile_number IS NULL OR LTRIM(RTRIM(@mobile_number)) = ''
            THROW 58004, 'mobile_number is required.', 1;

        IF @email IS NULL OR LTRIM(RTRIM(@email)) = ''
            THROW 58005, 'email is required.', 1;

        IF @business_type IS NULL OR LTRIM(RTRIM(@business_type)) = ''
            THROW 58006, 'business_type is required.', 1;

        IF @pan_no IS NULL OR LTRIM(RTRIM(@pan_no)) = ''
            THROW 58007, 'pan_no is required.', 1;

        IF @ac_holder_name IS NULL OR LTRIM(RTRIM(@ac_holder_name)) = ''
           OR @ac_number IS NULL OR LTRIM(RTRIM(@ac_number)) = ''
           OR @ac_type IS NULL OR LTRIM(RTRIM(@ac_type)) = ''
           OR @ifsc IS NULL OR LTRIM(RTRIM(@ifsc)) = ''
           OR @bank_name IS NULL OR LTRIM(RTRIM(@bank_name)) = ''
           OR @bank_branch_name IS NULL OR LTRIM(RTRIM(@bank_branch_name)) = ''
           OR @bank_address IS NULL OR LTRIM(RTRIM(@bank_address)) = ''
            THROW 58010, 'Bank account details (holder name, account number, account type, IFSC, bank name, branch, address) are required.', 1;

        -- ── Resolve the ServiceVendorKYC workflow for this org scope ───────
        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);

        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceVendorKYC';

        IF @workflow_types_id IS NULL
            THROW 58008, 'No ServiceVendorKYC workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key] = '0' AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 58009, 'No approver found for the first stage of the ServiceVendorKYC workflow.', 1;

        INSERT INTO dbo.service_vendor_kyc (
            com_sno, div_sno, brn_sno, dept_sno, company_name, contact_person, email, mobile_number,
            business_type, is_gst_avail, gst_no, is_msme_avail, msme_no, pan_no, supplier_cat_code,
            document, remarks, workflow_types_id, current_approver_id, status, is_active, created_by,
            legal_name, trade_name, gst_status, gst_blk_status, date_of_reg,
            ac_holder_name, ac_number, ac_type, ifsc, bank_name, bank_branch_name, bank_address,
            preferred_payment_mode
        )
        VALUES (
            @com_sno, @div_sno, @brn_sno, @dept_sno, @company_name, @contact_person, @email, @mobile_number,
            @business_type, @is_gst_avail, @gst_no, @is_msme_avail, @msme_no, @pan_no, @supplier_cat_code,
            @document, @remarks, @workflow_types_id, @first_approver, 'P', 'Y', @created_by,
            @legal_name, @trade_name, @gst_status, @gst_blk_status, @date_of_reg,
            @ac_holder_name, @ac_number, @ac_type, @ifsc, @bank_name, @bank_branch_name, @bank_address,
            @preferred_payment_mode
        );

        DECLARE @service_vendor_kyc_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.service_vendor_kyc_history (service_vendor_kyc_sno, action_type, status_by, comment, is_active)
        VALUES (@service_vendor_kyc_sno, 'SUBMITTED', @created_by, NULL, 'Y');

        COMMIT TRANSACTION;

        SELECT
            @service_vendor_kyc_sno AS service_vendor_kyc_sno,
            'SUCCESS'                AS result,
            N'Service vendor KYC submitted for approval.' AS message;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='service_vendor_kyc';
--   SELECT * FROM dbo.payment_mode_master;
--   SELECT name FROM sys.procedures WHERE name IN (
--     'sp_nt_GetPaymentModeRecords','sp_nt_CreatePaymentModeRecords','sp_nt_CreateServiceVendorKyc');
-- ============================================================
