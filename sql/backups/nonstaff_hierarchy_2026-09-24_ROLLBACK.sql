-- ROLLBACK for sql/94_nonstaff_user_hierarchy_lookup.sql
-- Restores sp_nt_GetUserHierarchy to its 80_dept_scope_fix.sql definition
-- (captured verbatim from live Non_Trade and Non_trade_Dev on 2026-09-24 —
-- both were identical). Effect of rolling back: non-staff logins go back to
-- an empty hierarchy (and therefore empty org-scoped screens).

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetUserHierarchy
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX);
    SELECT TOP 1 @HierarchyJson = hierarchy_json
    FROM dbo.nt_user_permissions_json
    WHERE ecno = @Ecno AND is_active = 'Y'
    ORDER BY user_perm_json_sno DESC;

    SELECT com_sno, div_sno, brn_sno, dept_sno
    FROM OPENJSON(@HierarchyJson)
    WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno', dept_sno INT '$.dept_sno');
END;
GO
