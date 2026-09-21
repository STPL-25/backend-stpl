-- ============================================================
-- Vendor Bill + Payment screens
-- Database : Non_trade_Dev (MSSQL, 10.0.21.8)
-- Used by  : nt-frontend-stpl SideBar.tsx (screens table),
--            Application/VendorBill/VendorBillPage.tsx,
--            Application/Payment/PaymentPage.tsx
--
-- Registers the two new screens closing out the Vendor-Driven Purchase
-- Requisition feature's billing/payment side (see
-- backend-stpl/sql/61_vendor_driven_purchase_requisition_v2.sql and
-- grn-service/sql/28_vendor_driven_billing.sql). PaymentPage also closes a
-- pre-existing gap — grn-service/src/payment has been live with no
-- frontend since file 14_payment.sql was written; this is genuinely the
-- first Payment screen in the app, not vendor-driven-specific.
-- Same group_id/screen_code convention as every other screen registered
-- this session (group_id=2, screen_code='S17').
-- ============================================================

DECLARE @group_id    INT         = 2;
DECLARE @screen_code VARCHAR(10) = N'S17';

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'VendorBillPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Vendor Bill', @screen_code, 'VendorBillPage', N'Receipt', @group_id, 24, 'Y');

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'PaymentPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Payment', @screen_code, 'PaymentPage', N'Wallet', @group_id, 25, 'Y');
GO

-- ============================================================
-- After running, confirm:
--   SELECT screen_id, comp FROM dbo.screens WHERE comp IN ('VendorBillPage','PaymentPage');
-- ============================================================
