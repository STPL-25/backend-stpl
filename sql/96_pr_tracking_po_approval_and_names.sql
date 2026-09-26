-- ============================================================
-- PR Tracking — show the PO-approval stage and WHO everyone is, end to end.
-- Database : Non_trade_Dev (re-runnable; same objects exist in Non_Trade)
--
-- Request (2026-09-24): once a PR is raised the requester should see what stage
-- it is at, who has approved it (with their comment), and the approvals still
-- to come — through PO raised, Gate Entry and GRN.
--
-- What sql/29 + sql/30 already gave the timeline: the PR's own approval chain
-- and history (with comments), and the Quotation / PO / Dispatch / Gate Entry /
-- GRN / Inventory rows. What was missing:
--
--   1. The approval that sits BETWEEN "PR approved" and "PO raised". In this
--      system a PO is not approved on its own: the Purchase team selects a
--      supplier quotation and THAT goes through an approval chain
--      (supplier_quotation_info.workflow_types_id -> workflow_stage), and on
--      the last approval sp_nt_ApproveSupplierQuotation creates the PO
--      (history row PO_CREATED, "PO STPL… auto-generated"). The timeline showed
--      only raw quotation history rows — no chain, no "pending with", no names.
--      -> new RS14 (stage chain per quotation workflow) + names on RS2/RS3.
--
--   2. Names. RS12/RS13 resolved approver names through vw_verified_employees
--      only, so a NON-STAFF approver (e.g. ED001 on the KYC/PO workflows) showed
--      as a bare code. Every name now resolves staff first, then
--      nt_nonstaff_login.full_name (same COALESCE as sql/33). Gate-entry /
--      GRN / PO-history actors get names too.
--
--   3. The list screens ("My Requests" / "Team / Org View") said "PR approval
--      pending" with the approver's name only while the PR itself was pending.
--      Once the PR was approved and the quotation was waiting on an approver
--      the row just said "Purchase Quotation" with nobody named. It now says
--      "PO Approval" and "with <approver>".
--
-- All names come from ONE small temp table (#people) filled once per call,
-- rather than joining the cross-database vw_verified_employees view in every
-- result set.
--
-- Result-set order of sp_nt_GetPRTrackingTimeline is APPENDED to, never
-- reordered: RS1..RS13 keep their positions (columns are only added), RS14 =
-- quotation approval chains, RS15 = PR core row. The Node service destructures
-- by position, so it must be updated together with this file.
--
-- Only objects this feature created are touched (CREATE OR ALTER). Nothing the
-- approval / PO procedures depend on changes.
-- ============================================================

-- ── 1. sp_nt_GetPRTrackingTimeline ──────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPRTrackingTimeline
    @pr_no VARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @base_pr_no VARCHAR(20) =
        LEFT(@pr_no, CASE WHEN CHARINDEX('/', @pr_no) > 0 THEN CHARINDEX('/', @pr_no) - 1 ELSE LEN(@pr_no) END);

    DECLARE @pr_basic_sno INT, @workflow_types_id INT;
    SELECT @pr_basic_sno = pr_basic_sno, @workflow_types_id = workflow_types_id
    FROM dbo.pr_basic_info
    WHERE pr_no = @base_pr_no AND is_active = 'Y';

    IF @pr_basic_sno IS NULL
    BEGIN
        SELECT CAST(NULL AS INT) AS pr_basic_sno WHERE 1 = 0;
        RETURN;
    END

    DECLARE @poIds TABLE (po_basic_sno INT PRIMARY KEY);
    INSERT INTO @poIds (po_basic_sno)
    SELECT po_basic_sno FROM dbo.po_request_info WHERE pr_basic_sno = @pr_basic_sno;

    -- Workflow types whose stage chains the caller needs: the PR's own, plus every
    -- one a quotation of this PR was routed through.
    DECLARE @sqWorkflows TABLE (workflow_types_id INT PRIMARY KEY);
    INSERT INTO @sqWorkflows (workflow_types_id)
    SELECT DISTINCT workflow_types_id
    FROM dbo.supplier_quotation_info
    WHERE pr_basic_sno = @pr_basic_sno AND workflow_types_id IS NOT NULL;

    -- ── #people: every person code that appears below -> a display name ───────
    -- COLLATE DATABASE_DEFAULT: temp tables take tempdb's collation, which can differ from this
    -- database's and would raise a collation-conflict error when joined to its columns.
    CREATE TABLE #codes (code VARCHAR(50) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
    INSERT INTO #codes (code)
    SELECT DISTINCT LTRIM(RTRIM(c)) FROM (
        SELECT created_by          AS c FROM dbo.pr_basic_info          WHERE pr_basic_sno = @pr_basic_sno
        UNION SELECT current_approver_id FROM dbo.pr_basic_info         WHERE pr_basic_sno = @pr_basic_sno
        UNION SELECT approver_ecno       FROM dbo.pr_history_data       WHERE pr_basic_sno = @pr_basic_sno
        UNION SELECT status_by           FROM dbo.pr_history_data       WHERE pr_basic_sno = @pr_basic_sno
        UNION SELECT JSON_VALUE(s.value, '$.approver_ecno')
              FROM dbo.workflow_stage ws
              CROSS APPLY OPENJSON(ws.stage_order_json) AS s
              WHERE ws.is_active = 'Y'
                AND (ws.workflow_types_id = @workflow_types_id
                     OR ws.workflow_types_id IN (SELECT workflow_types_id FROM @sqWorkflows))
        UNION SELECT created_by          FROM dbo.supplier_quotation_info WHERE pr_basic_sno = @pr_basic_sno
        UNION SELECT approver_ecno       FROM dbo.supplier_quotation_info WHERE pr_basic_sno = @pr_basic_sno
        UNION SELECT transferred_from    FROM dbo.supplier_quotation_info WHERE pr_basic_sno = @pr_basic_sno
        UNION SELECT transferred_to      FROM dbo.supplier_quotation_info WHERE pr_basic_sno = @pr_basic_sno
        UNION SELECT approver_ecno       FROM dbo.supplier_quotation_history WHERE pr_basic_sno = @pr_basic_sno
        UNION SELECT status_by           FROM dbo.supplier_quotation_history WHERE pr_basic_sno = @pr_basic_sno
        UNION SELECT selected_by         FROM dbo.supplier_quotation_history WHERE pr_basic_sno = @pr_basic_sno
        UNION SELECT transferred_from    FROM dbo.supplier_quotation_history WHERE pr_basic_sno = @pr_basic_sno
        UNION SELECT transferred_to      FROM dbo.supplier_quotation_history WHERE pr_basic_sno = @pr_basic_sno
        UNION SELECT current_approver_id FROM dbo.po_request_info       WHERE pr_basic_sno = @pr_basic_sno
        UNION SELECT approver_ecno       FROM dbo.po_history_data       WHERE po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
        UNION SELECT status_by           FROM dbo.po_history_data       WHERE po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
        UNION SELECT created_by          FROM dbo.nt_gate_entry         WHERE po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
        UNION SELECT receiver_ecno       FROM dbo.nt_gate_entry         WHERE po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
        UNION SELECT created_by          FROM dbo.grn_basic_info        WHERE po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
        UNION SELECT status_by           FROM dbo.grn_history_data      WHERE po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    ) x
    WHERE c IS NOT NULL AND LTRIM(RTRIM(c)) <> '';

    CREATE TABLE #people (code VARCHAR(50) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, name NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL);
    INSERT INTO #people (code, name)
    SELECT c.code,
           MAX(COALESCE(NULLIF(LTRIM(RTRIM(e.ename)), ''), ns.full_name)) AS name
    FROM #codes c
    LEFT JOIN dbo.vw_verified_employees e ON e.ecno = c.code
    LEFT JOIN dbo.nt_nonstaff_login ns   ON ns.login_id = c.code
    GROUP BY c.code;

    -- RS1: PR header
    SELECT * FROM dbo.vw_PR_Basic_Info WHERE pr_basic_sno = @pr_basic_sno;

    -- RS2: Purchase Quotation header rows (+ supplier name, who submitted it, who it is with now)
    SELECT sq.*, pc.name AS created_by_name, pa.name AS approver_name, k.company_name AS vendor_name
    FROM dbo.supplier_quotation_info sq
    LEFT JOIN #people pc ON pc.code = sq.created_by
    LEFT JOIN #people pa ON pa.code = sq.approver_ecno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sq.vendor_sno
    WHERE sq.pr_basic_sno = @pr_basic_sno
    ORDER BY sq.created_date, sq.sq_basic_sno;

    -- RS3: Purchase Quotation history / audit trail (+ names)
    SELECT sqh.*, pb.name AS status_by_name, pa.name AS approver_name, pt.name AS transferred_to_name
    FROM dbo.supplier_quotation_history sqh
    LEFT JOIN #people pb ON pb.code = sqh.status_by
    LEFT JOIN #people pa ON pa.code = sqh.approver_ecno
    LEFT JOIN #people pt ON pt.code = sqh.transferred_to
    WHERE sqh.pr_basic_sno = @pr_basic_sno
    ORDER BY sqh.sq_history_sno;

    -- RS4: PO header rows (+ supplier name, who it is with if still moving)
    SELECT po.*, pc.name AS current_approver_name, k.company_name AS vendor_name
    FROM dbo.po_request_info po
    LEFT JOIN #people pc ON pc.code = po.current_approver_id
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = po.vendor_sno
    WHERE po.pr_basic_sno = @pr_basic_sno
    ORDER BY po.po_date, po.po_basic_sno;

    -- RS5: PO history / audit trail (+ names)
    SELECT phd.*, pb.name AS status_by_name
    FROM dbo.po_history_data phd
    LEFT JOIN #people pb ON pb.code = phd.status_by
    WHERE phd.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    ORDER BY phd.po_history_sno;

    -- RS6: Supplier dispatch slips
    SELECT ds.*
    FROM dbo.nt_dispatch_slip ds
    WHERE ds.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    ORDER BY ds.created_at;

    -- RS7: Dispatch delivery lines
    SELECT dd.*
    FROM dbo.nt_dispatch_slip_delivery dd
    WHERE dd.dispatch_slip_sno IN (
        SELECT dispatch_slip_sno FROM dbo.nt_dispatch_slip
        WHERE po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    )
    ORDER BY dd.created_at;

    -- RS8: Gate Entry (+ who received / logged it)
    SELECT ge.*, pr.name AS receiver_name, pc.name AS created_by_name
    FROM dbo.nt_gate_entry ge
    LEFT JOIN #people pr ON pr.code = ge.receiver_ecno
    LEFT JOIN #people pc ON pc.code = ge.created_by
    WHERE ge.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    ORDER BY ge.created_at;

    -- RS9: GRN header rows (+ who posted it, and the formatted GRN reference that
    -- nt_stock_movements.reference_no uses — see RS11)
    SELECT g.*,
           pc.name AS created_by_name,
           CASE WHEN g.grn_no IS NULL THEN NULL
                ELSE 'GRN-' + CAST(YEAR(g.created_date) AS VARCHAR(4)) + '-'
                     + RIGHT('000000' + CAST(g.grn_no AS VARCHAR(6)), 6)
           END AS grn_ref
    FROM dbo.grn_basic_info g
    LEFT JOIN #people pc ON pc.code = g.created_by
    WHERE g.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    ORDER BY g.created_date;

    -- RS10: GRN history / audit trail (+ names)
    SELECT gh.*, pb.name AS status_by_name
    FROM dbo.grn_history_data gh
    LEFT JOIN #people pb ON pb.code = gh.status_by
    WHERE gh.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    ORDER BY gh.status_at;

    -- RS11: Inventory movements realized from this PR's GRN(s) — "Received Stock"
    SELECT sm.*
    FROM dbo.nt_stock_movements sm
    WHERE sm.reference_no IN (
        SELECT 'GRN-' + CAST(YEAR(g.created_date) AS VARCHAR(4)) + '-'
                + RIGHT('000000' + CAST(g.grn_no AS VARCHAR(6)), 6)
        FROM dbo.grn_basic_info g
        WHERE g.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
          AND g.grn_no IS NOT NULL
    )
    ORDER BY sm.created_at;

    -- RS12: the PR's own approval stage chain, in order, with names
    SELECT
        CAST(s.[key] AS INT) + 1                    AS stage_no,
        JSON_VALUE(s.value, '$.stage')               AS stage_name,
        JSON_VALUE(s.value, '$.approver_ecno')       AS approver_ecno,
        p.name                                       AS approver_name,
        JSON_VALUE(s.value, '$.is_mandatory')        AS is_mandatory,
        JSON_VALUE(s.value, '$.required_approvals')  AS required_approvals
    FROM dbo.workflow_stage ws
    CROSS APPLY OPENJSON(ws.stage_order_json) AS s
    LEFT JOIN #people p ON p.code = JSON_VALUE(s.value, '$.approver_ecno')
    WHERE ws.workflow_types_id = @workflow_types_id
      AND ws.is_active = 'Y'
    ORDER BY stage_no;

    -- RS13: the PR's full ordered approval history — who, what, when, and the comment
    SELECT
        phd.pr_history_sno,
        phd.approver_ecno,
        phd.status_by,
        p.name AS status_by_name,
        phd.status,
        phd.status_date,
        phd.commends
    FROM dbo.pr_history_data phd
    LEFT JOIN #people p ON p.code = phd.status_by
    WHERE phd.pr_basic_sno = @pr_basic_sno
    ORDER BY phd.pr_history_sno;

    -- RS14 (new): the approval chain(s) the PR's quotations were routed through —
    -- this is the "PO approval": the last approver's sign-off raises the PO.
    SELECT
        ws.workflow_types_id,
        CAST(s.[key] AS INT) + 1                    AS stage_no,
        JSON_VALUE(s.value, '$.stage')               AS stage_name,
        JSON_VALUE(s.value, '$.approver_ecno')       AS approver_ecno,
        p.name                                       AS approver_name,
        JSON_VALUE(s.value, '$.can_forward')         AS can_forward
    FROM dbo.workflow_stage ws
    CROSS APPLY OPENJSON(ws.stage_order_json) AS s
    LEFT JOIN #people p ON p.code = JSON_VALUE(s.value, '$.approver_ecno')
    WHERE ws.workflow_types_id IN (SELECT workflow_types_id FROM @sqWorkflows)
      AND ws.is_active = 'Y'
    ORDER BY ws.workflow_types_id, stage_no;

    -- RS15 (new): the PR row itself — status and who it is with RIGHT NOW
    SELECT
        pb.pr_basic_sno, pb.pr_no, pb.status, pb.workflow_types_id,
        pb.current_approver_id, pa.name AS current_approver_name,
        pb.created_by, pc.name AS created_by_name, pb.created_date
    FROM dbo.pr_basic_info pb
    LEFT JOIN #people pa ON pa.code = pb.current_approver_id
    LEFT JOIN #people pc ON pc.code = pb.created_by
    WHERE pb.pr_basic_sno = @pr_basic_sno;

    DROP TABLE #people;
    DROP TABLE #codes;
END;
GO

-- ── 2. sp_nt_GetMyPRTracking ────────────────────────────────────────────────
-- Same columns as before. New: while the PR is approved but its quotation is
-- waiting on an approver, current_stage = 'PO Approval' and current_approver_*
-- name that approver (previously "Purchase Quotation", nobody named). Names now
-- fall back to nt_nonstaff_login.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetMyPRTracking
    @ecno VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH PRList AS (
        SELECT
            pbf.pr_basic_sno,
            pbf.pr_no,
            pbf.status                 AS pr_status,
            pbf.purpose,
            pbf.required_date,
            pbf.created_date,
            vadr.com_name, vadr.div_name, vadr.brn_name, vadr.dept_name,
            COALESCE(pbf.current_approver_id,
                     CASE WHEN po.po_basic_sno IS NULL THEN sqa.approver_ecno END) AS current_approver_id,
            sq.sq_basic_sno,
            sq.status                  AS quotation_status,
            po.po_basic_sno,
            po.status                  AS po_status,
            po.supplier_ack_status,
            po.po_pdf_url,
            ds.dispatch_slip_sno,
            ge.gate_entry_sno,
            ge.status                  AS gate_entry_status,
            grn.grn_basic_sno,
            grn.status                 AS grn_status,
            CASE
                WHEN grn.grn_basic_sno IS NOT NULL AND grn.status IN ('Received', 'Partial') THEN 'Received Stock'
                WHEN grn.grn_basic_sno IS NOT NULL                                            THEN 'GRN'
                WHEN ge.gate_entry_sno IS NOT NULL                                             THEN 'Gate Entry'
                WHEN ds.dispatch_slip_sno IS NOT NULL                                          THEN 'Dispatched'
                WHEN po.po_basic_sno IS NOT NULL AND po.status = 'A'                           THEN 'PO Sent / In Transit'
                WHEN po.po_basic_sno IS NOT NULL                                               THEN 'PO Approval'
                WHEN sqa.approver_ecno IS NOT NULL                                             THEN 'PO Approval'
                WHEN sq.sq_basic_sno IS NOT NULL                                               THEN 'Purchase Quotation'
                WHEN pbf.status = 'A'                                                          THEN 'PR Approved — Awaiting Quotation/PO'
                WHEN pbf.status = 'R'                                                          THEN 'PR Rejected'
                ELSE 'PR Approval Pending'
            END AS current_stage
        FROM dbo.pr_basic_info pbf
        INNER JOIN dbo.vw_ActiveDeptRecords vadr
            ON pbf.brn_sno = vadr.brn_sno AND pbf.dept_sno = vadr.dept_sno
        OUTER APPLY (
            SELECT TOP 1 * FROM dbo.supplier_quotation_info
            WHERE pr_basic_sno = pbf.pr_basic_sno ORDER BY sq_basic_sno DESC
        ) sq
        OUTER APPLY (
            SELECT TOP 1 approver_ecno FROM dbo.supplier_quotation_info
            WHERE pr_basic_sno = pbf.pr_basic_sno AND status = 'P' AND approver_ecno IS NOT NULL
            ORDER BY sq_basic_sno DESC
        ) sqa
        OUTER APPLY (
            SELECT TOP 1 * FROM dbo.po_request_info
            WHERE pr_basic_sno = pbf.pr_basic_sno ORDER BY po_basic_sno DESC
        ) po
        OUTER APPLY (
            SELECT TOP 1 * FROM dbo.nt_dispatch_slip
            WHERE po_basic_sno = po.po_basic_sno ORDER BY dispatch_slip_sno DESC
        ) ds
        OUTER APPLY (
            SELECT TOP 1 * FROM dbo.nt_gate_entry
            WHERE po_basic_sno = po.po_basic_sno ORDER BY gate_entry_sno DESC
        ) ge
        OUTER APPLY (
            SELECT TOP 1 * FROM dbo.grn_basic_info
            WHERE po_basic_sno = po.po_basic_sno ORDER BY grn_basic_sno DESC
        ) grn
        WHERE pbf.created_by = @ecno AND pbf.is_active = 'Y'
    )
    SELECT
        r.*,
        COALESCE(NULLIF(LTRIM(RTRIM(ea.ename)), ''), nsa.full_name) AS current_approver_name
    FROM PRList r
    LEFT JOIN dbo.vw_verified_employees ea ON ea.ecno = r.current_approver_id
    LEFT JOIN dbo.nt_nonstaff_login nsa    ON nsa.login_id = r.current_approver_id
    ORDER BY r.created_date DESC, r.pr_basic_sno DESC;
END;
GO

-- ── 3. sp_nt_GetOrgPRTracking ───────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetOrgPRTracking
    @com_sno  INT,
    @div_sno  INT = NULL,
    @brn_sno  INT = NULL,
    @dept_sno INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH PRList AS (
        SELECT
            pbf.pr_basic_sno,
            pbf.pr_no,
            pbf.status                 AS pr_status,
            pbf.purpose,
            pbf.required_date,
            pbf.created_date,
            pbf.created_by,
            vve.ename                  AS created_by_name,
            COALESCE(pbf.current_approver_id,
                     CASE WHEN po.po_basic_sno IS NULL THEN sqa.approver_ecno END) AS current_approver_id,
            vadr.com_name, vadr.div_name, vadr.brn_name, vadr.dept_name,
            sq.sq_basic_sno,
            sq.status                  AS quotation_status,
            po.po_basic_sno,
            po.status                  AS po_status,
            po.supplier_ack_status,
            ds.dispatch_slip_sno,
            ge.gate_entry_sno,
            ge.status                  AS gate_entry_status,
            grn.grn_basic_sno,
            grn.status                 AS grn_status,
            CASE
                WHEN grn.grn_basic_sno IS NOT NULL AND grn.status IN ('Received', 'Partial') THEN 'Received Stock'
                WHEN grn.grn_basic_sno IS NOT NULL                                            THEN 'GRN'
                WHEN ge.gate_entry_sno IS NOT NULL                                             THEN 'Gate Entry'
                WHEN ds.dispatch_slip_sno IS NOT NULL                                          THEN 'Dispatched'
                WHEN po.po_basic_sno IS NOT NULL AND po.status = 'A'                           THEN 'PO Sent / In Transit'
                WHEN po.po_basic_sno IS NOT NULL                                               THEN 'PO Approval'
                WHEN sqa.approver_ecno IS NOT NULL                                             THEN 'PO Approval'
                WHEN sq.sq_basic_sno IS NOT NULL                                               THEN 'Purchase Quotation'
                WHEN pbf.status = 'A'                                                          THEN 'PR Approved — Awaiting Quotation/PO'
                WHEN pbf.status = 'R'                                                          THEN 'PR Rejected'
                ELSE 'PR Approval Pending'
            END AS current_stage
        FROM dbo.pr_basic_info pbf
        INNER JOIN dbo.vw_ActiveDeptRecords vadr
            ON pbf.brn_sno = vadr.brn_sno AND pbf.dept_sno = vadr.dept_sno
        INNER JOIN dbo.vw_verified_employees vve
            ON pbf.created_by = vve.ecno
        OUTER APPLY (
            SELECT TOP 1 * FROM dbo.supplier_quotation_info
            WHERE pr_basic_sno = pbf.pr_basic_sno ORDER BY sq_basic_sno DESC
        ) sq
        OUTER APPLY (
            SELECT TOP 1 approver_ecno FROM dbo.supplier_quotation_info
            WHERE pr_basic_sno = pbf.pr_basic_sno AND status = 'P' AND approver_ecno IS NOT NULL
            ORDER BY sq_basic_sno DESC
        ) sqa
        OUTER APPLY (
            SELECT TOP 1 * FROM dbo.po_request_info
            WHERE pr_basic_sno = pbf.pr_basic_sno ORDER BY po_basic_sno DESC
        ) po
        OUTER APPLY (
            SELECT TOP 1 * FROM dbo.nt_dispatch_slip
            WHERE po_basic_sno = po.po_basic_sno ORDER BY dispatch_slip_sno DESC
        ) ds
        OUTER APPLY (
            SELECT TOP 1 * FROM dbo.nt_gate_entry
            WHERE po_basic_sno = po.po_basic_sno ORDER BY gate_entry_sno DESC
        ) ge
        OUTER APPLY (
            SELECT TOP 1 * FROM dbo.grn_basic_info
            WHERE po_basic_sno = po.po_basic_sno ORDER BY grn_basic_sno DESC
        ) grn
        WHERE pbf.is_active = 'Y'
          AND pbf.com_sno  = @com_sno
          AND (@div_sno  IS NULL OR pbf.div_sno  = @div_sno)
          AND (@brn_sno  IS NULL OR pbf.brn_sno  = @brn_sno)
          AND (@dept_sno IS NULL OR pbf.dept_sno = @dept_sno)
    )
    SELECT
        r.*,
        COALESCE(NULLIF(LTRIM(RTRIM(ea.ename)), ''), nsa.full_name) AS current_approver_name
    FROM PRList r
    LEFT JOIN dbo.vw_verified_employees ea ON ea.ecno = r.current_approver_id
    LEFT JOIN dbo.nt_nonstaff_login nsa    ON nsa.login_id = r.current_approver_id
    WHERE r.current_stage NOT IN ('Received Stock', 'PR Rejected')
    ORDER BY r.created_date DESC, r.pr_basic_sno DESC;
END;
GO

-- ============================================================
-- After running, confirm:
--   EXEC dbo.sp_nt_GetPRTrackingTimeline @pr_no = 'PR26270026';   -- a PR that reached GRN
--   EXEC dbo.sp_nt_GetMyPRTracking @ecno = 'KTM1148';
-- ============================================================
