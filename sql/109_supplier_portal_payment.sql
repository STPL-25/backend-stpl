-- ============================================================
-- Supplier KYC: "pays via website / portal" option (no bank account).
-- Database: Non_trade_Dev (MSSQL).  ROLLBACK: sql/backups/109_ROLLBACK.sql
--
-- Corporates that are paid through their own website have no bank account to
-- give, but KYC made one mandatory. kyc_basic_info gains a flag + portal
-- name/url/instructions; the submit validation (kycValidation.js) then accepts
-- a portal instead of a bank account. Existing rows default to 'N' (bank).
-- Re-runnable.
--   * sp_InsertKYCData            saves the 4 columns, skips bank rows when portal
--   * sp_nt_GetSupplierFullDetails returns them in the basic result set
-- ============================================================
IF COL_LENGTH('dbo.kyc_basic_info','pay_via_portal') IS NULL
    ALTER TABLE dbo.kyc_basic_info ADD pay_via_portal CHAR(1) NOT NULL CONSTRAINT DF_kyc_basic_info_pay_via_portal DEFAULT 'N';
IF COL_LENGTH('dbo.kyc_basic_info','payment_portal_name') IS NULL ALTER TABLE dbo.kyc_basic_info ADD payment_portal_name NVARCHAR(150) NULL;
IF COL_LENGTH('dbo.kyc_basic_info','payment_portal_url')  IS NULL ALTER TABLE dbo.kyc_basic_info ADD payment_portal_url  NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.kyc_basic_info','payment_instructions') IS NULL ALTER TABLE dbo.kyc_basic_info ADD payment_instructions NVARCHAR(1000) NULL;
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_InsertKYCData]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE
            @kyc_basic_info_sno INT,
            @company_name       NVARCHAR(255),
            @contact_name       NVARCHAR(100),
            @email              NVARCHAR(100),
            @mobile_number      VARCHAR(15),
            @business_type      NVARCHAR(50),
            @is_gst_avail       CHAR(1),
            @gst_no             VARCHAR(20),
            @is_msme_avail      CHAR(1),
            @msme_no            VARCHAR(20),
            @pan_no             VARCHAR(20),
            @created_by         VARCHAR(50),
            @addresses          NVARCHAR(MAX),
            @bankDetails        NVARCHAR(MAX),
            @contacts           NVARCHAR(MAX),
            @document           NVARCHAR(MAX),
            @approver_ecno      VARCHAR(20),
            @supplier_cat_code  VARCHAR(20),
            @legal_name         VARCHAR(100),
            @trade_name         VARCHAR(100),
            @txp_type           VARCHAR(10),
            @gst_status         VARCHAR(1),
            @gst_blk_status     VARCHAR(10),
            @date_of_reg        date,
            @workflow_types_id  INT,
            @pay_via_portal     CHAR(1),
            @portal_name        NVARCHAR(150),
            @portal_url         NVARCHAR(500),
            @pay_instructions   NVARCHAR(1000);
        -- Extract scalar values from JSON
        SELECT
            @company_name  = JSON_VALUE(@jsonInput, '$.company_name'),
            @contact_name  = JSON_VALUE(@jsonInput, '$.contact_name'),
            @email         = JSON_VALUE(@jsonInput, '$.email'),
            @mobile_number = JSON_VALUE(@jsonInput, '$.mobile_number'),
            @business_type = JSON_VALUE(@jsonInput, '$.business_type'),
            @is_gst_avail  = CASE WHEN JSON_VALUE(@jsonInput, '$.is_gst_avail')  = 'true' THEN 'Y' ELSE 'N' END,
            @gst_no        = JSON_VALUE(@jsonInput, '$.gst_no'),
            @is_msme_avail = CASE WHEN JSON_VALUE(@jsonInput, '$.is_msme_avail') = 'true' THEN 'Y' ELSE 'N' END,
            @msme_no       = JSON_VALUE(@jsonInput, '$.msme_no'),
            @pan_no        = JSON_VALUE(@jsonInput, '$.pan_no'),
            @created_by    = ISNULL(JSON_VALUE(@jsonInput, '$.created_by'), ''),
            @supplier_cat_code=JSON_VALUE(@jsonInput, '$.supplier_cat_code'),
            @legal_name=JSON_VALUE(@jsonInput, '$.legal_name'),
            @trade_name= JSON_VALUE(@jsonInput, '$.trade_name'),
            @txp_type=  JSON_VALUE(@jsonInput, '$.txp_type'),
            @gst_status  =  JSON_VALUE(@jsonInput, '$.gst_status'),
            @gst_blk_status=  JSON_VALUE(@jsonInput, '$.gst_blk_status'),
            @date_of_reg  =JSON_VALUE(@jsonInput, '$.date_of_reg');



        -- Supplier pays via its own website/portal instead of a bank account.
        SET @pay_via_portal = CASE WHEN JSON_VALUE(@jsonInput, '$.pay_via_portal') IN ('true','1','Y') THEN 'Y' ELSE 'N' END;
        SET @portal_name      = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.payment_portal_name'))), '');
        SET @portal_url       = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.payment_portal_url'))), '');
        SET @pay_instructions = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.payment_instructions'))), '');
        IF @pay_via_portal = 'Y' AND (@portal_name IS NULL OR @portal_url IS NULL)
            THROW 50021, 'Portal payment needs the portal name and portal URL.', 1;

        SET  @workflow_types_id=5;
      SELECT @approver_ecno = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key]  = '0'
          AND s2.[key] = '0';

        --IF @approver_ecno IS NULL
        --    THROW 50007, 'No approver found for the first stage of the workflow.', 1;


        SET @addresses   = JSON_QUERY(@jsonInput, '$.addresses');
        SET @bankDetails = JSON_QUERY(@jsonInput, '$.bankDetails');
        SET @contacts    = JSON_QUERY(@jsonInput, '$.contacts');
        SET @document    = JSON_VALUE(@jsonInput, '$.document');

        -- 1. Insert into kyc_basic_info
        INSERT INTO kyc_basic_info (
            company_name, contact_person, email, mobile_number,
            business_type, is_gst_avail, gst_no, is_msme_avail,
            msme_no, pan_no, created_by, created_date, is_active, status ,workflow_types_id ,approver_ecno ,supplier_cat_code,
            legal_name,trade_name,txp_type, gst_status,gst_blk_status ,date_of_reg,
            pay_via_portal, payment_portal_name, payment_portal_url, payment_instructions
        )
        VALUES (
            @company_name, @contact_name, @email, @mobile_number,
            @business_type, @is_gst_avail, @gst_no, @is_msme_avail,
            @msme_no, @pan_no, @created_by, GETDATE(), 'Y', 'P' ,@workflow_types_id ,@approver_ecno ,@supplier_cat_code
            ,@legal_name,@trade_name,@txp_type,@gst_status,@gst_blk_status,@date_of_reg,
            @pay_via_portal, @portal_name, @portal_url, @pay_instructions
        );

        SET @kyc_basic_info_sno = SCOPE_IDENTITY();

        -- 2. Insert into kyc_address_info
        IF ISJSON(@addresses) = 1
        BEGIN
            INSERT INTO kyc_address_info (
                kyc_basic_info_sno, address_type, door_no, street, area, city,
                taluk, state, state_code, pincode, location_link, is_primary,
                created_date, is_active, status
            )
            SELECT
                @kyc_basic_info_sno,
                CASE WHEN JSON_VALUE(value, '$.isPrimary') = 'true' THEN 'PRIMARY' ELSE 'SECONDARY' END,
                JSON_VALUE(value, '$.door_no'),
                JSON_VALUE(value, '$.street'),
                JSON_VALUE(value, '$.area'),
                JSON_VALUE(value, '$.city'),
                JSON_VALUE(value, '$.taluk'),
                JSON_VALUE(value, '$.state'),
                TRY_CONVERT(INT, JSON_VALUE(value, '$.state_code')),
                JSON_VALUE(value, '$.pincode'),
                NULLIF(JSON_VALUE(value, '$.location_link'), ''),
                CASE WHEN JSON_VALUE(value, '$.isPrimary') = 'true' THEN 'Y' ELSE 'N' END,
                GETDATE(), 'Y', 'P'
            FROM OPENJSON(@addresses);
        END

        -- 3. Insert into kyc_bank_info (none when the supplier pays via its portal)
        IF @pay_via_portal = 'N' AND ISJSON(@bankDetails) = 1
        BEGIN
            INSERT INTO kyc_bank_info (
                kyc_basic_info_sno, ac_holder_name, ac_number, ac_type, ifsc,
                bank_name, bank_branch_name, bank_address, is_primary,
                created_date, is_active, status
            )
            SELECT
                @kyc_basic_info_sno,
                JSON_VALUE(value, '$.ac_holder_name'),
                JSON_VALUE(value, '$.ac_number'),
                JSON_VALUE(value, '$.ac_type'),
                JSON_VALUE(value, '$.ifsc'),
                JSON_VALUE(value, '$.bank_name'),
                JSON_VALUE(value, '$.bank_branch_name'),
                JSON_VALUE(value, '$.bank_address'),
                CASE WHEN JSON_VALUE(value, '$.isPrimary') = 'true' THEN 'Y' ELSE 'N' END,
                GETDATE(), 'Y', 'P'
            FROM OPENJSON(@bankDetails);
        END

        -- 4. Insert into kyc_contact_info
        IF ISJSON(@contacts) = 1
        BEGIN
            INSERT INTO kyc_contact_info (
                kyc_basic_info_sno, contact_type, contact_name, contact_position,
                contact_mobile, contact_email, created_date, is_active, status
            )
            SELECT
                @kyc_basic_info_sno,
                CASE WHEN JSON_VALUE(value, '$.isPrimary') = 'true' THEN 'PRIMARY' ELSE 'SECONDARY' END,
                JSON_VALUE(value, '$.ownername'),
                JSON_VALUE(value, '$.ownerposition'),
                JSON_VALUE(value, '$.ownermobile'),
                JSON_VALUE(value, '$.owneremail'),
                GETDATE(), 'Y', 'P'
            FROM OPENJSON(@contacts);
        END

        -- 5. Insert into kyc_document_info
        IF ISJSON(@document) = 1
        BEGIN
            INSERT INTO kyc_document_info (
                kyc_basic_info_sno, document_type, document_name,
                document_path, file_size, uploaded_date, is_active, status
            )
            SELECT
                @kyc_basic_info_sno,
                JSON_VALUE(value, '$.documentType'),
                JSON_VALUE(value, '$.filename'),
                JSON_VALUE(value, '$.url'),
                JSON_VALUE(value, '$.size'),
                GETDATE(), 'Y', 'P'
            FROM OPENJSON(@document);
        END

        COMMIT TRANSACTION;
                  SELECT
            @kyc_basic_info_sno AS kyc_basic_info_sno,
            'KYC Data Saved Successfully' AS message,
            'Success' AS Status;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT            = ERROR_SEVERITY();
        DECLARE @ErrorState    INT            = ERROR_STATE();

        SELECT @ErrorMessage AS errorMessage, 'Error' AS Status;
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END;
GO

-- ============================================================
-- Supplier Status / KYC Approval: "view + download everything entered".
-- Database: Non_trade_Dev (MSSQL)
--
-- One read-only SP returning every address / bank account / contact / document
-- and the verification results for a supplier, for the detail dialogs and the
-- Excel / PDF downloads. Additive only - no existing object is touched.
--
--   @source     'KYC' (kyc_basic_info) | 'SERVICE_KYC' (service vendor request
--               not yet provisioned - its single address/bank live on the row)
--   @record_id  kyc_basic_info_sno | service_vendor_kyc_sno
--
-- Result sets: RS1 basic, RS2 addresses, RS3 banks, RS4 contacts,
--              RS5 documents, RS6 verification results.
-- Deactivated rows (is_active = 'N') are left out.
-- Re-runnable (CREATE OR ALTER).
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetSupplierFullDetails
    @source    VARCHAR(12),
    @record_id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @source = 'SERVICE_KYC'
    BEGIN
        SELECT 'SERVICE_KYC' AS source, v.service_vendor_kyc_sno AS record_id,
               COALESCE(NULLIF(LTRIM(RTRIM(v.company_name)), ''), v.legal_name, v.trade_name) AS company_name,
               v.legal_name, v.trade_name, v.service_vendor_code AS supp_code, v.status,
               'Service Vendor' AS category, v.contact_person, v.email, v.mobile_number,
               COALESCE(bt.business_types_name, NULLIF(LTRIM(RTRIM(v.business_type)), '')) AS business_type_name,
               v.is_gst_avail, v.gst_no, v.gst_status, v.gst_blk_status, v.date_of_reg,
               v.is_msme_avail, v.msme_no, v.pan_no, v.created_by, v.created_at AS created_date
        FROM dbo.service_vendor_kyc v
        LEFT JOIN dbo.business_types bt ON bt.business_types_id = TRY_CONVERT(INT, v.business_type)
        WHERE v.service_vendor_kyc_sno = @record_id;

        SELECT CAST('PRIMARY' AS NVARCHAR(50)) AS address_type, CAST(NULL AS NVARCHAR(300)) AS door_no,
               CAST(NULL AS NVARCHAR(200)) AS street, CAST(NULL AS NVARCHAR(200)) AS area, v.city, v.taluk, v.state,
               v.state_code, CAST(NULL AS NVARCHAR(20)) AS pincode, CAST(NULL AS NVARCHAR(500)) AS location_link,
               CAST('Y' AS CHAR(1)) AS is_primary
        FROM dbo.service_vendor_kyc v
        WHERE v.service_vendor_kyc_sno = @record_id
          AND COALESCE(v.city, v.taluk, v.state) IS NOT NULL;

        SELECT v.ac_holder_name, v.ac_number, v.ac_type,
               COALESCE(bat.account_type_name, NULLIF(LTRIM(RTRIM(v.ac_type)), '')) AS ac_type_name,
               v.ifsc, v.bank_name, v.bank_branch_name, v.bank_address, CAST('Y' AS CHAR(1)) AS is_primary
        FROM dbo.service_vendor_kyc v
        LEFT JOIN dbo.bank_account_type_master bat ON bat.bank_account_type_sno = TRY_CONVERT(INT, v.ac_type)
        WHERE v.service_vendor_kyc_sno = @record_id
          AND COALESCE(NULLIF(LTRIM(RTRIM(v.ac_number)), ''), NULLIF(LTRIM(RTRIM(v.bank_name)), '')) IS NOT NULL;

        SELECT TOP 0 CAST(NULL AS NVARCHAR(50)) AS contact_type, CAST(NULL AS NVARCHAR(200)) AS contact_name,
               CAST(NULL AS NVARCHAR(200)) AS contact_position, CAST(NULL AS NVARCHAR(50)) AS contact_mobile,
               CAST(NULL AS NVARCHAR(200)) AS contact_email;

        SELECT CAST('Document' AS NVARCHAR(100)) AS document_type, CAST('Attachment' AS NVARCHAR(200)) AS document_name,
               v.document AS document_path, CAST(NULL AS DATETIME) AS uploaded_date
        FROM dbo.service_vendor_kyc v
        WHERE v.service_vendor_kyc_sno = @record_id AND NULLIF(LTRIM(RTRIM(v.document)), '') IS NOT NULL;

        SELECT TOP 0 CAST(NULL AS NVARCHAR(50)) AS verify_type, CAST(NULL AS NVARCHAR(100)) AS identifier,
               CAST(NULL AS BIT) AS is_valid, CAST(NULL AS DATETIME) AS created_at;
        RETURN;
    END

    SELECT 'KYC' AS source, k.kyc_basic_info_sno AS record_id,
           COALESCE(NULLIF(LTRIM(RTRIM(k.company_name)), ''), k.legal_name, k.trade_name) AS company_name,
           k.legal_name, k.trade_name, k.supp_code, k.status,
           CASE WHEN k.vendor_category = 'SERVICE' THEN 'Service Vendor' ELSE 'Supplier' END AS category,
           k.contact_person, k.email, k.mobile_number,
           COALESCE(bt.business_types_name, NULLIF(LTRIM(RTRIM(k.business_type)), '')) AS business_type_name,
           k.is_gst_avail, k.gst_no, k.gst_status, k.gst_blk_status, k.date_of_reg,
           k.is_msme_avail, k.msme_no, k.pan_no, k.created_by, k.created_date,
           k.pay_via_portal, k.payment_portal_name, k.payment_portal_url, k.payment_instructions
    FROM dbo.kyc_basic_info k
    LEFT JOIN dbo.business_types bt ON bt.business_types_id = TRY_CONVERT(INT, k.business_type)
    WHERE k.kyc_basic_info_sno = @record_id;

    SELECT a.address_type, a.door_no, a.street, a.area, a.city, a.taluk, a.state, a.state_code,
           a.pincode, a.location_link, a.is_primary
    FROM dbo.kyc_address_info a
    WHERE a.kyc_basic_info_sno = @record_id AND ISNULL(a.is_active, 'Y') <> 'N'
    ORDER BY CASE WHEN a.address_type = 'PRIMARY' OR a.is_primary = 'Y' THEN 0 ELSE 1 END, a.kyc_address_sno;

    SELECT b.ac_holder_name, b.ac_number, b.ac_type,
           COALESCE(bat.account_type_name, NULLIF(LTRIM(RTRIM(b.ac_type)), '')) AS ac_type_name,
           b.ifsc, b.bank_name, b.bank_branch_name, b.bank_address, b.is_primary
    FROM dbo.kyc_bank_info b
    LEFT JOIN dbo.bank_account_type_master bat ON bat.bank_account_type_sno = TRY_CONVERT(INT, b.ac_type)
    WHERE b.kyc_basic_info_sno = @record_id AND ISNULL(b.is_active, 'Y') <> 'N'
    ORDER BY CASE WHEN b.is_primary = 'Y' THEN 0 ELSE 1 END, b.kyc_address_sno;

    SELECT c.contact_type, c.contact_name, c.contact_position, c.contact_mobile, c.contact_email
    FROM dbo.kyc_contact_info c
    WHERE c.kyc_basic_info_sno = @record_id AND ISNULL(c.is_active, 'Y') <> 'N'
    ORDER BY CASE WHEN c.contact_type = 'PRIMARY' THEN 0 ELSE 1 END, c.kyc_contact_sno;

    SELECT d.document_type, d.document_name, d.document_path, d.uploaded_date
    FROM dbo.kyc_document_info d
    WHERE d.kyc_basic_info_sno = @record_id AND ISNULL(d.is_active, 'Y') <> 'N'
    ORDER BY d.kyc_document_sno;

    SELECT r.verify_type, r.identifier, r.is_valid, r.pan_status, r.gst_status, r.gst_taxpayer_type,
           r.gst_last_update_date, r.nature_of_business_activities, r.msme_type, r.major_activity,
           r.udyam_registered_date, r.created_at
    FROM dbo.kyc_verification_response r
    WHERE r.kyc_basic_info_sno = @record_id
    ORDER BY r.id;
END
GO
