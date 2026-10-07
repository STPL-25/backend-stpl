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
CREATE   PROCEDURE dbo.sp_nt_GetSupplierFullDetails
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