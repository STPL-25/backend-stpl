-- ============================================================
-- Supplier Status — every supplier with where its approval stands.
-- Database : Non_trade_Dev (re-runnable; same objects can be created in Non_Trade)
--
-- Request (2026-09-24): a page for the EXISTING suppliers showing whether each
-- is approved or still awaiting approval (and, for a pending one, who it is
-- waiting on and what the rest of the chain is).
--
-- Why new procedures rather than sp_get_kyc_info / sp_get_kyc_approval:
--   * sp_get_kyc_info returns every kyc_basic_info row but with all the JSON
--     address/bank/contact/document blobs — far more than a status list needs —
--     and no approver names, no stage position, no service-vendor requests.
--   * sp_get_kyc_approval is "pending for ONE approver".
--   Neither is touched; both keep serving the KYC Data View / KYC Approval
--   screens exactly as before.
--
-- Two places hold a supplier's approval:
--   source 'KYC'         kyc_basic_info + kyc_history (regular supplier KYC; also the
--                        row a Service Vendor KYC is provisioned into on approval,
--                        vendor_category = 'SERVICE')
--   source 'SERVICE_KYC' service_vendor_kyc + service_vendor_kyc_history — ONLY the
--                        requests not yet provisioned into kyc_basic_info (pending /
--                        rejected ones), so an approved service vendor is listed once.
--
-- What is NOT available and therefore not shown: approval COMMENTS for regular
-- KYC. sp_approve_kyc_datas receives `comments` from the API but never stores
-- them (kyc_history has no comment column). Service Vendor KYC does store them
-- (service_vendor_kyc_history.comment) and they are returned.
--
-- Names resolve staff first, then non-staff (nt_nonstaff_login.full_name), via one
-- small #people table filled per call — the same approach as sql/96.
-- ============================================================

-- ── 1. sp_nt_GetSupplierStatusList ──────────────────────────────────────────
CREATE   PROCEDURE dbo.sp_nt_GetSupplierStatusList
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #s (
        source              VARCHAR(12)   COLLATE DATABASE_DEFAULT NOT NULL,
        record_id           INT           NOT NULL,
        company_name        NVARCHAR(300) NULL,
        supp_code           VARCHAR(50)   NULL,
        status              CHAR(1)       NULL,
        category            VARCHAR(20)   NOT NULL,
        contact_person      NVARCHAR(200) NULL,
        email               NVARCHAR(200) NULL,
        mobile_number       VARCHAR(50)   NULL,
        gst_no              VARCHAR(50)   NULL,
        pan_no              VARCHAR(50)   NULL,
        business_type_name  NVARCHAR(200) NULL,
        created_by          VARCHAR(50)   COLLATE DATABASE_DEFAULT NULL,
        created_date        DATETIME      NULL,
        current_approver_id VARCHAR(50)   COLLATE DATABASE_DEFAULT NULL,
        stage_no            INT           NULL,
        total_stages        INT           NULL,
        last_action_by      VARCHAR(50)   COLLATE DATABASE_DEFAULT NULL,
        last_action_date    DATETIME      NULL
    );

    -- ── A. regular KYC (and provisioned service vendors) ─────────────────────
    INSERT INTO #s
    SELECT
        'KYC',
        k.kyc_basic_info_sno,
        COALESCE(NULLIF(LTRIM(RTRIM(k.company_name)), ''), NULLIF(LTRIM(RTRIM(k.legal_name)), ''), NULLIF(LTRIM(RTRIM(k.trade_name)), '')),
        k.supp_code,
        k.status,
        CASE WHEN k.vendor_category = 'SERVICE' THEN 'Service Vendor' ELSE 'Supplier' END,
        k.contact_person,
        k.email,
        k.mobile_number,
        k.gst_no,
        k.pan_no,
        COALESCE(bt.business_types_name, NULLIF(LTRIM(RTRIM(k.business_type)), '')),
        k.created_by,
        k.created_date,
        CASE WHEN k.status = 'P' THEN k.approver_ecno END,
        CASE WHEN k.status = 'P' THEN (
            SELECT TOP 1 CAST(st.[key] AS INT) + 1
            FROM dbo.workflow_stage ws
            CROSS APPLY OPENJSON(ws.stage_order_json) AS st
            WHERE ws.workflow_types_id = k.workflow_types_id AND ws.is_active = 'Y'
              AND JSON_VALUE(st.value, '$.approver_ecno') = k.approver_ecno
        ) END,
        (
            SELECT COUNT(*)
            FROM dbo.workflow_stage ws
            CROSS APPLY OPENJSON(ws.stage_order_json) AS st
            WHERE ws.workflow_types_id = k.workflow_types_id AND ws.is_active = 'Y'
        ),
        COALESCE(h.status_by, k.modified_by),
        COALESCE(CAST(h.status_date AS DATETIME), k.modified_date)
    FROM dbo.kyc_basic_info k
    LEFT JOIN dbo.business_types bt ON bt.business_types_id = TRY_CONVERT(INT, k.business_type)
    OUTER APPLY (
        SELECT TOP 1 status_by, status_date
        FROM dbo.kyc_history
        WHERE kyc_basic_info_sno = k.kyc_basic_info_sno
        ORDER BY kyc_history_sno DESC
    ) h;

    -- ── names ────────────────────────────────────────────────────────────────
    CREATE TABLE #codes (code VARCHAR(50) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
    INSERT INTO #codes (code)
    SELECT DISTINCT LTRIM(RTRIM(c)) FROM (
        SELECT created_by AS c FROM #s
        UNION SELECT current_approver_id FROM #s
        UNION SELECT last_action_by FROM #s
    ) x
    WHERE c IS NOT NULL AND LTRIM(RTRIM(c)) <> '';

    CREATE TABLE #people (code VARCHAR(50) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, name NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL);
    INSERT INTO #people (code, name)
    SELECT c.code, MAX(COALESCE(NULLIF(LTRIM(RTRIM(e.ename)), ''), ns.full_name))
    FROM #codes c
    LEFT JOIN dbo.vw_verified_employees e ON e.ecno = c.code
    LEFT JOIN dbo.nt_nonstaff_login ns   ON ns.login_id = c.code
    GROUP BY c.code;

    SELECT
        s.source, s.record_id, s.company_name, s.supp_code, s.status, s.category,
        s.contact_person, s.email, s.mobile_number, s.gst_no, s.pan_no, s.business_type_name,
        s.created_by, pc.name AS created_by_name, s.created_date,
        s.current_approver_id, pa.name AS current_approver_name, s.stage_no, s.total_stages,
        s.last_action_by, pl.name AS last_action_by_name, s.last_action_date
    FROM #s s
    LEFT JOIN #people pc ON pc.code = s.created_by
    LEFT JOIN #people pa ON pa.code = s.current_approver_id
    LEFT JOIN #people pl ON pl.code = s.last_action_by
    ORDER BY
        CASE s.status WHEN 'P' THEN 0 WHEN 'A' THEN 1 ELSE 2 END,   -- pending first
        s.created_date DESC, s.record_id DESC;

    DROP TABLE #people;
    DROP TABLE #codes;
    DROP TABLE #s;
END;