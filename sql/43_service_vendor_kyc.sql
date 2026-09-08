-- ============================================================
-- service_vendor_kyc — a separate KYC intake + approval workflow for
-- service vendors (electricians, AMC contractors, milk/vendor-bill
-- suppliers etc.), kept apart from the existing goods/trade KYC (Kyc module,
-- table kyc_basic_info).
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : new backend-stpl/src/ServiceVendorKyc module
--
-- Why this is needed
-- ------------------
-- The user explicitly asked for service vendors to go through their own KYC,
-- separate from goods/trade vendor KYC — own form, own table, own approvers.
-- Confirmed via clarifying question ("Fully separate KYC module", not the
-- lighter "tag the existing KYC with a type" option).
--
-- Key design constraint (see 45_service_master_supplier_and_product.sql and
-- the session's own plan notes): service_agreement.vendor_sno and
-- service_vendor_daily_entry.vendor_sno both carry REAL SQL FOREIGN KEY
-- constraints to kyc_basic_info, and downstream code
-- (sp_nt_IssueRecurringServicePOCycle, ServicePO.repository.js#getVendorContact)
-- reads vendor contact info straight out of kyc_basic_info by that same
-- vendor_sno — live rows already depend on this (e.g. AGR-2026-0005 auto-
-- issuing real POs on a schedule). Re-pointing those FKs at this new table
-- would mean migrating/nulling live data and touching already-working
-- recurring-PO/email code. To avoid that risk: this module owns intake and
-- approval end-to-end on its OWN table, but on final approval (see
-- 44_service_vendor_kyc_approval_and_provisioning.sql) it auto-provisions a
-- matching kyc_basic_info row and stores that row's id back here
-- (kyc_basic_info_sno) — every existing vendor_sno consumer keeps working
-- completely unchanged. "Separate KYC" is real (separate table, form,
-- approvers, fields) — it just interoperates with existing vendor plumbing
-- behind the scenes instead of forking it.
--
-- kyc_basic_info's live column list (queried directly via
-- INFORMATION_SCHEMA.COLUMNS — it predates this repo's migration convention,
-- same as product_master, see reference-non-trade-codebase-conventions):
-- kyc_basic_info_sno, div_sno, approver_ecno, brn_sno, dept_sno, com_sno,
-- company_name, contact_person (NOT contact_name), email, mobile_number,
-- business_type, is_gst_avail, gst_no, is_msme_avail, msme_no, pan_no,
-- created_by, created_date, modified_by, modified_date, is_active, status,
-- supp_code, old_supp_code, reference_no, instance_id, workflow_types_id,
-- supplier_cat_code, legal_name, trade_name, txp_type, gst_status,
-- gst_blk_status, date_of_reg. This table's own columns below intentionally
-- mirror the subset that gets carried into the provisioning INSERT
-- (company_name/contact_person/email/mobile_number/business_type/
-- is_gst_avail/gst_no/is_msme_avail/msme_no/pan_no/supplier_cat_code), sized
-- identically so the copy never truncates.
--
-- Shape otherwise follows service_agreement (10_service_agreement.sql)
-- almost exactly — same workflow-resolution block against
-- workflow_types/approval_workflow_master/vw_workflow_stages, same
-- single-stage-progression approve/reject procedure in the next file —
-- because ServiceVendorKYC is a new entity_type on the same generic
-- WorkFlowApproval engine, not a new approval mechanism.
-- ============================================================

-- ── service_vendor_kyc ───────────────────────────────────────────────────────

IF OBJECT_ID('dbo.service_vendor_kyc', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_vendor_kyc (
        service_vendor_kyc_sno INT IDENTITY(1,1) PRIMARY KEY,
        -- generated only on final approval (mirrors kyc_basic_info.supp_code's
        -- own "NULL until approved" behavior) — format SVK-YYYY-NNNN
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
        -- JSON array of {documentType,url,filename,mimetype,size}, same shape
        -- Kyc.controller.js#createKYCRecord already builds for kyc_basic_info
        document                              NVARCHAR(MAX) NULL,
        remarks                                NVARCHAR(500) NULL,
        workflow_types_id                       INT NULL,
        current_approver_id                      VARCHAR(30) NULL,
        -- P=Pending, A=Approved, R=Rejected, X=Expired/Deactivated. 'D' reserved,
        -- same convention as service_agreement — never inserted by the create proc.
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
-- Mirrors service_agreement_history's shape exactly.

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
--   gst_no?, is_msme_avail, msme_no?, pan_no, supplier_cat_code?, document?,
--   remarks?, created_by }
-- Always resolves and requires a workflow, same as sp_nt_CreateServiceAgreement.
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
            document, remarks, workflow_types_id, current_approver_id, status, is_active, created_by
        )
        VALUES (
            @com_sno, @div_sno, @brn_sno, @dept_sno, @company_name, @contact_person, @email, @mobile_number,
            @business_type, @is_gst_avail, @gst_no, @is_msme_avail, @msme_no, @pan_no, @supplier_cat_code,
            @document, @remarks, @workflow_types_id, @first_approver, 'P', 'Y', @created_by
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
-- approver. Mirrors sp_nt_GetServiceAgreementsForApproval's shape, including
-- stage_order_json so the frontend can round-trip approval_stages back into
-- sp_approve_service_vendor_kyc.
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
-- sp_nt_GetApprovedServiceVendorKycs — approved records only, for admin
-- visibility / picking which one to map to a service (see
-- 45_service_master_supplier_and_product.sql's ServiceMasterSupplierMapping,
-- which sources its VendorMaster options from kyc_basic_info directly via
-- the existing sp_nt_GetApprovedVendorsForServicePicker — this proc is a
-- ServiceVendorKYC-specific view for the KYC admin screen itself, not the
-- supplier-mapping picker).
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
-- After running, confirm:
--   SELECT * FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_vendor_kyc') ORDER BY column_id;
--   SELECT name FROM sys.procedures WHERE name LIKE '%ServiceVendorKyc%';
--   SELECT * FROM dbo.entity_master WHERE entity_code = 'ServiceVendorKYC';
--
-- NOTE before using in anger: same setup burden as ServiceAgreement —
-- sp_nt_CreateServiceVendorKyc will THROW 58008 until an actual
-- approval_workflow_master/workflow_types row is configured with
-- entity_type='ServiceVendorKYC' for each (com_sno,div_sno,brn_sno,dept_sno)
-- that needs to submit one. See 48_service_vendor_kyc_screens_and_workflow.sql.
--
-- Not yet built in this file (see next files):
--   - sp_approve_service_vendor_kyc + kyc_basic_info auto-provisioning (44)
--   - the Node.js ServiceVendorKyc module and screens/workflow config (48)
-- ============================================================
