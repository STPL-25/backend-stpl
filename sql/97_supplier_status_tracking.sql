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
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetSupplierStatusList
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

    -- ── B. service vendor KYC requests not yet provisioned into kyc_basic_info ─
    INSERT INTO #s
    SELECT
        'SERVICE_KYC',
        v.service_vendor_kyc_sno,
        COALESCE(NULLIF(LTRIM(RTRIM(v.company_name)), ''), NULLIF(LTRIM(RTRIM(v.legal_name)), ''), NULLIF(LTRIM(RTRIM(v.trade_name)), '')),
        v.service_vendor_code,
        v.status,
        'Service Vendor',
        v.contact_person,
        v.email,
        v.mobile_number,
        v.gst_no,
        v.pan_no,
        COALESCE(bt.business_types_name, NULLIF(LTRIM(RTRIM(v.business_type)), '')),
        v.created_by,
        v.created_at,
        CASE WHEN v.status = 'P' THEN v.current_approver_id END,
        CASE WHEN v.status = 'P' THEN (
            SELECT TOP 1 CAST(st.[key] AS INT) + 1
            FROM dbo.workflow_stage ws
            CROSS APPLY OPENJSON(ws.stage_order_json) AS st
            WHERE ws.workflow_types_id = v.workflow_types_id AND ws.is_active = 'Y'
              AND JSON_VALUE(st.value, '$.approver_ecno') = v.current_approver_id
        ) END,
        (
            SELECT COUNT(*)
            FROM dbo.workflow_stage ws
            CROSS APPLY OPENJSON(ws.stage_order_json) AS st
            WHERE ws.workflow_types_id = v.workflow_types_id AND ws.is_active = 'Y'
        ),
        COALESCE(h.status_by, v.modified_by),
        COALESCE(h.created_date, v.modified_at)
    FROM dbo.service_vendor_kyc v
    LEFT JOIN dbo.business_types bt ON bt.business_types_id = TRY_CONVERT(INT, v.business_type)
    OUTER APPLY (
        SELECT TOP 1 status_by, created_date
        FROM dbo.service_vendor_kyc_history
        WHERE service_vendor_kyc_sno = v.service_vendor_kyc_sno AND is_active = 'Y'
        ORDER BY history_sno DESC
    ) h
    WHERE v.is_active = 'Y' AND v.kyc_basic_info_sno IS NULL;

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
GO

-- ── 2. sp_nt_GetSupplierStatusTimeline ──────────────────────────────────────
-- @source    'KYC' | 'SERVICE_KYC'
-- @record_id kyc_basic_info_sno  |  service_vendor_kyc_sno
-- Result sets: RS1 header (0 or 1 row), RS2 approval chain, RS3 what happened.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetSupplierStatusTimeline
    @source    VARCHAR(12),
    @record_id INT
AS
BEGIN
    SET NOCOUNT ON;

    -- A provisioned service vendor lives in kyc_basic_info but its approval trail (with
    -- comments) is in service_vendor_kyc_history — find the request that produced it.
    DECLARE @svk_sno INT = NULL;
    IF @source = 'SERVICE_KYC'
        SET @svk_sno = @record_id;
    ELSE
        SELECT TOP 1 @svk_sno = service_vendor_kyc_sno
        FROM dbo.service_vendor_kyc
        WHERE kyc_basic_info_sno = @record_id
        ORDER BY service_vendor_kyc_sno DESC;

    DECLARE @workflow_types_id INT, @status CHAR(1), @approver VARCHAR(50);
    IF @source = 'SERVICE_KYC'
        SELECT @workflow_types_id = workflow_types_id, @status = status, @approver = current_approver_id
        FROM dbo.service_vendor_kyc WHERE service_vendor_kyc_sno = @record_id;
    ELSE
        SELECT @workflow_types_id = COALESCE(k.workflow_types_id, sv.workflow_types_id),
               @status = k.status, @approver = k.approver_ecno
        FROM dbo.kyc_basic_info k
        LEFT JOIN dbo.service_vendor_kyc sv ON sv.service_vendor_kyc_sno = @svk_sno
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
        UNION SELECT created_by FROM dbo.service_vendor_kyc WHERE service_vendor_kyc_sno = @svk_sno
        UNION SELECT modified_by FROM dbo.service_vendor_kyc WHERE service_vendor_kyc_sno = @svk_sno
        UNION SELECT status_by FROM dbo.kyc_history WHERE @source = 'KYC' AND @svk_sno IS NULL AND kyc_basic_info_sno = @record_id
        UNION SELECT status_by FROM dbo.service_vendor_kyc_history WHERE service_vendor_kyc_sno = @svk_sno AND is_active = 'Y'
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
    IF @source = 'SERVICE_KYC'
        SELECT
            'SERVICE_KYC' AS source, v.service_vendor_kyc_sno AS record_id,
            COALESCE(NULLIF(LTRIM(RTRIM(v.company_name)), ''), v.legal_name, v.trade_name) AS company_name,
            v.legal_name, v.trade_name, v.service_vendor_code AS supp_code, v.status, 'Service Vendor' AS category,
            v.contact_person, v.email, v.mobile_number, v.gst_no, v.pan_no, v.msme_no,
            COALESCE(bt.business_types_name, NULLIF(LTRIM(RTRIM(v.business_type)), '')) AS business_type_name,
            v.created_by, pc.name AS created_by_name, v.created_at AS created_date,
            CASE WHEN v.status = 'P' THEN v.current_approver_id END AS current_approver_id,
            CASE WHEN v.status = 'P' THEN pa.name END AS current_approver_name,
            v.modified_by AS last_action_by, pl.name AS last_action_by_name, v.modified_at AS last_action_date
        FROM dbo.service_vendor_kyc v
        LEFT JOIN dbo.business_types bt ON bt.business_types_id = TRY_CONVERT(INT, v.business_type)
        LEFT JOIN #people pc ON pc.code = v.created_by
        LEFT JOIN #people pa ON pa.code = v.current_approver_id
        LEFT JOIN #people pl ON pl.code = v.modified_by
        WHERE v.service_vendor_kyc_sno = @record_id;
    ELSE
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

    -- RS3: what actually happened, oldest first. Service-vendor history carries comments;
    -- regular KYC history does not (see the header note).
    IF @svk_sno IS NOT NULL
        SELECT h.action_type AS event, h.status_by, p.name AS status_by_name, h.created_date AS event_date, h.comment
        FROM dbo.service_vendor_kyc_history h
        LEFT JOIN #people p ON p.code = h.status_by
        WHERE h.service_vendor_kyc_sno = @svk_sno AND h.is_active = 'Y'
        ORDER BY h.history_sno;
    ELSE
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

-- ============================================================
-- After running, confirm:
--   EXEC dbo.sp_nt_GetSupplierStatusList;
--   EXEC dbo.sp_nt_GetSupplierStatusTimeline @source = 'KYC', @record_id = 96;
--   EXEC dbo.sp_nt_GetSupplierStatusTimeline @source = 'KYC', @record_id = 112;  -- provisioned service vendor
-- ============================================================
