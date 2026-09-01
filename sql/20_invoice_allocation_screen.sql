-- ============================================================
-- Invoice Allocation screen registration + grant
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : nt-frontend-stpl SideBar.tsx — makes InvoiceAllocationPage
--            (new grn-service-backed screen, ComponentsDatas.tsx already
--            registers it as lazy()) reachable via menu navigation.
--
-- Modeled on the same self-referential INSERT pattern used in
-- sql/17_pr_entry_screens_activation.sql, copying screen_code/group_id/
-- comp_img off the sibling ServicePOPage row (group_id=2, screen_code='S17'
-- — same "procurement/finance ops" menu section as Payment/Service* screens,
-- confirmed live) rather than guessing.
-- ============================================================

INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
SELECT N'Invoice Allocation', screen_code, 'InvoiceAllocationPage', comp_img, group_id, 23, 'Y'
FROM dbo.screens
WHERE comp = 'ServicePOPage'
  AND NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'InvoiceAllocationPage');
GO

DECLARE @ecno VARCHAR(50) = 'KTM1148';
DECLARE @permission_ids NVARCHAR(50) = '[2,3,4,5,7,8]';
DECLARE @screen_id INT;
DECLARE @json NVARCHAR(200);

SELECT @screen_id = screen_id FROM dbo.screens WHERE comp = 'InvoiceAllocationPage';
SET @json = N'{"ecno":"' + @ecno + N'","screen_id":' + CAST(@screen_id AS VARCHAR(10)) + N',"permission_ids":' + @permission_ids + N'}';
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;
GO

-- ============================================================
-- After running, confirm:
--   SELECT screen_id, comp, is_active, group_id FROM dbo.screens WHERE comp = 'InvoiceAllocationPage';
--   SELECT screens_json FROM dbo.nt_user_permissions_json WHERE ecno='KTM1148' AND is_active='Y';
-- ============================================================
