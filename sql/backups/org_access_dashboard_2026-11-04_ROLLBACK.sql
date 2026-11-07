-- ============================================================================
-- Rollback for 152_org_access_dashboard.sql (Non_trade_Dev)
--
-- Removes the Dashboard screen from every user's screens_json, deletes the screen, deletes the (now empty) "Dashboard"
-- group and drops sp_nt_GetOrgAccessDashboard. Other screen entries are preserved as they were (the JSON array is rebuilt
-- from its own elements, so only whitespace between elements may differ). Safe to re-run.
-- ============================================================================

DECLARE @scr INT = (SELECT TOP 1 screen_id FROM dbo.screens WHERE comp = 'OrgDashboard');

IF @scr IS NOT NULL
BEGIN
    UPDATE p
       SET screens_json = ISNULL('[' + (
               SELECT STRING_AGG(CAST(v.[value] AS NVARCHAR(MAX)), ',') WITHIN GROUP (ORDER BY CAST(v.[key] AS INT))
               FROM OPENJSON(p.screens_json) v
               WHERE ISNULL(TRY_CAST(JSON_VALUE(v.[value], '$.screen_id') AS INT), -1) <> @scr
           ) + ']', '[]')
    FROM dbo.nt_user_permissions_json p
    WHERE ISJSON(p.screens_json) = 1
      AND EXISTS (SELECT 1 FROM OPENJSON(p.screens_json) WITH (screen_id INT '$.screen_id') s WHERE s.screen_id = @scr);

    DELETE FROM dbo.screens WHERE screen_id = @scr;
END

DELETE g FROM dbo.screen_group g
WHERE g.group_name = N'Dashboard'
  AND NOT EXISTS (SELECT 1 FROM dbo.screens s WHERE s.group_id = g.group_id);
GO

IF OBJECT_ID('dbo.sp_nt_GetOrgAccessDashboard', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetOrgAccessDashboard;
GO
