-- ============================================================
-- Vendor Entry Consolidation screen registration
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : nt-frontend-stpl SideBar.tsx (screens table), new
--            Application/ServiceVendorEntry/ServiceVendorConsolidationPage.tsx
--
-- Only ONE new screen is needed here — the daily-entry form itself lives
-- inside the existing, already-registered ServiceAgreementPage (Vendor
-- Driven tab), it's just been repointed at the new
-- createServiceVendorDailyEntry endpoint instead of createServicePO
-- directly. Only the consolidation ("pick entries, raise PO") screen is new
-- UI. Same group_id/screen_code/comp_img convention as every sibling
-- Service* screen (14_service_agreement_screens.sql, 24_service_bill_
-- request_screens_and_backfill.sql) — verified live before writing this via
-- SELECT screen_id, comp, group_id, screen_code, display_order, comp_img
-- FROM dbo.screens WHERE comp LIKE 'Service%'.
-- Reuses the existing sp_nt_GrantScreenToUser — no new procedure needed.
-- ============================================================

DECLARE @group_id       INT           = 2;
DECLARE @screen_code    VARCHAR(10)   = N'S17';
DECLARE @display_order  INT           = 22;
DECLARE @comp_img_value NVARCHAR(100) = N'ClipboardCheck';

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceVendorConsolidationPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Vendor Entry Consolidation', @screen_code, 'ServiceVendorConsolidationPage', @comp_img_value, @group_id, @display_order, 'Y');
GO

-- ============================================================
-- After running, confirm and grant:
--   SELECT * FROM dbo.screens WHERE comp = 'ServiceVendorConsolidationPage';
--   SELECT screen_id FROM dbo.screens WHERE comp = 'ServiceVendorConsolidationPage';
--   EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = N'{"ecno":"<ECNO>","screen_id":<id>,"permission_ids":[2,3,4,5,7,8]}';
-- ============================================================
