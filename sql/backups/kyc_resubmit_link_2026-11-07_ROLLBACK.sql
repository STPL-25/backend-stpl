-- ============================================================
-- ROLLBACK for sql/155_kyc_resubmit_link.sql. Database: Non_trade_Dev. Re-runnable.
-- Puts the three objects sql/155 changed back to the definitions they had on 2026-11-07, then drops what sql/155 added.
--
-- !! This DELETES the correction-link records and the resubmission history (kyc_resubmit_link, kyc_resubmission). The KYC rows
-- !! themselves are untouched: a KYC that was resubmitted stays pending (P) with its corrected values; one that has a link but
-- !! was never resubmitted stays rejected (R) - it just has no link any more.
-- sql/156 (sp_InsertKYCData created with QUOTED_IDENTIFIER ON) is NOT undone here: the old setting made every new KYC fail.
-- ============================================================
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- 1. objects sql/155 changed
CREATE OR ALTER VIEW dbo.vw_get_all_kyc_info
AS
    SELECT
        bf.*, -- your basic info columns
        -- Aggregate addresses into JSON array
        ISNULL((SELECT address_type,door_no,street,area,city,taluk,state,pincode,location_link FROM kyc_address_info af
         WHERE af.kyc_basic_info_sno = bf.kyc_basic_info_sno
         FOR JSON PATH), '[]') AS kyc_address,
        -- Aggregate bank info into JSON array
        ISNULL((SELECT ac_holder_name,ac_number,ac_type,ifsc,bank_name,bank_branch_name,bank_address,is_primary FROM kyc_bank_info kbi
         WHERE kbi.kyc_basic_info_sno = bf.kyc_basic_info_sno
         FOR JSON PATH), '[]') AS kyc_bank_info,
        -- Aggregate contacts into JSON array
        ISNULL((SELECT contact_type,contact_name,contact_position,contact_mobile,contact_email,created_date,is_active FROM kyc_contact_info ci
         WHERE ci.kyc_basic_info_sno = bf.kyc_basic_info_sno
         FOR JSON PATH), '[]') AS kyc_contact_details,
        -- Aggregate documents into JSON array
        ISNULL((SELECT document_type,document_name,document_path,uploaded_date,is_active FROM kyc_document_info di
         WHERE di.kyc_basic_info_sno = bf.kyc_basic_info_sno
         FOR JSON PATH), '[]') AS kyc_uploaded_doc
    FROM kyc_basic_info bf;
GO

-- 110: sp_get_kyc_approval - fix truncation of #kyc.kyc_bank_info (widen to NVARCHAR(MAX)). Re-runnable.

CREATE OR ALTER PROCEDURE dbo.sp_get_kyc_approval
    @Ecno VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NULLIF(LTRIM(RTRIM(@Ecno)), '') IS NULL
            THROW 50001, 'Ecno cannot be null or empty.', 1;

        SELECT v.*,
               CAST(NULL AS NVARCHAR(200)) AS business_type_name
        INTO #kyc
        FROM dbo.vw_get_all_kyc_info v
        WHERE v.approver_ecno = @Ecno
          AND v.status = 'P';

        -- View column kyc_bank_info is fixed-width; long/multi-account JSON overflowed it (error 2628).
        ALTER TABLE #kyc ALTER COLUMN kyc_bank_info NVARCHAR(MAX) NULL;

        UPDATE k
        SET business_type_name = COALESCE(bt.business_types_name, NULLIF(LTRIM(RTRIM(k.business_type)), '')),
            kyc_bank_info = ISNULL((
                SELECT kbi.ac_holder_name, kbi.ac_number, kbi.ac_type,
                       COALESCE(bat.account_type_name, NULLIF(LTRIM(RTRIM(kbi.ac_type)), '')) AS ac_type_name,
                       kbi.ifsc, kbi.bank_name, kbi.bank_branch_name, kbi.bank_address, kbi.is_primary
                FROM dbo.kyc_bank_info kbi
                LEFT JOIN dbo.bank_account_type_master bat
                       ON bat.bank_account_type_sno = TRY_CONVERT(INT, kbi.ac_type)
                WHERE kbi.kyc_basic_info_sno = k.kyc_basic_info_sno
                FOR JSON PATH), '[]')
        FROM #kyc k
        LEFT JOIN dbo.business_types bt
               ON bt.business_types_id = TRY_CONVERT(INT, k.business_type);

        SELECT * FROM #kyc;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

-- ── 2. sp_nt_GetSupplierStatusTimeline ──────────────────────────────────────
-- @source    'KYC'
-- @record_id kyc_basic_info_sno
-- Result sets: RS1 header (0 or 1 row), RS2 approval chain, RS3 what happened.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetSupplierStatusTimeline
    @source    VARCHAR(12),
    @record_id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @workflow_types_id INT, @status CHAR(1), @approver VARCHAR(50);
    SELECT @workflow_types_id = k.workflow_types_id,
               @status = k.status, @approver = k.approver_ecno
        FROM dbo.kyc_basic_info k
        WHERE k.kyc_basic_info_sno = @record_id;

    -- Every person code we will show, resolved once.
    CREATE TABLE #codes (code VARCHAR(50) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
    INSERT INTO #codes (code)
    SELECT DISTINCT LTRIM(RTRIM(c)) FROM (
        SELECT JSON_VALUE(st.value, '$.approver_ecno') AS c
            FROM dbo.workflow_stage ws CROSS APPLY OPENJSON(ws.stage_order_json) AS st
            WHERE ws.workflow_types_id = @workflow_types_id AND ws.is_active = 'Y'
        UNION SELECT @approver
        UNION SELECT created_by FROM dbo.kyc_basic_info WHERE @source = 'KYC' AND kyc_basic_info_sno = @record_id
        UNION SELECT modified_by FROM dbo.kyc_basic_info WHERE @source = 'KYC' AND kyc_basic_info_sno = @record_id
        UNION SELECT status_by FROM dbo.kyc_history WHERE @source = 'KYC' AND kyc_basic_info_sno = @record_id
    ) x
    WHERE c IS NOT NULL AND LTRIM(RTRIM(c)) <> '';

    CREATE TABLE #people (code VARCHAR(50) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, name NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL);
    INSERT INTO #people (code, name)
    SELECT c.code, MAX(COALESCE(NULLIF(LTRIM(RTRIM(e.ename)), ''), ns.full_name))
    FROM #codes c
    LEFT JOIN dbo.vw_verified_employees e ON e.ecno = c.code
    LEFT JOIN dbo.nt_nonstaff_login ns   ON ns.login_id = c.code
    GROUP BY c.code;

    -- RS1: header (last_action_* = the last modification, used only when history has no row for the final decision)
        SELECT
            'KYC' AS source, k.kyc_basic_info_sno AS record_id,
            COALESCE(NULLIF(LTRIM(RTRIM(k.company_name)), ''), k.legal_name, k.trade_name) AS company_name,
            k.legal_name, k.trade_name, k.supp_code, k.status,
            CASE WHEN k.vendor_category = 'SERVICE' THEN 'Service Vendor' ELSE 'Supplier' END AS category,
            k.contact_person, k.email, k.mobile_number, k.gst_no, k.pan_no, k.msme_no,
            COALESCE(bt.business_types_name, NULLIF(LTRIM(RTRIM(k.business_type)), '')) AS business_type_name,
            k.created_by, pc.name AS created_by_name, k.created_date,
            CASE WHEN k.status = 'P' THEN k.approver_ecno END AS current_approver_id,
            CASE WHEN k.status = 'P' THEN pa.name END AS current_approver_name,
            k.modified_by AS last_action_by, pl.name AS last_action_by_name, k.modified_date AS last_action_date
        FROM dbo.kyc_basic_info k
        LEFT JOIN dbo.business_types bt ON bt.business_types_id = TRY_CONVERT(INT, k.business_type)
        LEFT JOIN #people pc ON pc.code = k.created_by
        LEFT JOIN #people pa ON pa.code = k.approver_ecno
        LEFT JOIN #people pl ON pl.code = k.modified_by
        WHERE k.kyc_basic_info_sno = @record_id;

    -- RS2: the approval chain, in order, with names
    SELECT
        CAST(st.[key] AS INT) + 1             AS stage_no,
        JSON_VALUE(st.value, '$.stage')        AS stage_name,
        JSON_VALUE(st.value, '$.approver_ecno') AS approver_ecno,
        p.name                                 AS approver_name
    FROM dbo.workflow_stage ws
    CROSS APPLY OPENJSON(ws.stage_order_json) AS st
    LEFT JOIN #people p ON p.code = JSON_VALUE(st.value, '$.approver_ecno')
    WHERE ws.workflow_types_id = @workflow_types_id AND ws.is_active = 'Y'
    ORDER BY stage_no;

    -- RS3: what actually happened, oldest first (regular KYC history carries no comments).
        SELECT
            CASE h.status WHEN 'A' THEN 'APPROVED' WHEN 'R' THEN 'REJECTED' ELSE h.status END AS event,
            h.status_by, p.name AS status_by_name, CAST(h.status_date AS DATETIME) AS event_date,
            CAST(NULL AS VARCHAR(500)) AS comment
        FROM dbo.kyc_history h
        LEFT JOIN #people p ON p.code = h.status_by
        WHERE h.kyc_basic_info_sno = @record_id AND @source = 'KYC'
        ORDER BY h.kyc_history_sno;

    DROP TABLE #people;
    DROP TABLE #codes;
END;
GO

-- 2. objects sql/155 added
DROP PROCEDURE IF EXISTS dbo.sp_nt_KycResubmitSave;
DROP PROCEDURE IF EXISTS dbo.sp_nt_KycResubmitOpen;
DROP PROCEDURE IF EXISTS dbo.sp_nt_KycResubmitCheck;
DROP PROCEDURE IF EXISTS dbo.sp_nt_KycResubmitFindLink;
DROP PROCEDURE IF EXISTS dbo.sp_nt_KycResubmitLinkStatus;
DROP PROCEDURE IF EXISTS dbo.sp_nt_KycResubmitMarkEmail;
DROP PROCEDURE IF EXISTS dbo.sp_nt_KycResubmitIssue;
DROP TABLE IF EXISTS dbo.kyc_resubmission;
DROP TABLE IF EXISTS dbo.kyc_resubmit_link;
GO
