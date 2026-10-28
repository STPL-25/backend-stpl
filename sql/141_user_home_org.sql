-- ============================================================================
-- 141_user_home_org.sql   (Non_trade_Dev)
--
-- A user's FIXED home Company / Division / Branch / Department.
--
--   * Role Approval (nt_user_permissions_json) stays what it was: the org scope a user may SEE / ACT in.
--   * The home org is who the user IS - it lives on nt_sign_up (com_sno, div_sno, brn_sno, dept_sno), is returned by
--     sp_nt_Login (vw_Sign_Up) into the session, and is never touched by Role Approval.
--   * HR (vw_verified_employees) only has FREE-TEXT dept / branch ("IT", "KTM-HO") which do not match the app's own
--     dept_master / branch_master ("Information Technology", ...). So an admin maps each user once on the
--     "User Home Org" screen; sp_nt_GetUserHomeOrgList shows the HR text beside the current mapping and a
--     name-match SUGGESTION (never auto-applied).
--
-- Creates: sp_nt_GetUserHomeOrgList, sp_nt_SetUserHomeOrg, screen "User Home Org" (comp UserHomeOrgPage).
-- Safe to re-run. Rollback: sql/backups/user_home_org_2026-10-26_ROLLBACK.sql
-- ============================================================================

-- ── list ────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetUserHomeOrgList
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        s.nt_sign_up_sno,
        s.ecno,
        e.ename,
        COALESCE(e.dept,   s.dept)   AS hr_dept,     -- HR free text (live), falling back to what sign-up copied
        COALESCE(e.BRANCH, s.branch) AS hr_branch,
        s.com_sno,  c.com_name,
        s.div_sno,  d.div_name,
        s.brn_sno,  b.brn_name,
        s.dept_sno, dm.dept_name,
        CASE WHEN s.dept_sno IS NOT NULL THEN 1 ELSE 0 END AS is_mapped,
        -- name-match suggestion: HR dept text = dept name or code, preferring the branch whose name/prefix = HR branch text
        sg.dept_sno AS sug_dept_sno
    FROM dbo.nt_sign_up s
    LEFT JOIN dbo.vw_verified_employees e ON e.ecno COLLATE DATABASE_DEFAULT = s.ecno COLLATE DATABASE_DEFAULT
    LEFT JOIN dbo.company_master  c  ON c.com_sno  = s.com_sno
    LEFT JOIN dbo.division_master d  ON d.div_sno  = s.div_sno
    LEFT JOIN dbo.branch_master   b  ON b.brn_sno  = s.brn_sno
    LEFT JOIN dbo.dept_master     dm ON dm.dept_sno = s.dept_sno
    OUTER APPLY (
        SELECT TOP 1 x.dept_sno
        FROM dbo.dept_master x
        LEFT JOIN dbo.branch_master xb ON xb.brn_sno = x.brn_sno
        WHERE x.is_active = 'Y'
          AND (UPPER(LTRIM(RTRIM(x.dept_name))) = UPPER(LTRIM(RTRIM(COALESCE(e.dept, s.dept)))) COLLATE DATABASE_DEFAULT
               OR UPPER(LTRIM(RTRIM(x.dept_code))) = UPPER(LTRIM(RTRIM(COALESCE(e.dept, s.dept)))) COLLATE DATABASE_DEFAULT)
        ORDER BY CASE WHEN UPPER(LTRIM(RTRIM(xb.brn_name))) = UPPER(LTRIM(RTRIM(COALESCE(e.BRANCH, s.branch)))) COLLATE DATABASE_DEFAULT
                        OR UPPER(LTRIM(RTRIM(xb.brn_prefix))) = UPPER(LTRIM(RTRIM(COALESCE(e.BRANCH, s.branch)))) COLLATE DATABASE_DEFAULT
                      THEN 0 ELSE 1 END, x.dept_sno
    ) sg
    WHERE s.is_active = 'Y'
    ORDER BY s.ecno;

    -- second result set: the departments an admin can pick (each carries its own company / division / branch)
    SELECT x.dept_sno, x.dept_name, x.com_sno, c.com_name, x.div_sno, d.div_name, x.brn_sno, b.brn_name
    FROM dbo.dept_master x
    JOIN dbo.company_master  c ON c.com_sno = x.com_sno
    JOIN dbo.division_master d ON d.div_sno = x.div_sno
    JOIN dbo.branch_master   b ON b.brn_sno = x.brn_sno
    WHERE x.is_active = 'Y'
    ORDER BY c.com_name, d.div_name, b.brn_name, x.dept_name;
END
GO

-- ── set ─────────────────────────────────────────────────────────────────────
-- @jsonInput: { ecno, dept_sno, modified_by? }. Company / division / branch are DERIVED from the department row, so the four
-- can never disagree. Errors are THROWN with a message the screen shows as it is.
CREATE OR ALTER PROCEDURE dbo.sp_nt_SetUserHomeOrg
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF @jsonInput IS NULL OR ISJSON(@jsonInput) = 0
        THROW 59301, N'Invalid JSON payload provided.', 1;

    DECLARE @ecno VARCHAR(50) = LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.ecno')));
    DECLARE @dept INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);

    IF @ecno IS NULL OR @ecno = ''
        THROW 59302, N'Employee number is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.nt_sign_up WHERE ecno = @ecno COLLATE DATABASE_DEFAULT AND is_active = 'Y')
        THROW 59303, N'That user is not signed up (or is inactive).', 1;
    IF @dept IS NULL
        THROW 59304, N'Pick a department.', 1;

    DECLARE @com INT, @div INT, @brn INT;
    SELECT @com = com_sno, @div = div_sno, @brn = brn_sno
    FROM dbo.dept_master WHERE dept_sno = @dept AND is_active = 'Y';

    IF @com IS NULL OR @div IS NULL OR @brn IS NULL
        THROW 59305, N'That department is inactive or has no company / division / branch.', 1;

    UPDATE dbo.nt_sign_up
       SET com_sno = @com, div_sno = @div, brn_sno = @brn, dept_sno = @dept
     WHERE ecno = @ecno COLLATE DATABASE_DEFAULT;

    SELECT @ecno AS ecno, @com AS com_sno, @div AS div_sno, @brn AS brn_sno, @dept AS dept_sno;
END
GO

-- ── screen ──────────────────────────────────────────────────────────────────
-- Placed in the same group as the User Role Approval screen. Not granted to anyone here: give it to the admin who maps users
-- on Role Approval > User Permissions.
IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'UserHomeOrgPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    SELECT TOP 1 N'User Home Org', screen_code, 'UserHomeOrgPage', comp_img, group_id,
           (SELECT MAX(display_order) FROM dbo.screens WHERE group_id = r.group_id) + 1, 'Y'
    FROM dbo.screens r WHERE r.comp = 'RoleApproval';
GO
