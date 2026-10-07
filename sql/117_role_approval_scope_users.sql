-- ============================================================
-- Role Approval screen: show only the logged-in admin's own scope.
-- Database: Non_trade_Dev (MSSQL)
--
-- Companies / Divisions / Branches pickers are now filtered in Node from the
-- admin's own hierarchy (attachHierarchyScope). The USER picker needs a DB
-- helper: which employees / non-staff logins may this admin see?
--
-- A user is visible when
--   * they have no active nt_user_permissions_json row yet (brand-new user
--     who still has to be assigned a scope — hiding them would make first-time
--     assignment impossible), OR
--   * at least one of their hierarchy rows overlaps one of the admin's rows.
--     Two rows overlap when, at every level (com/div/brn/dept), either side
--     is NULL ("whole parent") or both are equal.
--
-- Returns identities only (ecno for staff, login_id for non-staff); the Node
-- layer filters the existing user lists with them, so
-- sp_nt_GetAllUsersSignUp / /api/nonstaff/list stay untouched.
--
-- Re-runnable (CREATE OR ALTER). Rollback: DROP PROCEDURE dbo.sp_nt_GetUserIdentitiesInScope;
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetUserIdentitiesInScope
    @HierarchyJson NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.ecno, p.login_id
    FROM dbo.nt_user_permissions_json p
    WHERE p.is_active = 'Y'
      AND EXISTS (
            SELECT 1
            FROM OPENJSON(p.hierarchy_json)
                 WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno', dept_sno INT '$.dept_sno') u
            JOIN OPENJSON(@HierarchyJson)
                 WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno', dept_sno INT '$.dept_sno') a
              ON  (u.com_sno  IS NULL OR a.com_sno  IS NULL OR u.com_sno  = a.com_sno)
              AND (u.div_sno  IS NULL OR a.div_sno  IS NULL OR u.div_sno  = a.div_sno)
              AND (u.brn_sno  IS NULL OR a.brn_sno  IS NULL OR u.brn_sno  = a.brn_sno)
              AND (u.dept_sno IS NULL OR a.dept_sno IS NULL OR u.dept_sno = a.dept_sno)
      );

    -- Recordset 2: everyone who already has a scope row. The Node layer treats
    -- anyone NOT in this list as brand-new/unassigned and keeps them visible.
    SELECT ecno, login_id FROM dbo.nt_user_permissions_json WHERE is_active = 'Y';
END;
GO
