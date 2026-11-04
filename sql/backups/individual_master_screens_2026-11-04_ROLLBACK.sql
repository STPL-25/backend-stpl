-- ============================================================================
-- Rollback for sql/151_individual_master_screens.sql   (Non_trade_Dev)
--
--   1. takes the 32 per-master rows (comp 'masters.%') out of every user's screens_json - this also removes any
--      grants admins made on those rows after 151, which is the point: the matrix goes back to the single "Masters" row
--   2. switches the 32 screen rows and the "Individual Masters" group off (soft delete - nothing is dropped, so
--      re-applying 151 simply switches them back on)
--
-- The "Masters" row (comp 'masters') and every user's grant on it are never touched, so each user is back to exactly
-- the access the Masters page gave before 151 (whole page or nothing) - as long as the frontend from before the change
-- is deployed. The new frontend needs the rows: with them off, no master tile shows.
-- ============================================================================

UPDATE u
SET u.screens_json = ISNULL((
        SELECT e.screen_id, JSON_QUERY(e.permissions) AS permissions
        FROM OPENJSON(u.screens_json) WITH (screen_id INT '$.screen_id', permissions NVARCHAR(MAX) '$.permissions' AS JSON) e
        WHERE e.screen_id NOT IN (SELECT screen_id FROM dbo.screens WHERE comp LIKE 'masters.%')
        FOR JSON PATH
    ), '[]'),
    u.updated_date = GETDATE()
FROM dbo.nt_user_permissions_json u
WHERE ISJSON(u.screens_json) = 1
  AND EXISTS (
        SELECT 1
        FROM OPENJSON(u.screens_json) WITH (screen_id INT '$.screen_id') h
        JOIN dbo.screens c ON c.screen_id = h.screen_id AND c.comp LIKE 'masters.%'
  );
GO

UPDATE dbo.screens SET is_active = 'N' WHERE comp LIKE 'masters.%' AND is_active <> 'N';
UPDATE dbo.screen_group SET is_active = 'N' WHERE group_name = N'Individual Masters' AND is_active <> 'N';
GO
