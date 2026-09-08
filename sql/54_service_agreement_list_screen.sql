-- ============================================================
-- Service Agreement List screen (browse Fixed/Variable/Vendor-Driven,
-- edit Fixed/Variable with re-approval)
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : nt-frontend-stpl SideBar.tsx (screens table),
--            Application/ServiceAgreement/ServiceAgreementListPage.tsx
--
-- Same group_id/screen_code/comp_img convention as every other Service*
-- screen (group_id=2, screen_code='S17'). Reuses sp_nt_GrantScreenToUser.
-- Deliberately does not grant to any user here (needs the live screen_id
-- this INSERT produces) — done as a live post-step, same order every prior
-- Service* screens file followed.
-- ============================================================

DECLARE @group_id            INT           = 2;
DECLARE @screen_code         VARCHAR(10)   = N'S17';
DECLARE @display_order_page  INT           = 22;
DECLARE @comp_img_value      NVARCHAR(100) = N'ClipboardList';

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceAgreementListPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service Agreements List', @screen_code, 'ServiceAgreementListPage', @comp_img_value, @group_id, @display_order_page, 'Y');
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.screens WHERE comp = 'ServiceAgreementListPage';
--   EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = N'{"ecno":"<ECNO>","screen_id":<id>,"permission_ids":[2,3,4,5,7,8]}';
-- ============================================================
