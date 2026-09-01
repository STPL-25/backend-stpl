-- ============================================================
-- Service Bill Request screens + recurrence_cadence_sno backfill
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : nt-frontend-stpl SideBar.tsx (screens table), new
--            backend-stpl/src/ServiceBillRequest module
--
-- Two independent pieces:
--
-- 1. Registers ServiceBillRequestPage / ServiceBillRequestApprovalScreen in
--    dbo.screens, same group_id/screen_code/comp_img as the sibling
--    ServiceAgreement* rows (14_service_agreement_screens.sql) — verified
--    live before writing this: `SELECT screen_id, comp, group_id, screen_code,
--    display_order, comp_img FROM dbo.screens WHERE comp LIKE 'Service%'`
--    shows group_id=2, screen_code='S17', comp_img='PackageMinus' consistently
--    across every existing Service* screen row. Reuses the existing
--    sp_nt_GrantScreenToUser (14_service_agreement_screens.sql) — no new
--    procedure needed, same as every other screen addition in this series.
--
-- 2. Backfills service_agreement.recurrence_cadence_sno for the 3 rows that
--    predate 23_service_recurring_flow_redesign.sql (all still status='P',
--    verified live: agreement_sno 1/3 = 'MONTHLY', agreement_sno 2 =
--    'QUARTERLY' — both map cleanly onto recurrence_cadence_master's seed
--    rows). Without this, approving one of these 3 the normal way would still
--    correctly auto-issue its FIRST cycle (sp_nt_IssueRecurringServicePOCycle
--    doesn't need recurrence_cadence_sno), but sp_nt_ProcessDueRecurringServiceAgreements'
--    sweep would never pick it up for any LATER cycle (its JOIN requires a
--    non-NULL match) — a real functional gap for pre-existing data, not
--    speculative. Matches by cadence_code text, same value already stored in
--    the old recurrence_cadence column; NULLs stay NULL if no matching code
--    exists in the master (none do here, but the UPDATE is written to be
--    re-runnable/safe regardless of what's live when it's applied).
-- ============================================================

-- ── 1. Screens ──────────────────────────────────────────────────────────────

DECLARE @group_id            INT           = 2;
DECLARE @screen_code         VARCHAR(10)   = N'S17';
DECLARE @display_order_page  INT           = 22;
DECLARE @display_order_appr  INT           = 22;
DECLARE @comp_img_value      NVARCHAR(100) = N'Receipt';

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceBillRequestPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service Bill Requests', @screen_code, 'ServiceBillRequestPage', @comp_img_value, @group_id, @display_order_page, 'Y');

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceBillRequestApprovalScreen')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service Bill Request Approvals', @screen_code, 'ServiceBillRequestApprovalScreen', @comp_img_value, @group_id, @display_order_appr, 'Y');
GO

-- ── 2. Backfill existing agreements' recurrence_cadence_sno ────────────────

UPDATE sa
SET sa.recurrence_cadence_sno = rc.recurrence_cadence_sno
FROM dbo.service_agreement sa
JOIN dbo.recurrence_cadence_master rc ON rc.cadence_code = sa.recurrence_cadence AND rc.is_active = 'Y'
WHERE sa.recurrence_cadence_sno IS NULL;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.screens WHERE comp LIKE 'ServiceBillRequest%';
--   SELECT agreement_sno, agreement_no, recurrence_cadence, recurrence_cadence_sno FROM dbo.service_agreement ORDER BY agreement_sno;
--   -- then, per user who needs access to the new screens (replace the values):
--   SELECT screen_id FROM dbo.screens WHERE comp = 'ServiceBillRequestPage';
--   SELECT permission_id, permission_name FROM dbo.permissions;
--   EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = N'{"ecno":"<ECNO>","screen_id":<id>,"permission_ids":[<ids>]}';
-- ============================================================
