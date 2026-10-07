-- ============================================================
-- Screen: register "Test Screen" (dashboard-style placeholder page) and grant it to KTM1148.
-- Database : Non_trade_Dev
--
-- Frontend: Application/TestScreen/TestScreenPage.tsx, registered in ComponentsDatas.tsx.
-- Placed in group_id 2 (same group as Supplier Status), display_order 5. Re-runnable.
-- Grant uses the existing idempotent sp_nt_GrantScreenToUser (view permission 2), KTM1148 only.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'TestScreenPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Test Screen', 'S3', 'TestScreenPage', 'LayoutDashboard', 2, 5, 'Y');
GO

DECLARE @screen_id INT, @json NVARCHAR(200);
SELECT @screen_id = screen_id FROM dbo.screens WHERE comp = 'TestScreenPage';
SET @json = N'{"ecno":"KTM1148","screen_id":' + CAST(@screen_id AS VARCHAR(10)) + N',"permission_ids":[2]}';
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;
GO
