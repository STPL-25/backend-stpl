-- ============================================================
-- Service Vendor KYC — a separate KYC intake + approval workflow for
-- service vendors (electricians, AMC contractors, transporters, lenders
-- on a Statutory/loan Service Agreement, etc.), kept apart from the
-- existing goods/trade KYC (Kyc module, table kyc_basic_info).
-- Database : Non_trade_Dev (MSSQL, 10.0.21.8) — apply to Non_Trade
-- (production) as a separate, deliberate follow-up sync once verified.
-- Used by  : new backend-stpl/src/ServiceVendorKyc module
--
-- Why this is needed / history
-- -----------------------------
-- A module with this exact name and shape existed before (sql/43, 44, 48,
-- 52) and was deleted on 2026-09-11 (sql/71_remove_service_feature.sql)
-- along with the entire old Service Agreement feature "for a new flow
-- design". Service Agreement/PO was rebuilt afterward (sql/73 -> 90) but
-- deliberately left Service Vendor KYC out of scope. The user now wants
-- the separation back, plus Service Agreement's vendor picker restricted
-- to only vendors who came through it. This file re-creates the module,
-- combining the old sql/43 (base table+procs) and sql/52 (bank/GST/
-- payment-mode columns) into one shot, and adds the picker-restriction
-- plumbing that didn't exist before (Service Agreement now supports a
-- multi-supplier split, sql/88, not a single vendor_sno).
--
-- Key design constraint (same as the original design): service_agreement.
-- vendor_sno / service_agreement_vendor.vendor_sno carry real application-
-- level references to kyc_basic_info_sno (validated in
-- sp_nt_SaveServiceAgreementSuppliers), and downstream code reads vendor
-- contact info straight out of kyc_basic_info by that same id. Re-pointing
-- those at a new table would mean touching already-working code. So: this
-- module owns intake and approval end-to-end on its OWN table, but on
-- final approval it auto-provisions a matching kyc_basic_info row and
-- stores that row's id back here (kyc_basic_info_sno) — every existing
-- vendor_sno consumer keeps working unchanged. "Separate KYC" is real
-- (separate table, form, approvers, fields); it just interoperates with
-- existing vendor plumbing behind the scenes instead of forking it.
--
-- How the picker restriction works: a new nullable kyc_basic_info.
-- vendor_category column is NULL for every existing/product vendor and
-- gets set to 'SERVICE' only by this module's provisioning insert. Both
-- the new sp_nt_GetApprovedServiceKycVendorsForPicker (frontend dropdown)
-- and the amended sp_nt_SaveServiceAgreementSuppliers (the actual SQL-side
-- chokepoint both sp_nt_CreateServiceAgreement/UpdateServiceAgreement call)
-- filter on it — a client can no longer bypass the dropdown and post an
-- arbitrary product-vendor's kyc_basic_info_sno into a Service Agreement.
-- sp_nt_GetApprovedVendorsForServicePicker (the pre-existing generic
-- "VendorMaster" picker, still shared by Payment/VendorBill/
-- VendorDrivenPR) is untouched — it must keep returning every approved
-- vendor regardless of category.
--
-- payment_mode_master / sp_nt_GetPaymentModeRecords / sp_nt_
-- CreatePaymentModeRecords already exist live (added 2026-09-03 for the
-- Bank Payment Voucher feature) — reused as-is, not recreated here.
-- ============================================================

-- ── 0. kyc_basic_info.vendor_category — additive, nullable, no backfill ──
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.kyc_basic_info') AND name = 'vendor_category'
)
    ALTER TABLE dbo.kyc_basic_info ADD vendor_category VARCHAR(20) NULL;
GO

-- ── 1. service_vendor_kyc ────────────────────────────────────────────────
IF OBJECT_ID('dbo.service_vendor_kyc', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_vendor_kyc (
        service_vendor_kyc_sno INT IDENTITY(1,1) PRIMARY KEY,
        -- generated only on final approval, format SVK-YYYY-NNNN
        service_vendor_code    VARCHAR(30)   NULL,
        com_sno                INT           NOT NULL,
        div_sno                INT           NOT NULL,
        brn_sno                INT           NOT NULL,
        dept_sno                INT          NOT NULL,
        company_name             NVARCHAR(50) NOT NULL,
        contact_person            NVARCHAR(50) NOT NULL,
        email                      NVARCHAR(50) NOT NULL,
        mobile_number                VARCHAR(15) NOT NULL,
        business_type                 NVARCHAR(50) NOT NULL,
        is_gst_avail                   CHAR(1)   NOT NULL DEFAULT 'N',
        gst_no                          VARCHAR(20) NULL,
        is_msme_avail                    CHAR(1) NOT NULL DEFAULT 'N',
        msme_no                            VARCHAR(20) NULL,
        pan_no                              VARCHAR(20) NOT NULL,
        supplier_cat_code                    VARCHAR(20) NULL,
        -- GST-fetch-derived (optional, populated by the GSTIN lookup on the form)
        legal_name                            VARCHAR(100) NULL,
        trade_name                             VARCHAR(100) NULL,
        gst_status                              VARCHAR(50) NULL,
        gst_blk_status                           VARCHAR(50) NULL,
        date_of_reg                               VARCHAR(20) NULL,
        -- single flat primary bank account (required — see sp_nt_CreateServiceVendorKyc)
        ac_holder_name                             NVARCHAR(100) NULL,
        ac_number                                   VARCHAR(30) NULL,
        ac_type                                      VARCHAR(50) NULL,
        ifsc                                          VARCHAR(15) NULL,
        bank_name                                     NVARCHAR(100) NULL,
        bank_branch_name                               NVARCHAR(100) NULL,
        bank_address                                    NVARCHAR(500) NULL,
        preferred_payment_mode                           VARCHAR(30) NULL,
        -- JSON array of {documentType,url,filename,mimetype,size}, same shape
        -- Kyc.controller.js#createKYCRecord already builds for kyc_basic_info
        document                              NVARCHAR(MAX) NULL,
        remarks                                NVARCHAR(500) NULL,
        workflow_types_id                       INT NULL,
        current_approver_id                      VARCHAR(30) NULL,
        -- P=Pending, A=Approved, R=Rejected, X=Expired/Deactivated. 'D' reserved,
        -- never inserted by the create proc.
        status                                    CHAR(1) NOT NULL,
        -- set only at final approval, once the mirrored kyc_basic_info row exists
        kyc_basic_info_sno                         INT NULL,
        is_active                                   CHAR(1) NOT NULL DEFAULT 'Y',
        created_by                                   VARCHAR(20) NULL,
        created_at                                    DATETIME NOT NULL DEFAULT GETDATE(),
        modified_by                                    VARCHAR(20) NULL,
        modified_at                                     DATETIME NULL,
        CONSTRAINT UQ_service_vendor_kyc_code UNIQUE (service_vendor_code),
        CONSTRAINT CK_service_vendor_kyc_status CHECK (status IN ('D','P','A','R','X')),
        CONSTRAINT FK_service_vendor_kyc_kyc_basic_info FOREIGN KEY (kyc_basic_info_sno)
            REFERENCES dbo.kyc_basic_info (kyc_basic_info_sno)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_service_vendor_kyc_scope' AND object_id = OBJECT_ID('dbo.service_vendor_kyc'))
    CREATE INDEX IX_service_vendor_kyc_scope
        ON dbo.service_vendor_kyc (com_sno, div_sno, brn_sno, dept_sno, status);
GO

-- ── service_vendor_kyc_history — approve/reject audit trail ────────────────
IF OBJECT_ID('dbo.service_vendor_kyc_history', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_vendor_kyc_history (
        history_sno             INT IDENTITY(1,1) PRIMARY KEY,
        service_vendor_kyc_sno  INT           NOT NULL,
        action_type              VARCHAR(20)  NOT NULL, -- SUBMITTED | APPROVED | REJECTED
        status_by                VARCHAR(30)  NULL,
        comment                   VARCHAR(200) NULL,
        is_active                 CHAR(1)      NOT NULL DEFAULT 'Y',
        created_date               DATETIME    NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_service_vendor_kyc_history_kyc FOREIGN KEY (service_vendor_kyc_sno)
            REFERENCES dbo.service_vendor_kyc (service_vendor_kyc_sno)
    );
END;
GO

-- ── entity_master: register ServiceVendorKYC as a workflow entity_type ─────
IF NOT EXISTS (SELECT 1 FROM dbo.entity_master WHERE entity_code = 'ServiceVendorKYC')
    INSERT INTO dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by)
    VALUES (N'Service Vendor KYC', N'ServiceVendorKYC', N'KYC onboarding + approval for service vendors, separate from goods/trade vendor KYC', 'Y', N'system');
GO

-- ============================================================
-- sp_nt_CreateServiceVendorKyc
-- @jsonInput: { com_sno, div_sno, brn_sno, dept_sno, company_name,
--   contact_person, email, mobile_number, business_type, is_gst_avail,
--   gst_no?, is_msme_avail, msme_no?, pan_no, supplier_cat_code?,
--   legal_name?, trade_name?, gst_status?, gst_blk_status?, date_of_reg?,
--   ac_holder_name, ac_number, ac_type, ifsc, bank_name, bank_branch_name,
--   bank_address, preferred_payment_mode?, document?, remarks, created_by }
-- Always resolves and requires a workflow, same as every other entity in
-- this app (this app throws on missing workflow config rather than
-- silently proceeding — see sp_nt_CreateServiceAgreement for precedent).
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
        DECLARE @legal_name         VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.legal_name');
        DECLARE @trade_name         VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.trade_name');
        DECLARE @gst_status         VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.gst_status');
        DECLARE @gst_blk_status     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.gst_blk_status');
        DECLARE @date_of_reg        VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.date_of_reg');
        DECLARE @ac_holder_name     NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.ac_holder_name');
        DECLARE @ac_number          VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.ac_number');
        DECLARE @ac_type            VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.ac_type');
        DECLARE @ifsc               VARCHAR(15)   = JSON_VALUE(@jsonInput, '$.ifsc');
        DECLARE @bank_name          NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.bank_name');
        DECLARE @bank_branch_name   NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.bank_branch_name');
        DECLARE @bank_address       NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.bank_address');
        DECLARE @preferred_payment_mode VARCHAR(30) = JSON_VALUE(@jsonInput, '$.preferred_payment_mode');
        DECLARE @document           NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.document');
        DECLARE @remarks            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @created_by         VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @created_by IS NULL
            THROW 58201, 'com_sno, div_sno, brn_sno, dept_sno and created_by are required.', 1;

        IF @company_name IS NULL OR LTRIM(RTRIM(@company_name)) = ''
            THROW 58202, 'company_name is required.', 1;

        IF @contact_person IS NULL OR LTRIM(RTRIM(@contact_person)) = ''
            THROW 58203, 'contact_person is required.', 1;

        IF @mobile_number IS NULL OR LTRIM(RTRIM(@mobile_number)) = ''
            THROW 58204, 'mobile_number is required.', 1;

        IF @email IS NULL OR LTRIM(RTRIM(@email)) = ''
            THROW 58205, 'email is required.', 1;

        IF @business_type IS NULL OR LTRIM(RTRIM(@business_type)) = ''
            THROW 58206, 'business_type is required.', 1;

        IF @pan_no IS NULL OR LTRIM(RTRIM(@pan_no)) = ''
            THROW 58207, 'pan_no is required.', 1;

        IF @ac_holder_name IS NULL OR LTRIM(RTRIM(@ac_holder_name)) = ''
           OR @ac_number IS NULL OR LTRIM(RTRIM(@ac_number)) = ''
           OR @ac_type IS NULL OR LTRIM(RTRIM(@ac_type)) = ''
           OR @ifsc IS NULL OR LTRIM(RTRIM(@ifsc)) = ''
           OR @bank_name IS NULL OR LTRIM(RTRIM(@bank_name)) = ''
           OR @bank_branch_name IS NULL OR LTRIM(RTRIM(@bank_branch_name)) = ''
           OR @bank_address IS NULL OR LTRIM(RTRIM(@bank_address)) = ''
            THROW 58210, 'Bank account details (holder name, account number, account type, IFSC, bank name, branch name, address) are required.', 1;

        -- ── Resolve the ServiceVendorKYC workflow for this org scope ───────
        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);

        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceVendorKYC';

        IF @workflow_types_id IS NULL
            THROW 58208, 'No ServiceVendorKYC workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key] = '0' AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 58209, 'No approver found for the first stage of the ServiceVendorKYC workflow.', 1;

        INSERT INTO dbo.service_vendor_kyc (
            com_sno, div_sno, brn_sno, dept_sno, company_name, contact_person, email, mobile_number,
            business_type, is_gst_avail, gst_no, is_msme_avail, msme_no, pan_no, supplier_cat_code,
            legal_name, trade_name, gst_status, gst_blk_status, date_of_reg,
            ac_holder_name, ac_number, ac_type, ifsc, bank_name, bank_branch_name, bank_address,
            preferred_payment_mode, document, remarks, workflow_types_id, current_approver_id,
            status, is_active, created_by
        )
        VALUES (
            @com_sno, @div_sno, @brn_sno, @dept_sno, @company_name, @contact_person, @email, @mobile_number,
            @business_type, @is_gst_avail, @gst_no, @is_msme_avail, @msme_no, @pan_no, @supplier_cat_code,
            @legal_name, @trade_name, @gst_status, @gst_blk_status, @date_of_reg,
            @ac_holder_name, @ac_number, @ac_type, @ifsc, @bank_name, @bank_branch_name, @bank_address,
            @preferred_payment_mode, @document, @remarks, @workflow_types_id, @first_approver,
            'P', 'Y', @created_by
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
-- sp_approve_service_vendor_kyc
-- @jsonInput: { service_vendor_kyc_sno, approved_by, comments, approval_stages, action:'approve'|'reject' }
-- Same single-stage-progression shape as sp_approve_service_agreement.
-- On the FINAL stage of an approval, auto-provisions a kyc_basic_info row
-- (vendor_category='SERVICE') and writes its id back onto this table.
-- ============================================================
IF OBJECT_ID('dbo.sp_approve_service_vendor_kyc', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_approve_service_vendor_kyc;
GO
CREATE PROCEDURE dbo.sp_approve_service_vendor_kyc
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @service_vendor_kyc_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_vendor_kyc_sno') AS INT);
        DECLARE @approved_by            VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by');
        DECLARE @comments               VARCHAR(1000) = JSON_VALUE(@jsonInput, '$.comments');
        DECLARE @approval_stages        NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages');
        DECLARE @action                 VARCHAR(20)   = LOWER(JSON_VALUE(@jsonInput, '$.action'));

        IF @service_vendor_kyc_sno IS NULL
            THROW 58220, 'service_vendor_kyc_sno is required.', 1;
        IF @approved_by IS NULL OR LTRIM(RTRIM(@approved_by)) = ''
            THROW 58221, 'approved_by is required.', 1;
        IF @action NOT IN ('approve', 'reject')
            THROW 58222, 'action must be approve or reject.', 1;
        IF @action = 'reject' AND (@comments IS NULL OR LTRIM(RTRIM(@comments)) = '')
            THROW 58223, 'comments are required when rejecting.', 1;
        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
            THROW 58224, 'Invalid or missing approval_stages.', 1;

        DECLARE @current_status CHAR(1), @current_approver VARCHAR(30);
        SELECT @current_status = status, @current_approver = current_approver_id
        FROM dbo.service_vendor_kyc WHERE service_vendor_kyc_sno = @service_vendor_kyc_sno AND is_active = 'Y';

        IF @current_status IS NULL
            THROW 58225, 'Service vendor KYC record not found.', 1;
        IF @current_status <> 'P'
            THROW 58226, 'This record is not pending approval.', 1;
        IF @current_approver <> @approved_by
            THROW 58227, 'You are not the current approver for this record.', 1;

        CREATE TABLE #approval_stages (
            seq_no             INT,
            approver_ecno      VARCHAR(30),
            stage              VARCHAR(100),
            can_forward        CHAR(1),
            can_backward       CHAR(1)
        );
        INSERT INTO #approval_stages (seq_no, approver_ecno, stage, can_forward, can_backward)
        SELECT
            CAST(oj.[key] AS INT),
            JSON_VALUE(oj.[value], '$.approver_ecno'),
            JSON_VALUE(oj.[value], '$.stage'),
            JSON_VALUE(oj.[value], '$.can_forward'),
            JSON_VALUE(oj.[value], '$.can_backward')
        FROM OPENJSON(@approval_stages) AS oj;

        BEGIN TRANSACTION;

        IF @action = 'reject'
        BEGIN
            UPDATE dbo.service_vendor_kyc
            SET status = 'R', current_approver_id = NULL, modified_by = @approved_by, modified_at = GETDATE()
            WHERE service_vendor_kyc_sno = @service_vendor_kyc_sno;

            INSERT INTO dbo.service_vendor_kyc_history (service_vendor_kyc_sno, action_type, status_by, comment, is_active)
            VALUES (@service_vendor_kyc_sno, 'REJECTED', @approved_by, @comments, 'Y');

            COMMIT TRANSACTION;
            DROP TABLE #approval_stages;

            SELECT 'REJECTED' AS result, @service_vendor_kyc_sno AS service_vendor_kyc_sno;
            RETURN;
        END

        -- APPROVE: resolve next stage
        DECLARE @next_current_approver VARCHAR(30);
        ;WITH stage_cte AS (
            SELECT seq_no, approver_ecno, LEAD(approver_ecno) OVER (ORDER BY seq_no) AS next_ecno
            FROM #approval_stages
        )
        SELECT @next_current_approver = next_ecno FROM stage_cte WHERE approver_ecno = @approved_by;

        INSERT INTO dbo.service_vendor_kyc_history (service_vendor_kyc_sno, action_type, status_by, comment, is_active)
        VALUES (@service_vendor_kyc_sno, 'APPROVED', @approved_by, @comments, 'Y');

        IF @next_current_approver IS NOT NULL
        BEGIN
            UPDATE dbo.service_vendor_kyc
            SET current_approver_id = @next_current_approver, modified_by = @approved_by, modified_at = GETDATE()
            WHERE service_vendor_kyc_sno = @service_vendor_kyc_sno;

            COMMIT TRANSACTION;
            DROP TABLE #approval_stages;

            SELECT 'APPROVED' AS result, 'N' AS is_final, @service_vendor_kyc_sno AS service_vendor_kyc_sno,
                   @next_current_approver AS next_approver;
            RETURN;
        END

        -- FINAL STAGE: generate service_vendor_code, provision kyc_basic_info
        DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT,
                @company_name NVARCHAR(50), @contact_person NVARCHAR(50), @email NVARCHAR(50),
                @mobile_number VARCHAR(15), @business_type NVARCHAR(50), @is_gst_avail CHAR(1),
                @gst_no VARCHAR(20), @is_msme_avail CHAR(1), @msme_no VARCHAR(20), @pan_no VARCHAR(20),
                @supplier_cat_code VARCHAR(20), @created_by VARCHAR(20);

        SELECT
            @com_sno = com_sno, @div_sno = div_sno, @brn_sno = brn_sno, @dept_sno = dept_sno,
            @company_name = company_name, @contact_person = contact_person, @email = email,
            @mobile_number = mobile_number, @business_type = business_type, @is_gst_avail = is_gst_avail,
            @gst_no = gst_no, @is_msme_avail = is_msme_avail, @msme_no = msme_no, @pan_no = pan_no,
            @supplier_cat_code = supplier_cat_code, @created_by = created_by
        FROM dbo.service_vendor_kyc WHERE service_vendor_kyc_sno = @service_vendor_kyc_sno;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(service_vendor_code, 4) AS INT)), 0) + 1
        FROM dbo.service_vendor_kyc WITH (UPDLOCK, HOLDLOCK)
        WHERE service_vendor_code LIKE 'SVK-' + @year + '-%';

        DECLARE @service_vendor_code VARCHAR(30) = 'SVK-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.kyc_basic_info (
            com_sno, div_sno, brn_sno, dept_sno, company_name, contact_person, email, mobile_number,
            business_type, is_gst_avail, gst_no, is_msme_avail, msme_no, pan_no, supplier_cat_code,
            approver_ecno, workflow_types_id, status, supp_code, vendor_category, is_active, created_by, created_date
        )
        VALUES (
            @com_sno, @div_sno, @brn_sno, @dept_sno, @company_name, @contact_person, @email, @mobile_number,
            @business_type, @is_gst_avail, @gst_no, @is_msme_avail, @msme_no, @pan_no, @supplier_cat_code,
            @approved_by, NULL, 'A', @service_vendor_code, 'SERVICE', 'Y', @created_by, GETDATE()
        );

        DECLARE @new_kyc_basic_info_sno INT = SCOPE_IDENTITY();

        UPDATE dbo.service_vendor_kyc
        SET status = 'A', service_vendor_code = @service_vendor_code,
            kyc_basic_info_sno = @new_kyc_basic_info_sno,
            current_approver_id = NULL, modified_by = @approved_by, modified_at = GETDATE()
        WHERE service_vendor_kyc_sno = @service_vendor_kyc_sno;

        COMMIT TRANSACTION;
        DROP TABLE #approval_stages;

        SELECT 'FINAL_APPROVED' AS result, 'Y' AS is_final, @service_vendor_kyc_sno AS service_vendor_kyc_sno,
               @service_vendor_code AS service_vendor_code, @new_kyc_basic_info_sno AS kyc_basic_info_sno;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL DROP TABLE #approval_stages;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- sp_nt_GetServiceVendorKycs — list/filter, for admin/browse screens
-- @jsonInput optional: { com_sno?, div_sno?, brn_sno?, dept_sno?, status? }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServiceVendorKycs', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetServiceVendorKycs;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceVendorKycs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL, @status VARCHAR(1) = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @com_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        SET @status   = JSON_VALUE(@jsonInput, '$.status');
    END

    SELECT
        svk.service_vendor_kyc_sno, svk.service_vendor_code,
        svk.com_sno, svk.div_sno, svk.brn_sno, svk.dept_sno,
        svk.company_name, svk.contact_person, svk.email, svk.mobile_number, svk.business_type,
        svk.is_gst_avail, svk.gst_no, svk.is_msme_avail, svk.msme_no, svk.pan_no, svk.supplier_cat_code,
        svk.legal_name, svk.trade_name, svk.gst_status, svk.gst_blk_status, svk.date_of_reg,
        svk.ac_holder_name, svk.ac_number, svk.ac_type, svk.ifsc, svk.bank_name, svk.bank_branch_name,
        svk.bank_address, svk.preferred_payment_mode,
        svk.document, svk.remarks, svk.workflow_types_id, svk.current_approver_id, svk.status,
        svk.kyc_basic_info_sno, svk.created_by, svk.created_at
    FROM dbo.service_vendor_kyc svk
    WHERE svk.is_active = 'Y'
      AND (@com_sno IS NULL OR svk.com_sno = @com_sno)
      AND (@div_sno IS NULL OR svk.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR svk.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR svk.dept_sno = @dept_sno)
      AND (@status IS NULL OR svk.status = @status)
    ORDER BY svk.service_vendor_kyc_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetServiceVendorKycsForApproval — pending records for the logged-in
-- approver, with stage_order_json so the frontend can round-trip
-- approval_stages back into sp_approve_service_vendor_kyc.
-- @Ecno VARCHAR(50)
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServiceVendorKycsForApproval', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetServiceVendorKycsForApproval;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceVendorKycsForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        svk.service_vendor_kyc_sno, svk.service_vendor_code,
        svk.com_sno, svk.div_sno, svk.brn_sno, svk.dept_sno,
        svk.company_name, svk.contact_person, svk.email, svk.mobile_number, svk.business_type,
        svk.is_gst_avail, svk.gst_no, svk.is_msme_avail, svk.msme_no, svk.pan_no, svk.supplier_cat_code,
        svk.legal_name, svk.trade_name, svk.gst_status, svk.gst_blk_status, svk.date_of_reg,
        svk.ac_holder_name, svk.ac_number, svk.ac_type, svk.ifsc, svk.bank_name, svk.bank_branch_name,
        svk.bank_address, svk.preferred_payment_mode,
        svk.document, svk.remarks, svk.workflow_types_id, svk.current_approver_id, svk.status,
        (
            SELECT ws.stage_order_json
            FROM dbo.workflow_stage ws
            WHERE ws.workflow_types_id = svk.workflow_types_id AND ws.is_active = 'Y'
        ) AS stage_order_json
    FROM dbo.service_vendor_kyc svk
    WHERE svk.current_approver_id = @Ecno
      AND svk.status = 'P'
      AND svk.is_active = 'Y'
    ORDER BY svk.service_vendor_kyc_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetApprovedServiceVendorKycs — approved records only (KYC admin view)
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetApprovedServiceVendorKycs', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetApprovedServiceVendorKycs;
GO
CREATE PROCEDURE dbo.sp_nt_GetApprovedServiceVendorKycs
AS
BEGIN
    SET NOCOUNT ON;

    SELECT service_vendor_kyc_sno, service_vendor_code, company_name, contact_person,
           email, mobile_number, kyc_basic_info_sno
    FROM dbo.service_vendor_kyc
    WHERE status = 'A' AND is_active = 'Y'
    ORDER BY company_name;
END;
GO

-- ============================================================
-- sp_nt_GetApprovedServiceKycVendorsForPicker — the Service Agreement /
-- Service PO vendor dropdown. Deliberately separate from the generic
-- sp_nt_GetApprovedVendorsForServicePicker (VendorMaster), which stays
-- unrestricted for its other live consumers (Payment, VendorBill,
-- Vendor-Driven PR).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetApprovedServiceKycVendorsForPicker', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetApprovedServiceKycVendorsForPicker;
GO
CREATE PROCEDURE dbo.sp_nt_GetApprovedServiceKycVendorsForPicker
AS
BEGIN
    SET NOCOUNT ON;

    SELECT kyc_basic_info_sno, company_name, supp_code, email, mobile_number
    FROM dbo.kyc_basic_info
    WHERE status = 'A' AND is_active = 'Y' AND vendor_category = 'SERVICE'
    ORDER BY company_name;
END;
GO

-- ============================================================
-- sp_nt_SaveServiceAgreementSuppliers v2 — re-supersedes the sql/88
-- version. Only change: the existing-vendor EXISTS check now also
-- requires vendor_category='SERVICE', so a Service Agreement (Fixed/
-- Unfixed split, or the Statutory single-lender fallback) can only be
-- saved against Service-KYC-approved vendors. Everything else byte-
-- identical to the live version.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_SaveServiceAgreementSuppliers', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_SaveServiceAgreementSuppliers;
GO
CREATE PROCEDURE dbo.sp_nt_SaveServiceAgreementSuppliers
    @agreement_sno INT,
    @vendors_json NVARCHAR(MAX),
    @fallback_vendor_sno INT,
    @total_amount DECIMAL(18,2),
    @out_primary_vendor_sno INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @parsed TABLE (ord INT NOT NULL, vendor_sno INT NULL, share_amount DECIMAL(18,2) NULL);

    IF @vendors_json IS NOT NULL AND ISJSON(@vendors_json) = 1 AND LEFT(LTRIM(@vendors_json), 1) = '['
        INSERT INTO @parsed (ord, vendor_sno, share_amount)
        SELECT CAST(j.[key] AS INT) + 1,
               TRY_CAST(JSON_VALUE(j.[value], '$.vendor_sno') AS INT),
               TRY_CAST(JSON_VALUE(j.[value], '$.share_amount') AS DECIMAL(18,2))
        FROM OPENJSON(@vendors_json) AS j;

    IF NOT EXISTS (SELECT 1 FROM @parsed) AND @fallback_vendor_sno IS NOT NULL
        INSERT INTO @parsed (ord, vendor_sno, share_amount) VALUES (1, @fallback_vendor_sno, @total_amount);

    IF NOT EXISTS (SELECT 1 FROM @parsed)
        THROW 58150, 'At least one supplier is required.', 1;
    IF EXISTS (SELECT 1 FROM @parsed WHERE vendor_sno IS NULL OR share_amount IS NULL OR share_amount <= 0)
        THROW 58151, 'Every supplier needs a vendor and a share amount greater than zero.', 1;
    IF EXISTS (SELECT vendor_sno FROM @parsed GROUP BY vendor_sno HAVING COUNT(*) > 1)
        THROW 58152, 'The same supplier is listed more than once in the split.', 1;
    IF EXISTS (
        SELECT 1 FROM @parsed p
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.kyc_basic_info k
            WHERE k.kyc_basic_info_sno = p.vendor_sno AND k.status = 'A' AND k.is_active = 'Y'
              AND k.vendor_category = 'SERVICE'
        )
    )
        THROW 58153, 'One or more suppliers are not approved Service Vendor KYC vendors.', 1;

    DECLARE @sum DECIMAL(18,2) = (SELECT SUM(share_amount) FROM @parsed);
    IF ABS(@sum - @total_amount) > 0.01
    BEGIN
        DECLARE @msg NVARCHAR(400) =
            N'Supplier shares total ' + CONVERT(NVARCHAR(30), @sum) +
            N' but the amount per cycle (rate x quantity) is ' + CONVERT(NVARCHAR(30), @total_amount) +
            N'. The shares must add up exactly.';
        THROW 58154, @msg, 1;
    END

    DELETE FROM dbo.service_agreement_vendor WHERE agreement_sno = @agreement_sno;

    INSERT INTO dbo.service_agreement_vendor (agreement_sno, vendor_sno, share_amount, share_pct, sort_order)
    SELECT @agreement_sno, vendor_sno, share_amount, ROUND(share_amount * 100.0 / @total_amount, 6), ord
    FROM @parsed
    ORDER BY ord;

    SELECT TOP 1 @out_primary_vendor_sno = vendor_sno FROM @parsed ORDER BY ord;
END;
GO

-- ── screens: Service Vendor KYC entry + approval, same "Service" group as
-- ServiceAgreement/ServicePO/LoanVoucher (group_id=9), next free screen_code
-- (S21) and display_order (31/32) confirmed live before this insert. ──────
IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceVendorKycPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active, staff_only)
    VALUES (N'Service Vendor KYC', 'S21', 'ServiceVendorKycPage', N'ShieldCheck', 9, 31, 'Y', 'N');
GO
IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceVendorKycApprovalScreen')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active, staff_only)
    VALUES (N'Service Vendor KYC Approvals', 'S21', 'ServiceVendorKycApprovalScreen', N'ShieldCheck', 9, 32, 'Y', 'N');
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_vendor_kyc') ORDER BY column_id;
--   SELECT name FROM sys.procedures WHERE name LIKE '%ServiceVendorKyc%' OR name = 'sp_nt_GetApprovedServiceKycVendorsForPicker';
--   SELECT * FROM dbo.entity_master WHERE entity_code = 'ServiceVendorKYC';
--   SELECT * FROM dbo.screens WHERE comp LIKE 'ServiceVendorKyc%';
--
-- NOT done in this file (live follow-up, same as every other Service/Loan
-- feature rollout in this repo):
--   - approval_workflow_master / workflow_types / workflow_stage rows for
--     entity_type='ServiceVendorKYC' (who approves, per org scope) —
--     sp_nt_CreateServiceVendorKyc THROWs 58208 until this is seeded.
--   - nt_screen_permissions grants (sp_nt_GrantScreenToUser) for whoever
--     needs the two new screens.
-- ============================================================
