-- ============================================================================
-- 152_org_access_dashboard.sql   (Non_trade_Dev)
--
-- "Dashboard" - the first item in the sidebar. One live page that shows the organisation (companies, divisions, branches,
-- departments) and WHO has access to each of them.
--
--   * sp_nt_GetOrgAccessDashboard   one call, six result sets (meta, nodes, node_users, users, grants, unassigned).
--   * screen_group "Dashboard" + screen "Dashboard" (comp OrgDashboard, display_order 0 = sorts before every other screen;
--     sp_nt_GetUserScreensAndPermissionsJson orders by display_order and the sidebar lists groups in first-seen order).
--   * View (permission 2) granted to every active nt_user_permissions_json row, so the item actually appears.
--     nt_user_permissions_json.updated_date is NOT touched - the dashboard's "recently changed access" feed reads it.
--
-- WHAT A USER MAY SEE (decided here, in the database - the client cannot widen it)
--   * Everybody : the organisation nodes that overlap their own hierarchy (ancestors are shown dimmed as context), and
--                 their own access.
--   * Admins    : anyone holding View on the Role Approval screen (comp 'RoleApproval') additionally sees every user whose
--                 access overlaps the admin's own scope, how many users reach each node, and who has no access assigned yet.
--                 (Same overlap rule as sp_nt_GetUserIdentitiesInScope, which the Role Approval screen uses.)
--
-- HOW ACCESS IS READ
--   nt_user_permissions_json.hierarchy_json is a list of {com_sno, div_sno, brn_sno, dept_sno}. A NULL level means "the whole
--   parent". A grant COVERS a node when every level the grant names matches the node's own ancestry; it OVERLAPS a node when
--   it covers part of it (or the node is an ancestor of it). users_full = covers, users_total = overlaps.
--   Like the sidebar and sp_nt_GetUserHierarchy, only the LATEST active row per identity counts (production has duplicate
--   active rows for some non-staff logins).
--
-- Safe to re-run. Rollback: sql/backups/org_access_dashboard_2026-11-04_ROLLBACK.sql
-- Verify without applying: node sql/_verify_152.mjs   (applies inside a transaction that is always rolled back)
-- ============================================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetOrgAccessDashboard
    @jsonInput NVARCHAR(MAX)    -- { "ecno": "<ecno for staff, login_id for non-staff>" }
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Actor VARCHAR(100) = LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.ecno')));

    -- ── latest active permission row per identity (staff: ecno, non-staff: login_id) ───────────────
    CREATE TABLE #Perm (
        ident VARCHAR(100) NOT NULL PRIMARY KEY, ecno VARCHAR(50) NULL, login_id VARCHAR(50) NULL,
        hierarchy_json NVARCHAR(MAX) NULL, screens_json NVARCHAR(MAX) NULL, updated_at DATETIME NULL, perm_sno INT NOT NULL
    );
    INSERT INTO #Perm (ident, ecno, login_id, hierarchy_json, screens_json, updated_at, perm_sno)
    SELECT x.ident, x.ecno, x.login_id, x.hierarchy_json, x.screens_json, COALESCE(x.updated_date, x.created_date), x.user_perm_json_sno
    FROM (
        SELECT p.*, COALESCE(p.ecno, p.login_id) AS ident,
               ROW_NUMBER() OVER (PARTITION BY COALESCE(p.ecno, p.login_id) ORDER BY p.user_perm_json_sno DESC) AS rn
        FROM dbo.nt_user_permissions_json p
        WHERE p.is_active = 'Y' AND COALESCE(p.ecno, p.login_id) IS NOT NULL
    ) x
    WHERE x.rn = 1;

    DECLARE @MyIdent VARCHAR(100), @MyHier NVARCHAR(MAX), @MyScreens NVARCHAR(MAX);
    SELECT @MyIdent = ident, @MyHier = hierarchy_json, @MyScreens = screens_json FROM #Perm WHERE ident = @Actor;
    SET @MyIdent = COALESCE(@MyIdent, @Actor);

    -- Admin = View on the Role Approval screen.
    DECLARE @IsAdmin BIT = CASE WHEN EXISTS (
        SELECT 1
        FROM OPENJSON(ISNULL(@MyScreens, '[]'))
             WITH (screen_id INT '$.screen_id', permissions NVARCHAR(MAX) '$.permissions' AS JSON) s
        CROSS APPLY OPENJSON(s.permissions) WITH (permission_id INT '$') p
        JOIN dbo.screens sc ON sc.screen_id = s.screen_id AND sc.is_active = 'Y'
        WHERE sc.comp = 'RoleApproval' AND p.permission_id = 2
    ) THEN 1 ELSE 0 END;

    -- ── the caller's own grants ────────────────────────────────────────────────────────────────────
    CREATE TABLE #MyGrants (com_sno INT NOT NULL, div_sno INT NULL, brn_sno INT NULL, dept_sno INT NULL);
    INSERT INTO #MyGrants (com_sno, div_sno, brn_sno, dept_sno)
    SELECT DISTINCT com_sno, div_sno, brn_sno, dept_sno
    FROM OPENJSON(ISNULL(@MyHier, '[]'))
         WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno', dept_sno INT '$.dept_sno')
    WHERE com_sno IS NOT NULL;

    -- ── every organisation node, then keep the ones the caller can see ────────────────────────────
    CREATE TABLE #Nodes (
        node_id INT IDENTITY(1,1) PRIMARY KEY, node_level VARCHAR(12) NOT NULL,
        com_sno INT NOT NULL, div_sno INT NULL, brn_sno INT NULL, dept_sno INT NULL,
        node_name NVARCHAR(200) NULL, node_code NVARCHAR(50) NULL, is_active CHAR(1) NULL
    );
    INSERT INTO #Nodes (node_level, com_sno, div_sno, brn_sno, dept_sno, node_name, node_code, is_active)
    SELECT 'company',    c.com_sno, NULL,      NULL,      NULL,       c.com_name,  c.com_prefix, c.is_active FROM dbo.company_master  c
    UNION ALL
    SELECT 'division',   d.com_sno, d.div_sno, NULL,      NULL,       d.div_name,  d.div_prefix, d.is_active FROM dbo.division_master d
    UNION ALL
    SELECT 'branch',     b.com_sno, b.div_sno, b.brn_sno, NULL,       b.brn_name,  b.brn_prefix, b.is_active FROM dbo.branch_master   b
    UNION ALL
    SELECT 'department', x.com_sno, x.div_sno, x.brn_sno, x.dept_sno, x.dept_name, x.dept_code,  x.is_active FROM dbo.dept_master     x;

    -- overlap: the grant reaches some or all of the node (an ancestor node overlaps a deeper grant)
    DELETE n FROM #Nodes n
    WHERE NOT EXISTS (
        SELECT 1 FROM #MyGrants g
        WHERE g.com_sno = n.com_sno
          AND (g.div_sno  IS NULL OR n.div_sno  IS NULL OR g.div_sno  = n.div_sno)
          AND (g.brn_sno  IS NULL OR n.brn_sno  IS NULL OR g.brn_sno  = n.brn_sno)
          AND (g.dept_sno IS NULL OR n.dept_sno IS NULL OR g.dept_sno = n.dept_sno)
    );

    -- ── every identity's grants (deduplicated); lvl 1 company .. 4 department ──────────────────────
    CREATE TABLE #Grants (
        ident VARCHAR(100) NOT NULL, com_sno INT NOT NULL, div_sno INT NULL, brn_sno INT NULL, dept_sno INT NULL, lvl TINYINT NOT NULL
    );
    INSERT INTO #Grants (ident, com_sno, div_sno, brn_sno, dept_sno, lvl)
    SELECT DISTINCT p.ident, h.com_sno, h.div_sno, h.brn_sno, h.dept_sno,
           CASE WHEN h.dept_sno IS NOT NULL THEN 4 WHEN h.brn_sno IS NOT NULL THEN 3 WHEN h.div_sno IS NOT NULL THEN 2 ELSE 1 END
    FROM #Perm p
    CROSS APPLY OPENJSON(ISNULL(p.hierarchy_json, '[]'))
         WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno', dept_sno INT '$.dept_sno') h
    WHERE h.com_sno IS NOT NULL;

    -- People with no organisation access at all (admins only): active staff / non-staff with no grant row.
    CREATE TABLE #Unassigned (ident VARCHAR(100), user_name NVARCHAR(200), kind VARCHAR(10));
    IF @IsAdmin = 1
        INSERT INTO #Unassigned (ident, user_name, kind)
        SELECT u.ident, u.user_name, u.kind
        FROM (
            SELECT s.ecno AS ident, COALESCE(e.ename, s.ecno) AS user_name, 'Staff' AS kind
            FROM dbo.nt_sign_up s
            LEFT JOIN dbo.vw_verified_employees e ON e.ecno COLLATE DATABASE_DEFAULT = s.ecno COLLATE DATABASE_DEFAULT
            WHERE s.is_active = 'Y'
            UNION ALL
            SELECT n.login_id, COALESCE(n.full_name, n.login_id), 'Non-staff'
            FROM dbo.nt_nonstaff_login n
            WHERE n.is_active = 'Y'
        ) u
        WHERE NOT EXISTS (SELECT 1 FROM #Grants g WHERE g.ident = u.ident COLLATE DATABASE_DEFAULT);

    -- Who the caller may see: themselves, plus (admins) anyone whose access overlaps the admin's scope.
    CREATE TABLE #Vis (ident VARCHAR(100) NOT NULL PRIMARY KEY);
    INSERT INTO #Vis (ident)
    SELECT @MyIdent WHERE EXISTS (SELECT 1 FROM #Grants WHERE ident = @MyIdent);
    IF @IsAdmin = 1
        INSERT INTO #Vis (ident)
        SELECT DISTINCT g.ident
        FROM #Grants g
        WHERE g.ident <> @MyIdent
          AND EXISTS (
            SELECT 1 FROM #MyGrants m
            WHERE m.com_sno = g.com_sno
              AND (m.div_sno  IS NULL OR g.div_sno  IS NULL OR m.div_sno  = g.div_sno)
              AND (m.brn_sno  IS NULL OR g.brn_sno  IS NULL OR m.brn_sno  = g.brn_sno)
              AND (m.dept_sno IS NULL OR g.dept_sno IS NULL OR m.dept_sno = g.dept_sno));
    DELETE FROM #Grants WHERE ident NOT IN (SELECT ident FROM #Vis);

    -- ── which visible identity reaches which visible node (is_full = the whole node is covered) ─────
    CREATE TABLE #NodeUser (node_id INT NOT NULL, ident VARCHAR(100) NOT NULL, is_full BIT NOT NULL, PRIMARY KEY (node_id, ident));
    INSERT INTO #NodeUser (node_id, ident, is_full)
    SELECT n.node_id, g.ident,
           CAST(MAX(CASE WHEN (g.div_sno  IS NULL OR g.div_sno  = n.div_sno)
                          AND (g.brn_sno  IS NULL OR g.brn_sno  = n.brn_sno)
                          AND (g.dept_sno IS NULL OR g.dept_sno = n.dept_sno) THEN 1 ELSE 0 END) AS BIT)
    FROM #Nodes n
    JOIN #Grants g
      ON g.com_sno = n.com_sno
     AND (g.div_sno  IS NULL OR n.div_sno  IS NULL OR g.div_sno  = n.div_sno)
     AND (g.brn_sno  IS NULL OR n.brn_sno  IS NULL OR g.brn_sno  = n.brn_sno)
     AND (g.dept_sno IS NULL OR n.dept_sno IS NULL OR g.dept_sno = n.dept_sno)
    GROUP BY n.node_id, g.ident;

    -- ═════════ RESULT SET 1: meta ═════════
    SELECT
        @IsAdmin AS is_admin,
        @MyIdent AS my_ident,
        COALESCE(
            (SELECT TOP 1 e.ename FROM dbo.vw_verified_employees e WHERE e.ecno COLLATE DATABASE_DEFAULT = @MyIdent COLLATE DATABASE_DEFAULT),
            (SELECT TOP 1 n.full_name FROM dbo.nt_nonstaff_login n WHERE n.login_id = @MyIdent),
            @MyIdent) AS my_name,
        CASE WHEN EXISTS (SELECT 1 FROM #Perm WHERE ident = @MyIdent AND ecno IS NULL) THEN 'Non-staff' ELSE 'Staff' END AS my_kind,
        (SELECT COUNT(*) FROM #MyGrants) AS my_grant_count,
        (SELECT COUNT(DISTINCT s.screen_id)
           FROM OPENJSON(ISNULL(@MyScreens, '[]')) WITH (screen_id INT '$.screen_id') s
           JOIN dbo.screens sc ON sc.screen_id = s.screen_id AND sc.is_active = 'Y' AND sc.comp NOT LIKE 'masters.%') AS my_screen_count,
        CONVERT(VARCHAR(19), GETDATE(), 126) AS server_now;

    -- ═════════ RESULT SET 2: organisation nodes (company -> division -> branch -> department) ═════════
    SELECT
        n.node_id, n.node_level, n.com_sno, n.div_sno, n.brn_sno, n.dept_sno, n.node_name, n.node_code, n.is_active,
        CASE WHEN EXISTS (
            SELECT 1 FROM #MyGrants m
            WHERE m.com_sno = n.com_sno
              AND (m.div_sno  IS NULL OR m.div_sno  = n.div_sno)
              AND (m.brn_sno  IS NULL OR m.brn_sno  = n.brn_sno)
              AND (m.dept_sno IS NULL OR m.dept_sno = n.dept_sno)
        ) THEN 1 ELSE 0 END AS in_my_access,
        (SELECT COUNT(*) FROM #NodeUser nu WHERE nu.node_id = n.node_id)                  AS users_total,
        (SELECT COUNT(*) FROM #NodeUser nu WHERE nu.node_id = n.node_id AND nu.is_full = 1) AS users_full
    FROM #Nodes n
    ORDER BY n.com_sno,
             ISNULL(n.div_sno, 0), ISNULL(n.brn_sno, 0), ISNULL(n.dept_sno, 0),
             n.node_name;

    -- ═════════ RESULT SET 3: node <-> user pairs ═════════
    SELECT node_id, ident, is_full FROM #NodeUser ORDER BY node_id, ident;

    -- ═════════ RESULT SET 4: users (visible identities) ═════════
    SELECT
        u.ident,
        COALESCE(e.ename, nl.full_name, u.ident)               AS user_name,
        CASE WHEN p.ecno IS NULL THEN 'Non-staff' ELSE 'Staff' END AS kind,
        u.grant_count, u.company_grants, u.division_grants, u.branch_grants, u.dept_grants,
        (SELECT COUNT(DISTINCT s.screen_id)
           FROM OPENJSON(ISNULL(p.screens_json, '[]')) WITH (screen_id INT '$.screen_id') s
           JOIN dbo.screens sc ON sc.screen_id = s.screen_id AND sc.is_active = 'Y' AND sc.comp NOT LIKE 'masters.%') AS screen_count,
        CONVERT(VARCHAR(19), p.updated_at, 126)                AS last_updated,
        CASE WHEN u.ident = @MyIdent THEN 1 ELSE 0 END         AS is_me
    FROM (
        SELECT g.ident, COUNT(*) AS grant_count,
               SUM(CASE WHEN g.lvl = 1 THEN 1 ELSE 0 END) AS company_grants,
               SUM(CASE WHEN g.lvl = 2 THEN 1 ELSE 0 END) AS division_grants,
               SUM(CASE WHEN g.lvl = 3 THEN 1 ELSE 0 END) AS branch_grants,
               SUM(CASE WHEN g.lvl = 4 THEN 1 ELSE 0 END) AS dept_grants
        FROM #Grants g GROUP BY g.ident
    ) u
    JOIN #Perm p ON p.ident = u.ident
    LEFT JOIN dbo.vw_verified_employees e ON e.ecno COLLATE DATABASE_DEFAULT = p.ecno COLLATE DATABASE_DEFAULT
    LEFT JOIN dbo.nt_nonstaff_login nl ON nl.login_id = p.login_id
    ORDER BY CASE WHEN u.ident = @MyIdent THEN 0 ELSE 1 END, COALESCE(e.ename, nl.full_name, u.ident);

    -- ═════════ RESULT SET 5: each user's grants, with names. is_effective = 0 when a broader grant of the same user already covers it ═════════
    SELECT
        g.ident,
        CASE g.lvl WHEN 4 THEN 'department' WHEN 3 THEN 'branch' WHEN 2 THEN 'division' ELSE 'company' END AS node_level,
        g.com_sno, c.com_name, g.div_sno, d.div_name, g.brn_sno, b.brn_name, g.dept_sno, x.dept_name,
        CASE WHEN EXISTS (
            SELECT 1 FROM #Grants w
            WHERE w.ident = g.ident AND w.lvl < g.lvl
              AND w.com_sno = g.com_sno
              AND (w.div_sno  IS NULL OR w.div_sno  = g.div_sno)
              AND (w.brn_sno  IS NULL OR w.brn_sno  = g.brn_sno)
              AND (w.dept_sno IS NULL OR w.dept_sno = g.dept_sno)
        ) THEN 0 ELSE 1 END AS is_effective
    FROM #Grants g
    LEFT JOIN dbo.company_master  c ON c.com_sno  = g.com_sno
    LEFT JOIN dbo.division_master d ON d.div_sno  = g.div_sno
    LEFT JOIN dbo.branch_master   b ON b.brn_sno  = g.brn_sno
    LEFT JOIN dbo.dept_master     x ON x.dept_sno = g.dept_sno
    ORDER BY g.ident, g.com_sno, ISNULL(g.div_sno, 0), ISNULL(g.brn_sno, 0), ISNULL(g.dept_sno, 0);

    -- ═════════ RESULT SET 6: people with no organisation access yet (admins only; empty otherwise) ═════════
    SELECT ident, user_name, kind FROM #Unassigned ORDER BY user_name;
END
GO

-- ── screen group + screen ───────────────────────────────────────────────────
-- display_order 0 sorts before every other screen (the lowest existing value is 1, and no active screen has a NULL order).
IF NOT EXISTS (SELECT 1 FROM dbo.screen_group WHERE group_name = N'Dashboard')
    INSERT INTO dbo.screen_group (group_name, is_active) VALUES (N'Dashboard', 'Y');

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'OrgDashboard')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active, staff_only)
    SELECT N'Dashboard', 'ORGDASH', 'OrgDashboard', 'LayoutDashboard',     -- screen_code is VARCHAR(10)
           (SELECT TOP 1 group_id FROM dbo.screen_group WHERE group_name = N'Dashboard'), 0, 'Y', 'N';
GO

-- ── grant View to every active user ─────────────────────────────────────────
-- Appends {"screen_id":N,"permissions":[2]} to each active row that does not hold the screen yet. Idempotent.
-- updated_date is left alone on purpose (see header). Sessions already open pick the item up on the next sidebar refresh.
DECLARE @scr INT = (SELECT TOP 1 screen_id FROM dbo.screens WHERE comp = 'OrgDashboard');
UPDATE p
   SET screens_json = JSON_MODIFY(CASE WHEN ISJSON(p.screens_json) = 1 THEN p.screens_json ELSE '[]' END,
                                  'append $',
                                  JSON_QUERY('{"screen_id":' + CAST(@scr AS VARCHAR(12)) + ',"permissions":[2]}'))
FROM dbo.nt_user_permissions_json p
WHERE p.is_active = 'Y'
  AND @scr IS NOT NULL
  AND NOT EXISTS (
        SELECT 1
        FROM OPENJSON(CASE WHEN ISJSON(p.screens_json) = 1 THEN p.screens_json ELSE '[]' END) WITH (screen_id INT '$.screen_id') s
        WHERE s.screen_id = @scr);
GO
