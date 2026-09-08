-- ============================================================
-- Service Entry screens
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : nt-frontend-stpl SideBar.tsx (screens table),
--            Application/ServiceEntry/{ServiceEntryPage,ServiceEntryApprovalScreen}.tsx
--
-- Registers ServiceEntryPage (raise + history) and ServiceEntryApprovalScreen
-- (variance-exceeded escalation) in dbo.screens — same group_id/screen_code
-- convention as every other Service* screen (group_id=2, screen_code='S17').
-- The backend module (grn-service/src/serviceentry) and its SQL
-- (grn-service/sql/12_service_entry.sql) already existed and were already
-- live before this file — only the frontend was missing.
--
-- Deliberately does NOT grant the screens to any user here — same reasoning
-- as every prior Service* screens file: needs the live screen_id this
-- INSERT produces.
-- ============================================================

DECLARE @group_id            INT           = 2;
DECLARE @screen_code         VARCHAR(10)   = N'S17';
DECLARE @display_order_page  INT           = 23;
DECLARE @display_order_appr  INT           = 23;
DECLARE @comp_img_value      NVARCHAR(100) = N'ClipboardCheck';

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceEntryPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service Entry', @screen_code, 'ServiceEntryPage', @comp_img_value, @group_id, @display_order_page, 'Y');

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceEntryApprovalScreen')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service Entry Approvals', @screen_code, 'ServiceEntryApprovalScreen', @comp_img_value, @group_id, @display_order_appr, 'Y');
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.screens WHERE comp LIKE 'ServiceEntry%';
--   -- then, per user who needs access (replace the values):
--   EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = N'{"ecno":"<ECNO>","screen_id":<id>,"permission_ids":[<ids>]}';
-- ============================================================
