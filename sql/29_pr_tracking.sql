-- ============================================================
-- PR Requester Tracking — read-only aggregation layer
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : new backend-stpl/src/PRTracking module (Node)
--
-- IMPORTANT — nothing existing is touched. UAT is currently exercising
-- usp_InsertPurchaseRequest / sp_approve_pr_datas / the quotation and PO
-- approval procedures live, so this file creates ONLY brand-new objects
-- (no CREATE OR ALTER, no DROP+CREATE on anything that already exists) and
-- reads from existing tables/views without writing to any of them except
-- one new additive INSERT-only procedure (#1 below). Nothing here can change
-- the behaviour of a procedure UAT is currently mid-flow on.
--
-- Discovery note: pr_history_data (pr_basic_sno, pr_edit_data, is_active,
-- workflow_types_id, approver_ecno, status, status_by, status_date, commends,
-- pr_no) already exists live and is already populated by sp_approve_pr_datas
-- on every approve/reject — it was simply never checked into this repo's sql/
-- folder before now (same situation usp_InsertPurchaseRequest was in until
-- 06_usp_InsertPurchaseRequest_v2.sql). No new PR audit table is needed —
-- this file only reads it, via the existing vw_PR_Basic_Info view which
-- already nests it as JSON.
--
-- Contents:
--   1. sp_nt_LogPOSentToSupplier   — new, additive INSERT into the existing
--      po_history_data table. Call this from PurchaseTeamService.sendPOEmail
--      right after a successful send; today nothing logs that transition.
--   2. sp_nt_GetPRTrackingTimeline — new, one PR's full journey (PR header +
--      history, Quotation, PO + history, Dispatch, Gate Entry, GRN + history,
--      Inventory movements) as multiple result sets, all joined via
--      pr_basic_sno -> po_request_info.pr_basic_sno -> po_basic_sno, the same
--      FK chain every existing downstream table already uses.
--   3. sp_nt_GetMyPRTracking       — new, the caller's own PRs with a
--      computed current_stage, for a "My Requests" list.
--   4. sp_nt_GetOrgPRTracking      — new, pending/active PRs within an org
--      scope (com/div/brn/dept), for the permission-gated "Team / Org View".
--   5. sp_nt_GetPrNoByPoBasicSno   — new, tiny lookup so grn-service/PurchaseTeam
--      touch points (which only carry po_basic_sno) can resolve which
--      pr:track:{pr_no} room to broadcast into.
--   6. sp_nt_HasScreenPermission   — new, server-side check of the existing
--      screens/permissions grant, gating the "Team / Org View" endpoint.
--   7. Screens row for the new PRTrackingPage, same pattern as every prior
--      screen registration in this series (e.g.
--      24_service_bill_request_screens_and_backfill.sql) — reuses the
--      existing sp_nt_GrantScreenToUser, no new grant mechanism.
--
-- Deliberately NOT done: no org columns added to nt_gate_entry /
-- nt_dispatch_slip / nt_dispatch_slip_delivery / nt_transport_master — every
-- query below reaches them through po_basic_sno, which is already resolved
-- from a com/div/brn/dept-scoped pr_basic_info/po_request_info row.
-- ============================================================

-- ── 1. sp_nt_LogPOSentToSupplier ────────────────────────────────────────────
-- Additive audit row only. Never called in a way that can fail the actual
-- PO-send response — see PurchaseTeamService.sendPOEmail wiring.
CREATE OR ALTER PROCEDURE dbo.sp_nt_LogPOSentToSupplier
    @po_basic_sno INT,
    @status_by    VARCHAR(20),
    @comment      VARCHAR(250) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
    VALUES (@po_basic_sno, 'SENT_TO_SUPPLIER', @status_by, @comment, 'Y');

    SELECT 'LOGGED' AS result, @po_basic_sno AS po_basic_sno, SCOPE_IDENTITY() AS po_history_sno;
END;
GO

-- ── 2. sp_nt_GetPRTrackingTimeline ──────────────────────────────────────────
-- @pr_no accepts either the base pr_no ('PR26270008') or a split-group
-- display pr_no ('PR26270008/1'). Resolution is by pr_basic_sno; every
-- result set below returns ALL rows for that pr_basic_sno (all split groups
-- together, each row carrying its own identifying columns) rather than
-- trying to filter a specific split group out — simpler and safer than
-- string-matching split_pr_no everywhere, and the vast majority of PRs are
-- never split at all.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPRTrackingTimeline
    @pr_no VARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @base_pr_no VARCHAR(20) =
        LEFT(@pr_no, CASE WHEN CHARINDEX('/', @pr_no) > 0 THEN CHARINDEX('/', @pr_no) - 1 ELSE LEN(@pr_no) END);

    DECLARE @pr_basic_sno INT;
    SELECT @pr_basic_sno = pr_basic_sno
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

    -- RS1: PR header — reuses the existing view (org names, item details,
    -- workflow stage json, and pr_history_data already joined as JSON).
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

    -- RS5: PO history/audit trail (approve/reject/SENT_TO_SUPPLIER/etc.)
    SELECT phd.*
    FROM dbo.po_history_data phd
    WHERE phd.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    ORDER BY phd.po_history_sno;

    -- RS6: Supplier dispatch slips (transport/courier, LR no is on RS7)
    SELECT ds.*
    FROM dbo.nt_dispatch_slip ds
    WHERE ds.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    ORDER BY ds.created_at;

    -- RS7: Dispatch delivery lines (lr_no, invoice, qty/pieces/bundles)
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

    -- RS11: Inventory movements realized from this PR's GRN(s) — "Received
    -- Stock". reference_no is the FORMATTED display grn_no ('GRN-2026-000019'),
    -- not the raw int column — confirmed from sp_nt_CreateGRN's own final
    -- SELECT, which is what grn.service.js passes into
    -- InventoryService.receiveFromGRN as the reference. Must match exactly.
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
END;
GO

-- ── 3. sp_nt_GetMyPRTracking ────────────────────────────────────────────────
-- "My Requests" list: the caller's own PRs, most recent first, each with a
-- single computed current_stage label derived from its LATEST quotation/PO/
-- dispatch/gate-entry/GRN row. (The detail view — sp_nt_GetPRTrackingTimeline
-- — shows the full history; this is just the list-row summary.)
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

-- ── 4. sp_nt_GetOrgPRTracking ───────────────────────────────────────────────
-- "Team / Org View": pending/active PRs within a scope (excludes fully
-- Received Stock or Rejected ones). Same current_stage computation as #3,
-- scoped by org instead of by creator. div/brn/dept are optional narrowing —
-- NULL means "any" at that level, com_sno is always required.
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

-- ── 5. sp_nt_GetPrNoByPoBasicSno ────────────────────────────────────────────
-- Small lookup used by grn-service (dispatch/gate-entry/GRN touch points) and
-- backend-stpl (sendPOEmail) to resolve which pr:track:{pr_no} room to
-- broadcast into — those tables only carry po_basic_sno, not pr_no.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPrNoByPoBasicSno
    @po_basic_sno INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT pb.pr_no
    FROM dbo.po_request_info po
    INNER JOIN dbo.pr_basic_info pb ON pb.pr_basic_sno = po.pr_basic_sno
    WHERE po.po_basic_sno = @po_basic_sno;
END;
GO

-- ── 6. sp_nt_HasScreenPermission ────────────────────────────────────────────
-- Server-side enforcement for the "Team / Org View" tab: this codebase's
-- screens/permissions grant (nt_user_permissions_json.screens_json, written
-- by the existing sp_nt_GrantScreenToUser) otherwise only gates which menu
-- items the frontend renders — the grant itself must also be checked here,
-- or "role approval person can give access" would be UI-only, not real
-- access control. Every other DB touch point in this codebase goes through a
-- stored procedure (no ad hoc queries in Node repositories), so this stays
-- consistent with that rather than querying nt_user_permissions_json inline.
CREATE OR ALTER PROCEDURE dbo.sp_nt_HasScreenPermission
    @ecno          VARCHAR(20),
    @screen_comp   VARCHAR(100),
    @permission_id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @screens_json NVARCHAR(MAX);
    SELECT TOP 1 @screens_json = screens_json
    FROM dbo.nt_user_permissions_json
    WHERE ecno = @ecno AND is_active = 'Y'
    ORDER BY user_perm_json_sno DESC;

    SELECT CAST(
        CASE WHEN EXISTS (
            SELECT 1
            FROM OPENJSON(@screens_json) WITH (
                screen_id   INT           '$.screen_id',
                permissions NVARCHAR(MAX) '$.permissions' AS JSON
            ) s
            INNER JOIN dbo.screens sc ON sc.screen_id = s.screen_id AND sc.comp = @screen_comp
            CROSS APPLY OPENJSON(s.permissions) p
            WHERE TRY_CAST(p.value AS INT) = @permission_id
        ) THEN 1 ELSE 0 END
    AS BIT) AS has_permission;
END;
GO

-- ── 7. Screens row for the new page ─────────────────────────────────────────
-- Same group_id/screen_code family as its siblings Purchase Requisition
-- (screen_id 12, group_id=4, screen_code='S8') and PR Approval Screen
-- (screen_id 15, group_id=4, screen_code='S11') — verified live before
-- writing this via `SELECT * FROM dbo.screens WHERE comp LIKE '%PR%'`.
IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'PRTrackingPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'PR Tracking', 'S8', 'PRTrackingPage', 'Route', 4, 8, 'Y');
GO

-- ============================================================
-- After running, confirm:
--   EXEC dbo.sp_nt_GetMyPRTracking @ecno = 'KTM1148';
--   EXEC dbo.sp_nt_GetPRTrackingTimeline @pr_no = 'PR26270013';  -- or any live pr_no
--   SELECT screen_id FROM dbo.screens WHERE comp = 'PRTrackingPage';
--   -- grant, per user who needs access (View-only = "My Requests"; add
--   -- permission_id 7 = "Approve" to also unlock "Team / Org View"):
--   EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = N'{"ecno":"<ECNO>","screen_id":<id>,"permission_ids":[2]}';
-- ============================================================
