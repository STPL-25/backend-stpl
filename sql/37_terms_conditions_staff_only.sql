-- ============================================================
-- Terms & Conditions Master — staff-only screen
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Why this exists
-- ---------------
-- Non-staff (temporary login_id/password) sessions share the exact same
-- Dashboard shell, sidebar and Permission Manager grant plumbing as staff
-- (see sql/32_nonstaff_role_approval.sql, sql/34_nonstaff_dashboard_sidebar.sql)
-- — an admin CAN accidentally grant any screen, including
-- TermsConditionsMaster, to a non-staff user via the Permission Manager UI
-- or a manually-run sp_nt_GrantScreenToUser call. Per product decision,
-- Terms & Conditions Master must never be reachable by a non-staff session,
-- regardless of what's in that user's granted screens_json.
--
-- Rather than hardcoding 'TermsConditionsMaster' as a magic string inside
-- sp_nt_GetUserScreensAndPermissionsJson (which every future staff-only
-- screen would also need to be added to, by editing the SP again), this
-- adds a reusable staff_only flag column on dbo.screens itself — the SP
-- change becomes a one-time, generic filter.
--
-- VERIFIED LIVE (2026-09-01): fetched sp_nt_GetUserScreensAndPermissionsJson's
-- current body via OBJECT_DEFINITION before writing the replacement below —
-- only the two additions marked with a comment are new; every other line is
-- copied verbatim from the live definition.
-- ============================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.screens') AND name = 'staff_only'
)
BEGIN
    ALTER TABLE dbo.screens ADD staff_only CHAR(1) NOT NULL DEFAULT 'N';
END;
GO

UPDATE dbo.screens SET staff_only = 'Y' WHERE comp = 'TermsConditionsMaster';
GO

IF OBJECT_ID('dbo.sp_nt_GetUserScreensAndPermissionsJson', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetUserScreensAndPermissionsJson;
GO
CREATE PROCEDURE [dbo].[sp_nt_GetUserScreensAndPermissionsJson]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ecno VARCHAR(50);
    SELECT @Ecno = ecno
    FROM OPENJSON(@jsonInput)
    WITH (ecno VARCHAR(50) '$.ecno');

    DECLARE @HierarchyJson NVARCHAR(MAX), @ScreensJson NVARCHAR(MAX), @MatchedEcno VARCHAR(50);
    SELECT TOP 1
        @HierarchyJson = hierarchy_json,
        @ScreensJson   = screens_json,
        @MatchedEcno   = ecno                                          -- NEW: captured to detect non-staff below
    FROM nt_user_permissions_json
    WHERE is_active = 'Y'
      AND (
             login_id = @Ecno)
         OR (ecno = @Ecno
          )
    ORDER BY user_perm_json_sno DESC;

    -- NEW: a non-staff session's nt_user_permissions_json row has no real
    -- ecno (it matched on login_id instead) — used below to strip any
    -- staff_only screen out of the result even if it was granted.
    DECLARE @IsNonStaff BIT = CASE WHEN @MatchedEcno IS NULL THEN 1 ELSE 0 END;

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
        scn.screen_name, scn.screen_id, scn.display_order, scn.comp, scn.comp_img, scn.group_id,sg.group_name,
        p.permission_id, p.permission_name
    FROM Scr s
    INNER JOIN screens scn ON scn.screen_id = s.screen_id AND scn.is_active = 'Y'
    INNER JOIN screen_group sg ON sg.group_id=scn.group_id
    INNER JOIN permissions p ON p.permission_id = s.permission_id AND p.is_active = 'Y'
    CROSS JOIN Hier h
    LEFT JOIN company_master  cmp ON cmp.com_sno = h.com_sno
    LEFT JOIN division_master div ON div.div_sno = h.div_sno
    LEFT JOIN branch_master   br  ON br.brn_sno  = h.brn_sno
    WHERE NOT (@IsNonStaff = 1 AND scn.staff_only = 'Y')               -- NEW
    ORDER BY scn.display_order ASC;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT comp, staff_only FROM dbo.screens WHERE comp = 'TermsConditionsMaster';
--   -- should show staff_only = 'Y'
--
-- To make another screen staff-only in future, just:
--   UPDATE dbo.screens SET staff_only = 'Y' WHERE comp = '<comp>';
-- No further SP changes needed — the filter above is generic.
-- ============================================================
