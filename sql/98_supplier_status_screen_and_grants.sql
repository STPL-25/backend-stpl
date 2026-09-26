-- ============================================================
-- Screens: register "Supplier Status" and make "PR Tracking" reachable.
-- Database : Non_trade_Dev
--
-- 1. New screen SupplierStatusPage (frontend: Application/SupplierStatus, registered in
--    ComponentsDatas.tsx). Sits in the KYC group (group_id 2, next to KYC Entry = order 2 and
--    KYC Approval Screen = order 3). SideBar.tsx builds the menu from screens.comp / comp_img /
--    group_id, and reads comp_img as a lucide-react icon name.
--
-- 2. PR Tracking (screen 50, built in sql/29) has existed since 2026-09 but was granted to NO
--    staff user in this database — only to one non-staff login — so requesters could not open
--    it from the menu. Granting it here (view + Approve; permission 7 also unlocks the
--    "Team / Org View" tab, see PRTracking.service.js).
--
-- Grants follow the convention of sql/17: the account used for every verification pass in this
-- series (KTM1148) only, through the existing sp_nt_GrantScreenToUser, which is idempotent
-- (ALREADY_GRANTED on a re-run). Everyone else is granted through the Role Approval screen — a
-- menu/permission change for other people is not made silently.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'SupplierStatusPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Supplier Status', 'S2', 'SupplierStatusPage', 'ListChecks', 2, 4, 'Y');
GO

DECLARE @ecno VARCHAR(50) = 'KTM1148';
DECLARE @screen_id INT, @json NVARCHAR(200);

SELECT @screen_id = screen_id FROM dbo.screens WHERE comp = 'SupplierStatusPage';
SET @json = N'{"ecno":"' + @ecno + N'","screen_id":' + CAST(@screen_id AS VARCHAR(10)) + N',"permission_ids":[2]}';
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;

SELECT @screen_id = screen_id FROM dbo.screens WHERE comp = 'PRTrackingPage';
SET @json = N'{"ecno":"' + @ecno + N'","screen_id":' + CAST(@screen_id AS VARCHAR(10)) + N',"permission_ids":[2,7]}';
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;
GO
