-- ============================================================
-- sp_nt_GetPrLineRoutingStatus — per-PR-line downstream routing status
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : new GET /api/pr/getPrLineRoutingStatus/:pr_basic_sno
--            (backend-stpl/src/PR/{routes,controller,service,repository}.js)
--
-- Why this is needed
-- ------------------
-- No existing view/proc ties a PR line forward to its downstream status —
-- vw_PR_Basic_Info (06b_vw_pr_basic_info_service_lines.sql, extended for
-- category in 18_pr_category_and_source_invoice.sql) returns the PR's own
-- item list but nothing about what happened to each line afterward. This
-- closes that gap with a single new SP rather than a cross-service Node
-- composition, since backend-stpl and grn-service share one physical
-- database (verified: same SERVER/DATABASE in both .env files) — GRN and
-- Service Entry tables are reachable from a backend-stpl stored procedure
-- exactly like any other table here.
--
-- Join path (confirmed live before writing this):
--   pr_item_details.pr_item_sno -> po_item_details.pr_item_sno
--     (po_section 'MATERIAL' or 'SERVICE' disambiguates which side to follow)
--   MATERIAL: po_item_details.po_item_sno -> grn_item_details.po_item_sno
--     (NOT nt_grn_item_details — this repo has two parallel GRN table sets;
--     nt_grn_basic_info/nt_grn_item_details is a stale, abandoned earlier
--     iteration frozen at po_basic_sno<=37 with no created_date column at
--     all, while grn_basic_info/grn_item_details is the one sp_nt_CreateGRN
--     (grn-service/sql/07_grn_procs_v2.sql) actually inserts into today
--     (confirmed: max created_date 2026-08-20, po_basic_sno range covers the
--     latest PO #40). sp_nt_MatchInvoiceBucket (grn-service/sql/13_invoice.sql)
--     already correctly uses the no-prefix table — this SP now matches it.
--   SERVICE:  po_item_details.po_item_sno -> service_entry_item_details.po_item_sno
--             -> service_entry_info (for status/variance_status)
--
-- Deliberately returns raw joined facts (PO status, GRN receipt totals,
-- Service Entry status/variance) rather than collapsing them into one
-- computed "routing_status" label in SQL — the frontend panel decides how to
-- word/badge that, and this keeps the SP reusable if the labeling changes.
-- ============================================================

IF OBJECT_ID('dbo.sp_nt_GetPrLineRoutingStatus', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPrLineRoutingStatus;
GO

CREATE PROCEDURE dbo.sp_nt_GetPrLineRoutingStatus
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @pr_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT);

    IF @pr_basic_sno IS NULL
        THROW 61001, 'pr_basic_sno is required.', 1;

    SELECT
        pid.pr_item_sno,
        pid.item_type,
        pid.prod_sno,
        pid.service_sno,
        pid.qty,
        pid.total_cost,

        poi.po_item_sno,
        poi.po_section,
        po.po_basic_sno,
        po.po_df_no                AS po_no,
        po.status                  AS po_status,
        po.po_type,

        -- MATERIAL: receipt totals across every GRN line raised against this PO line
        JSON_QUERY((
            SELECT
                COUNT(DISTINCT g.grn_basic_sno)      AS grn_count,
                SUM(g.received_qty)                  AS total_received_qty,
                SUM(g.rejected_qty)                  AS total_rejected_qty
            FROM dbo.grn_item_details g
            WHERE g.po_item_sno = poi.po_item_sno
              AND g.is_active = 'Y'
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        )) AS grn_summary,

        -- SERVICE: every Service Entry raised against this PO line, with its
        -- own approval/variance status (a line can have more than one entry
        -- over time, e.g. monthly rent confirmations)
        JSON_QUERY((
            SELECT
                se.service_entry_sno,
                se.service_entry_no,
                se.status,
                se.variance_status,
                se.variance_pct,
                sei.billed_qty,
                sei.confirmed_amount
            FROM dbo.service_entry_item_details sei
            INNER JOIN dbo.service_entry_info se
                ON se.service_entry_sno = sei.service_entry_sno
            WHERE sei.po_item_sno = poi.po_item_sno
              AND sei.is_active = '1'
            ORDER BY se.created_date DESC
            FOR JSON PATH
        )) AS service_entry_summary

    FROM dbo.pr_item_details pid
    LEFT JOIN dbo.po_item_details poi
        ON poi.pr_item_sno = pid.pr_item_sno
    LEFT JOIN dbo.po_request_info po
        ON po.po_basic_sno = poi.po_basic_sno
    WHERE pid.pr_basic_sno = @pr_basic_sno
      AND pid.is_active = 'Y'
    ORDER BY pid.pr_item_sno
    FOR JSON PATH;
END;
GO

-- ============================================================
-- After running, confirm:
--   EXEC dbo.sp_nt_GetPrLineRoutingStatus @jsonInput = N'{"pr_basic_sno":<a real, approved pr_basic_sno>}';
-- A line with no po_item_details match yet (PR approved, not yet POed)
-- returns po_item_sno/po_basic_sno/... all NULL — the frontend panel should
-- treat that as "pending PO" rather than an error.
-- ============================================================
