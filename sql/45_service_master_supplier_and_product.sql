-- ============================================================
-- Service Master: predefined suppliers per service + linked catalogue product
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/Masters generic pipeline (new master key
--            "ServiceMasterSupplierMapping"), sp_nt_GetServiceRecords/
--            sp_nt_CreateServiceRecords (existing, versioned here)
--
-- Why this is needed
-- ------------------
-- Confirmed via full-repo grep: no join table between service_master and
-- vendors exists anywhere — every approved vendor
-- (sp_nt_GetApprovedVendorsForServicePicker) shows up for every service.
-- The user asked for each service to have predefined suppliers: pick one
-- when there's only one, choose among several when there's more. This file
-- adds that mapping, configured on Service Master itself (confirmed via
-- clarifying question), reusing the fully generic Masters CRUD pipeline —
-- each admin-grid row is one service+supplier pair (same UX as any other
-- simple master, e.g. BankAccountTypeMaster), no bespoke route or new
-- multi-select component needed.
--
-- Deliberately does NOT touch service_agreement.vendor_sno or
-- service_vendor_daily_entry.vendor_sno, or their FK targets — both stay
-- pointed at kyc_basic_info exactly as today. The new
-- sp_nt_GetApprovedSuppliersForService(@service_sno) below returns real
-- kyc_basic_info rows (filtered through this mapping), so every existing
-- downstream consumer of a vendor_sno value (recurring PO issuance, the
-- PO-generated email's getVendorContact lookup, the generic VendorMaster
-- picker) needs zero changes — only the FRONTEND source for the vendor_sno
-- dropdown becomes scoped instead of global.
--
-- Also in this file: service_master.default_product_sno, linking a
-- Vendor-Driven service to one catalogue product (confirmed via clarifying
-- question: one product per service, not picked fresh per entry) so daily
-- entries can show product details (name/description/HSN/UOM) without a
-- second lookup — sp_nt_GetServiceRecords already backs the ServiceMaster
-- options fetch every consumer screen uses, so joining product_master here
-- makes the details ride along for free.
--
-- product_master's live column list (queried via INFORMATION_SCHEMA.COLUMNS
-- — predates this repo's migration convention, same as kyc_basic_info):
-- prod_sno (identity), company_sno, division_sno, branch_sno, dept_sno,
-- cat_sno, subcat_sno, prod_name, prod_description, prod_notes, prod_code,
-- uom_sno, tax_sno, prod_hsn_code, prod_active (NOT is_active), prod_created_date,
-- prod_created_by, prod_modified_date, prod_modified_by, prod_uom_con_factor.
-- ============================================================

-- ── service_master_supplier ──────────────────────────────────────────────────

IF OBJECT_ID('dbo.service_master_supplier', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_master_supplier (
        mapping_sno         INT IDENTITY(1,1) PRIMARY KEY,
        service_sno          INT         NOT NULL,
        kyc_basic_info_sno    INT        NOT NULL,
        is_active              CHAR(1)   NOT NULL DEFAULT 'Y',
        created_by              VARCHAR(20) NULL,
        created_at               DATETIME  NOT NULL DEFAULT GETDATE(),
        CONSTRAINT UQ_service_master_supplier UNIQUE (service_sno, kyc_basic_info_sno),
        CONSTRAINT FK_service_master_supplier_service FOREIGN KEY (service_sno)
            REFERENCES dbo.service_master (service_sno),
        CONSTRAINT FK_service_master_supplier_vendor FOREIGN KEY (kyc_basic_info_sno)
            REFERENCES dbo.kyc_basic_info (kyc_basic_info_sno)
    );
END;
GO

-- ── service_master: link to a default catalogue product ────────────────────

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_master') AND name = 'default_product_sno')
    ALTER TABLE dbo.service_master ADD default_product_sno INT NULL
        CONSTRAINT FK_service_master_default_product FOREIGN KEY REFERENCES dbo.product_master (prod_sno);
GO

-- ============================================================
-- sp_nt_GetServiceMasterSupplierMappings — unfiltered list, for the
-- ServiceMasterSupplierMapping admin grid.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServiceMasterSupplierMappings', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetServiceMasterSupplierMappings;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceMasterSupplierMappings
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        msm.mapping_sno, msm.service_sno, sm.service_name,
        msm.kyc_basic_info_sno, k.company_name, k.supp_code,
        msm.is_active
    FROM dbo.service_master_supplier msm
    JOIN dbo.service_master sm ON sm.service_sno = msm.service_sno
    JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = msm.kyc_basic_info_sno
    WHERE msm.is_active = 'Y'
    ORDER BY sm.service_name, k.company_name;
END;
GO

-- ============================================================
-- sp_nt_CreateServiceMasterSupplierMapping
-- @jsonInput: { service_sno, kyc_basic_info_sno, created_by }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateServiceMasterSupplierMapping', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateServiceMasterSupplierMapping;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceMasterSupplierMapping
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
        THROW 60001, N'Invalid JSON payload provided.', 1;

    DECLARE @service_sno        INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT),
            @kyc_basic_info_sno INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno') AS INT),
            @created_by         VARCHAR(20) = JSON_VALUE(@jsonInput, '$.created_by');

    IF @service_sno IS NULL OR @kyc_basic_info_sno IS NULL
        THROW 60002, N'service_sno and kyc_basic_info_sno are required.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.service_master WHERE service_sno = @service_sno AND is_active = 'Y')
        THROW 60003, N'service_sno does not reference an active service.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = @kyc_basic_info_sno AND status = 'A' AND is_active = 'Y')
        THROW 60004, N'kyc_basic_info_sno does not reference an approved, active vendor.', 1;

    IF EXISTS (SELECT 1 FROM dbo.service_master_supplier WHERE service_sno = @service_sno AND kyc_basic_info_sno = @kyc_basic_info_sno AND is_active = 'Y')
        THROW 60005, N'This supplier is already mapped to this service.', 1;

    INSERT INTO dbo.service_master_supplier (service_sno, kyc_basic_info_sno, is_active, created_by)
    VALUES (@service_sno, @kyc_basic_info_sno, 'Y', @created_by);

    SELECT SCOPE_IDENTITY() AS mapping_sno, N'SUCCESS' AS status, N'Supplier mapped to service.' AS message;
END;
GO

-- ============================================================
-- sp_nt_GetApprovedSuppliersForService — the scoped picker used by
-- ServiceAgreementPage / the Vendor Driven daily-entry form's vendor_sno
-- field (reactive fetch keyed on the selected service_sno), replacing the
-- previously-global VendorMaster options source for those two fields.
-- @jsonInput: { service_sno }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetApprovedSuppliersForService', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetApprovedSuppliersForService;
GO
CREATE PROCEDURE dbo.sp_nt_GetApprovedSuppliersForService
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @service_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);

    IF @service_sno IS NULL
        THROW 60010, N'service_sno is required.', 1;

    SELECT k.kyc_basic_info_sno, k.company_name, k.supp_code, k.email, k.mobile_number
    FROM dbo.service_master_supplier msm
    JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = msm.kyc_basic_info_sno
    WHERE msm.service_sno = @service_sno AND msm.is_active = 'Y'
      AND k.status = 'A' AND k.is_active = 'Y'
    ORDER BY k.company_name;
END;
GO

-- ============================================================
-- sp_nt_GetServiceRecords v2 — adds default_product_sno + joined product
-- details (product_name/product_description/product_hsn_code/product_uom_name).
-- Filter logic unchanged from v1 (05_service_masters.sql).
-- @jsonInput optional: { service_type_sno }
-- ============================================================
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
        sm.is_active,
        sm.default_product_sno,
        pm.prod_name           AS product_name,
        pm.prod_description    AS product_description,
        pm.prod_hsn_code       AS product_hsn_code,
        pum.uom_name           AS product_uom_name
    FROM dbo.service_master sm
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.uom_master um     ON um.uom_sno = sm.default_uom_sno
    LEFT JOIN dbo.product_master pm ON pm.prod_sno = sm.default_product_sno
    LEFT JOIN dbo.uom_master pum    ON pum.uom_sno = pm.uom_sno
    WHERE sm.is_active = 'Y'
      AND (@service_type_sno IS NULL OR sm.service_type_sno = @service_type_sno)
    ORDER BY sm.service_name;
END;
GO

-- ============================================================
-- sp_nt_CreateServiceRecords v2 — adds optional default_product_sno.
-- Everything else unchanged from v1 (05_service_masters.sql), same error
-- codes for the unchanged checks.
-- @jsonInput adds: default_product_sno?
-- ============================================================
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
            @default_product_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.default_product_sno') AS INT),
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

    IF @default_product_sno IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.product_master WHERE prod_sno = @default_product_sno AND prod_active = 'Y')
    BEGIN
        THROW 50006, N'default_product_sno does not reference an active product.', 1;
        RETURN;
    END;

    INSERT INTO dbo.service_master (
        service_name, service_code, service_type_sno, default_uom_sno, sac_code,
        is_recurring, recurrence_cadence, recurrence_interval_days, description,
        default_product_sno, is_active, created_by
    )
    VALUES (
        @service_name, @service_code, @service_type_sno, @default_uom_sno, @sac_code,
        @is_recurring, @recurrence_cadence, @recurrence_interval_days, @description,
        @default_product_sno, 'Y', @created_by
    );

    SELECT SCOPE_IDENTITY() AS service_sno,
           @service_code    AS service_code,
           N'SUCCESS'       AS status,
           N'Service created successfully.' AS message;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_master') AND name = 'default_product_sno';
--   SELECT OBJECT_ID('dbo.service_master_supplier');
--   SELECT name FROM sys.procedures WHERE name IN (
--     'sp_nt_GetServiceMasterSupplierMappings','sp_nt_CreateServiceMasterSupplierMapping',
--     'sp_nt_GetApprovedSuppliersForService','sp_nt_GetServiceRecords','sp_nt_CreateServiceRecords');
-- ============================================================
