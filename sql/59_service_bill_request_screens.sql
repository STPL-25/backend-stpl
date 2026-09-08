-- ============================================================
-- Service Bill Request screens
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : nt-frontend-stpl SideBar.tsx (screens table),
--            Application/ServiceBillRequest/{ServiceBillRequestPage,ServiceBillRequestApprovalScreen}.tsx
--
-- Registers ServiceBillRequestPage/ServiceBillRequestApprovalScreen in
-- dbo.screens — same group_id/screen_code convention as every other
-- Service* screen. Backend + frontend both built and live-verified this
-- session (real items[] end-to-end, see sql/58_service_bill_request_items.sql).
--
-- Deliberately does NOT grant the screens to any user here — same reasoning
-- as every prior Service* screens file: needs the live screen_id this
-- INSERT produces.
-- ============================================================

DECLARE @group_id            INT           = 2;
DECLARE @screen_code         VARCHAR(10)   = N'S17';
DECLARE @display_order_page  INT           = 24;
DECLARE @display_order_appr  INT           = 24;
DECLARE @comp_img_value      NVARCHAR(100) = N'Receipt';

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceBillRequestPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service Bill Request', @screen_code, 'ServiceBillRequestPage', @comp_img_value, @group_id, @display_order_page, 'Y');

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceBillRequestApprovalScreen')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service Bill Request Approvals', @screen_code, 'ServiceBillRequestApprovalScreen', @comp_img_value, @group_id, @display_order_appr, 'Y');
GO
