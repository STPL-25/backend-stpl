-- ============================================================
-- PR Tracking — surface approver NAMES and the full multi-stage chain
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Follow-up to sql/29_pr_tracking.sql, based on user feedback after the
-- first live walkthrough: the "PR Approval" stage only showed a generic
-- "Pending" status with no indication of WHO it's pending with, and no view
-- of the full approval chain (e.g. "Stage 1: KTM1148 -> Stage 2: KTM1006").
--
-- All 4 objects touched here are ones this feature itself created in file
-- 29 (not pre-existing/UAT procedures) — CREATE OR ALTER is safe, same as
-- every other proc in that file.
--
-- Root cause: the existing (pre-dates this feature, NOT touched)
-- vw_PR_Basic_Info.pr_history_data subquery omits status/approver_ecno/
-- ordering — it only has {status_by, ename, status_date, commends,
-- pr_edit_data}, no way to tell approve vs reject or which stage. Rather
-- than alter that view (also read by sp_get_pr_details_for_approval, which
-- UAT is actively using), this adds two new result sets to
-- sp_nt_GetPRTrackingTimeline that resolve the full stage chain (from
-- workflow_stage.stage_order_json) and the full ordered history (straight
-- from pr_history_data, not the view) independently.
-- ============================================================

-- ── 1. sp_nt_GetMyPRTracking — add current_approver_name ───────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetMyPRTracking
    @ecno VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        pbf.pr_basic_sno,
        pbf.pr_no,
        pbf.status                 AS pr_status,
        pbf.purpose,
        pbf.required_date,
        pbf.created_date,
        vadr.com_name, vadr.div_name, vadr.brn_name, vadr.dept_name,
        pbf.current_approver_id,
        vve_approver.ename         AS current_approver_name,
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
            WHEN sq.sq_basic_sno IS NOT NULL                                               THEN 'Purchase Quotation'
            WHEN pbf.status = 'A'                                                          THEN 'PR Approved — Awaiting Quotation/PO'
            WHEN pbf.status = 'R'                                                          THEN 'PR Rejected'
            ELSE 'PR Approval Pending'
        END AS current_stage
    FROM dbo.pr_basic_info pbf
    INNER JOIN dbo.vw_ActiveDeptRecords vadr
        ON pbf.brn_sno = vadr.brn_sno AND pbf.dept_sno = vadr.dept_sno
    LEFT JOIN dbo.vw_verified_employees vve_approver
        ON vve_approver.ecno = pbf.current_approver_id
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.supplier_quotation_info
        WHERE pr_basic_sno = pbf.pr_basic_sno ORDER BY sq_basic_sno DESC
    ) sq
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
    ORDER BY pbf.created_date DESC, pbf.pr_basic_sno DESC;
END;
GO

-- ── 2. sp_nt_GetOrgPRTracking — add current_approver_name ──────────────────
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
            pbf.current_approver_id,
            vve_approver.ename         AS current_approver_name,
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
        LEFT JOIN dbo.vw_verified_employees vve_approver
            ON vve_approver.ecno = pbf.current_approver_id
        OUTER APPLY (
            SELECT TOP 1 * FROM dbo.supplier_quotation_info
            WHERE pr_basic_sno = pbf.pr_basic_sno ORDER BY sq_basic_sno DESC
        ) sq
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
    SELECT * FROM PRList
    WHERE current_stage NOT IN ('Received Stock', 'PR Rejected')
    ORDER BY created_date DESC, pr_basic_sno DESC;
END;
GO

-- ── 3. sp_nt_GetPRTrackingTimeline — add stage chain + full ordered history ─
-- Same 11 result sets as before (unchanged), PLUS two new ones at the end:
--   RS12: the PR's full approval STAGE CHAIN (stage_no, stage_name,
--         approver_ecno, approver_name, is_mandatory, required_approvals),
--         resolved from workflow_stage.stage_order_json — generic for any
--         number of stages, any approvers.
--   RS13: the full ORDERED pr_history_data audit trail, with approver name
--         and status included (the existing vw_PR_Basic_Info JSON omits
--         both) — lets the frontend match each stage to what actually
--         happened at it.
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

    -- RS1: PR header
    SELECT * FROM dbo.vw_PR_Basic_Info WHERE pr_basic_sno = @pr_basic_sno;

    -- RS2: Purchase Quotation header rows
    SELECT * FROM dbo.supplier_quotation_info
    WHERE pr_basic_sno = @pr_basic_sno
    ORDER BY created_date, sq_basic_sno;

    -- RS3: Purchase Quotation history/audit trail
    SELECT sqh.*
    FROM dbo.supplier_quotation_history sqh
    WHERE sqh.pr_basic_sno = @pr_basic_sno
    ORDER BY sqh.sq_history_sno;

    -- RS4: PO header rows
    SELECT * FROM dbo.po_request_info
    WHERE pr_basic_sno = @pr_basic_sno
    ORDER BY po_date, po_basic_sno;

    -- RS5: PO history/audit trail
    SELECT phd.*
    FROM dbo.po_history_data phd
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

    -- RS8: Gate Entry
    SELECT ge.*
    FROM dbo.nt_gate_entry ge
    WHERE ge.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    ORDER BY ge.created_at;

    -- RS9: GRN header rows
    SELECT g.*
    FROM dbo.grn_basic_info g
    WHERE g.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    ORDER BY g.created_date;

    -- RS10: GRN history/audit trail
    SELECT gh.*
    FROM dbo.grn_history_data gh
    WHERE gh.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    ORDER BY gh.status_at;

    -- RS11: Inventory movements
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

    -- RS12: Full PR approval stage chain, in order, with resolved names.
    SELECT
        CAST(s.[key] AS INT) + 1                AS stage_no,
        JSON_VALUE(s.value, '$.stage')           AS stage_name,
        JSON_VALUE(s.value, '$.approver_ecno')   AS approver_ecno,
        vve.ename                                AS approver_name,
        JSON_VALUE(s.value, '$.is_mandatory')    AS is_mandatory,
        JSON_VALUE(s.value, '$.required_approvals') AS required_approvals
    FROM dbo.workflow_stage ws
    CROSS APPLY OPENJSON(ws.stage_order_json) AS s
    LEFT JOIN dbo.vw_verified_employees vve
        ON vve.ecno = JSON_VALUE(s.value, '$.approver_ecno')
    WHERE ws.workflow_types_id = @workflow_types_id
      AND ws.is_active = 'Y'
    ORDER BY stage_no;

    -- RS13: Full ordered pr_history_data audit trail, with approver name and
    -- status included (the existing vw_PR_Basic_Info JSON has neither).
    SELECT
        phd.pr_history_sno,
        phd.approver_ecno,
        phd.status_by,
        vve.ename AS status_by_name,
        phd.status,
        phd.status_date,
        phd.commends
    FROM dbo.pr_history_data phd
    LEFT JOIN dbo.vw_verified_employees vve ON vve.ecno = phd.status_by
    WHERE phd.pr_basic_sno = @pr_basic_sno
    ORDER BY phd.pr_history_sno;
END;
GO
