-- ── 2. sp_nt_GetSupplierStatusTimeline ──────────────────────────────────────
-- @source    'KYC'
-- @record_id kyc_basic_info_sno
-- Result sets: RS1 header (0 or 1 row), RS2 approval chain, RS3 what happened.
CREATE   PROCEDURE dbo.sp_nt_GetSupplierStatusTimeline
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