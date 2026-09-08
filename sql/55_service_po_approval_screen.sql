-- ============================================================
-- Service PO Approval screen
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : nt-frontend-stpl SideBar.tsx (screens table),
--            Application/ServicePO/ServicePOApprovalScreen.tsx
--
-- Registers ServicePOApprovalScreen in dbo.screens, same group_id/
-- screen_code/comp_img convention as every other Service* screen row
-- (group_id=2, screen_code='S17' — verified live across every prior
-- Service* screens file, most recently 48_service_vendor_kyc_screens.sql).
-- Reuses the existing sp_nt_GrantScreenToUser — no new procedure needed.
--
-- Deliberately does NOT grant the screen to any user here — same reasoning
-- as every prior Service* screens file: needs the live screen_id this
-- INSERT produces. Done as a live post-step after this file runs.
-- ============================================================

DECLARE @group_id            INT           = 2;
DECLARE @screen_code         VARCHAR(10)   = N'S17';
DECLARE @display_order_appr  INT           = 22;
DECLARE @comp_img_value      NVARCHAR(100) = N'FileCheck2';

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServicePOApprovalScreen')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service PO Approvals', @screen_code, 'ServicePOApprovalScreen', @comp_img_value, @group_id, @display_order_appr, 'Y');
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.screens WHERE comp = 'ServicePOApprovalScreen';
--   -- then, per user who needs access (replace the values):
--   EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = N'{"ecno":"<ECNO>","screen_id":<id>,"permission_ids":[<ids>]}';
-- ============================================================
