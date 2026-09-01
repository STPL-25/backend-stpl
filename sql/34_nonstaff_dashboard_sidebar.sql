-- ============================================================
-- Non-staff users on the main Dashboard shell — sidebar reader
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Why this is needed
-- ------------------
-- 32_nonstaff_role_approval.sql added login_id to nt_user_permissions_json
-- and updated the 4 CRUD procs (Save/Get/Update/DeleteUserPermissionsJson)
-- so an admin can grant a non-staff login_id screen access from Role
-- Approval / Permission Manager. Its own header explicitly called out what
-- it deliberately left undone: "No change to
-- sp_nt_GetUserScreensAndPermissionsJson (the sidebar reader) — non-staff
-- users don't use the staff Dashboard shell, so nothing consumes these
-- permissions for them yet."
--
-- Non-staff login now signs in through the same session-cookie mechanism as
-- staff and lands on the same Dashboard shell (App.tsx/SideBar.tsx), so this
-- proc needs to resolve a login_id-keyed row exactly like
-- sp_nt_GetUserPermissionsJson already does. Same branch pattern, same
-- nullable @LoginId convention.
--
-- Base body reproduced from create_user_permissions_json_procs.mjs
-- (sp_nt_GetUserScreensAndPermissionsJson, lines 106-153) — only the lookup
-- (@LoginId added, WHERE branches on it) is new; everything else (hierarchy/
-- screens JOIN, company/division/branch resolution) is untouched.
-- ============================================================

IF OBJECT_ID('dbo.sp_nt_GetUserScreensAndPermissionsJson', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetUserScreensAndPermissionsJson;
GO
CREATE PROCEDURE dbo.sp_nt_GetUserScreensAndPermissionsJson
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ecno VARCHAR(50), @LoginId VARCHAR(30);
    SELECT @Ecno = ecno, @LoginId = loginId
    FROM OPENJSON(@jsonInput)
    WITH (ecno VARCHAR(50) '$.ecno', loginId VARCHAR(30) '$.loginId');

    DECLARE @HierarchyJson NVARCHAR(MAX), @ScreensJson NVARCHAR(MAX);
    SELECT TOP 1
        @HierarchyJson = hierarchy_json,
        @ScreensJson   = screens_json
    FROM nt_user_permissions_json
    WHERE is_active = 'Y'
      AND (
            (@LoginId IS NOT NULL AND login_id = @LoginId)
         OR (@LoginId IS NULL AND ecno = @Ecno)
          )
    ORDER BY user_perm_json_sno DESC;

    ;WITH Hier AS (
        SELECT com_sno, div_sno, brn_sno
        FROM OPENJSON(@HierarchyJson)
        WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno')
    ),
    Scr AS (
        SELECT s.screen_id, perm.permission_id
        FROM OPENJSON(@ScreensJson)
        WITH (
            screen_id INT '$.screen_id',
            permissions NVARCHAR(MAX) '$.permissions' AS JSON
        ) AS s
        CROSS APPLY OPENJSON(s.permissions) WITH (permission_id INT '$') AS perm
    )
    SELECT
        cmp.com_name, cmp.com_sno,
        div.div_name, div.div_sno,
        br.brn_name, br.brn_sno,
        scn.screen_name, scn.screen_id, scn.display_order, scn.comp, scn.comp_img, scn.group_id,
        p.permission_id, p.permission_name
    FROM Scr s
    INNER JOIN screens scn ON scn.screen_id = s.screen_id AND scn.is_active = 'Y'
    INNER JOIN permissions p ON p.permission_id = s.permission_id AND p.is_active = 'Y'
    CROSS JOIN Hier h
    LEFT JOIN company_master  cmp ON cmp.com_sno = h.com_sno
    LEFT JOIN division_master div ON div.div_sno = h.div_sno
    LEFT JOIN branch_master   br  ON br.brn_sno  = h.brn_sno
    ORDER BY scn.display_order ASC;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.sp_nt_GetUserScreensAndPermissionsJson'));
--
-- Manual smoke test — grant a non-staff login_id a screen via Role Approval,
-- then log in as that non-staff user on the main sign-in page: the sidebar
-- should show exactly the granted screen(s).
-- ============================================================
