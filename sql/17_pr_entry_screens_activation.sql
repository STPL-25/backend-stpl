-- ============================================================
-- Mixed Product+Service PR entry screens — activation + missing rows + grant
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : nt-frontend-stpl SideBar.tsx (reads screen.comp/comp_img/group_id
--            to build the menu) — makes the 4 requisition entry pages
--            (RoutineRequisitionPage, CivilWorksRequisitionPage,
--            ElectricalWorksRequisitionPage, TransportationRequisitionPage —
--            all already built, wired in ComponentsDatas.tsx, and building
--            clean) reachable via menu navigation. None of the 4 are reachable
--            by any user today.
--
-- Why
-- ---
-- VERIFIED LIVE (2026-08-21) against 10.0.21.8/Non_Trade before writing this:
--   SELECT * FROM screens WHERE comp IN
--     ('CivilWorksRequisitionPage','RoutineRequisitionPage',
--      'PurchaseRequisitionPage','PRApprovalScreen');
-- Found:
--   screen_id=26 CivilWorksRequisitionPage    screen_code=S16 group_id=4 display_order=16 comp_img=ShieldCheck is_active=N
--   screen_id=27 RoutineRequisitionPage        screen_code=S16 group_id=4 display_order=17 comp_img=ShieldCheck is_active=N
-- ElectricalWorksRequisitionPage / TransportationRequisitionPage have NO row
-- at all. All 4 wrapper pages share `permissionComponent` values that match
-- these `comp` strings exactly (confirmed by reading the 4 .tsx files).
--
-- This file (1) flips the two existing rows to is_active='Y', (2) inserts the
-- two missing rows via a self-referential INSERT off the live Civil row so
-- screen_code/group_id/comp_img are copied correctly rather than guessed,
-- continuing display_order 18/19, (3) grants all 4 to KTM1148 — the account
-- already used for every other manual verification pass in this series
-- (already holds PurchaseRequisitionPage/PRApprovalScreen and every Service*
-- screen) — via the existing sp_nt_GrantScreenToUser
-- (sql/14_service_agreement_screens.sql). Other users can be granted the same
-- way; deliberately not blasting this across all 5 active users without being
-- asked, per that procedure's own stated intent.
-- ============================================================

-- 1) Activate the two existing-but-disabled rows
UPDATE dbo.screens
SET is_active = 'Y'
WHERE comp IN ('CivilWorksRequisitionPage', 'RoutineRequisitionPage')
  AND is_active = 'N';
GO

-- 2) Insert the two missing rows, copied from the live Civil row
INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
SELECT N'Electrical Works Requisition', screen_code, 'ElectricalWorksRequisitionPage', comp_img, group_id, 18, 'Y'
FROM dbo.screens
WHERE comp = 'CivilWorksRequisitionPage'
  AND NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ElectricalWorksRequisitionPage');

INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
SELECT N'Transportation Requisition', screen_code, 'TransportationRequisitionPage', comp_img, group_id, 19, 'Y'
FROM dbo.screens
WHERE comp = 'CivilWorksRequisitionPage'
  AND NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'TransportationRequisitionPage');
GO

-- 3) Grant all 4 to KTM1148, same permission set already held on
--    PurchaseRequisitionPage/PRApprovalScreen (View/Create/Edit/Delete/Approve/Reject)
DECLARE @ecno VARCHAR(50) = 'KTM1148';
DECLARE @permission_ids NVARCHAR(50) = '[2,3,4,5,7,8]';
DECLARE @screen_id INT;
DECLARE @json NVARCHAR(200);

SELECT @screen_id = screen_id FROM dbo.screens WHERE comp = 'CivilWorksRequisitionPage';
SET @json = N'{"ecno":"' + @ecno + N'","screen_id":' + CAST(@screen_id AS VARCHAR(10)) + N',"permission_ids":' + @permission_ids + N'}';
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;

SELECT @screen_id = screen_id FROM dbo.screens WHERE comp = 'RoutineRequisitionPage';
SET @json = N'{"ecno":"' + @ecno + N'","screen_id":' + CAST(@screen_id AS VARCHAR(10)) + N',"permission_ids":' + @permission_ids + N'}';
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;

SELECT @screen_id = screen_id FROM dbo.screens WHERE comp = 'ElectricalWorksRequisitionPage';
SET @json = N'{"ecno":"' + @ecno + N'","screen_id":' + CAST(@screen_id AS VARCHAR(10)) + N',"permission_ids":' + @permission_ids + N'}';
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;

SELECT @screen_id = screen_id FROM dbo.screens WHERE comp = 'TransportationRequisitionPage';
SET @json = N'{"ecno":"' + @ecno + N'","screen_id":' + CAST(@screen_id AS VARCHAR(10)) + N',"permission_ids":' + @permission_ids + N'}';
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;
GO

-- ============================================================
-- After running, confirm:
--   SELECT screen_id, comp, is_active, display_order FROM dbo.screens
--   WHERE comp IN ('CivilWorksRequisitionPage','RoutineRequisitionPage',
--                   'ElectricalWorksRequisitionPage','TransportationRequisitionPage');
--   SELECT screens_json FROM dbo.nt_user_permissions_json WHERE ecno='KTM1148' AND is_active='Y';
-- ============================================================
