-- ============================================================
-- Service Vendor KYC screens
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : nt-frontend-stpl SideBar.tsx (screens table), new
--            backend-stpl/src/ServiceVendorKyc module
--
-- Registers ServiceVendorKycPage / ServiceVendorKycApprovalScreen in
-- dbo.screens, same group_id/screen_code/comp_img as every other Service*
-- screen row (verified live before writing this, same check
-- 24_service_bill_request_screens_and_backfill.sql documents:
-- group_id=2, screen_code='S17' consistently across every existing Service*
-- screen). Reuses the existing sp_nt_GrantScreenToUser — no new procedure
-- needed, same as every other screen addition in this series.
--
-- Deliberately does NOT grant the screens to any user or configure the
-- ServiceVendorKYC workflow here — those need live IDs (the screen_id this
-- INSERT produces, the current permission_id set, and confirmation of
-- sp_nt_SaveFullWorkflow's exact call shape) that can't be hardcoded blind
-- into a checked-in file. Done as a live post-step after this file runs,
-- same order every prior Service* module's screens file followed.
-- ============================================================

DECLARE @group_id            INT           = 2;
DECLARE @screen_code         VARCHAR(10)   = N'S17';
DECLARE @display_order_page  INT           = 22;
DECLARE @display_order_appr  INT           = 22;
DECLARE @comp_img_value      NVARCHAR(100) = N'ShieldCheck';

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceVendorKycPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service Vendor KYC', @screen_code, 'ServiceVendorKycPage', @comp_img_value, @group_id, @display_order_page, 'Y');

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceVendorKycApprovalScreen')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service Vendor KYC Approvals', @screen_code, 'ServiceVendorKycApprovalScreen', @comp_img_value, @group_id, @display_order_appr, 'Y');
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.screens WHERE comp LIKE 'ServiceVendorKyc%';
--   -- then, per user who needs access (replace the values):
--   SELECT screen_id FROM dbo.screens WHERE comp = 'ServiceVendorKycPage';
--   SELECT permission_id, permission_name FROM dbo.permissions;
--   EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = N'{"ecno":"<ECNO>","screen_id":<id>,"permission_ids":[<ids>]}';
--   -- and configure the ServiceVendorKYC workflow via sp_nt_SaveFullWorkflow
--   -- (same call shape used for ServiceAgreement/ServiceBillRequest), then via
--   -- Approval Workflow Manager UI, or a direct EXEC once its jsonInput shape
--   -- is confirmed live.
-- ============================================================
