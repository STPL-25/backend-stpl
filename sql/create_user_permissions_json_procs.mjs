import { initializeDatabase } from "../src/Dbconnections/Dbconnections.js";

const pool = await initializeDatabase();

const procedures = [
  {
    name: "sp_nt_SaveUserPermissionsJson",
    sql: `
CREATE PROCEDURE dbo.sp_nt_SaveUserPermissionsJson
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UserId INT, @Ecno VARCHAR(50), @HierarchyJson NVARCHAR(MAX), @ScreensJson NVARCHAR(MAX);

    SELECT
        @UserId = user_id,
        @Ecno = ecno,
        @HierarchyJson = hierarchy,
        @ScreensJson = screens
    FROM OPENJSON(@jsonInput)
    WITH (
        user_id INT '$.user_id',
        ecno VARCHAR(50) '$.ecno',
        hierarchy NVARCHAR(MAX) '$.hierarchy' AS JSON,
        screens NVARCHAR(MAX) '$.screens' AS JSON
    );

    INSERT INTO nt_user_permissions_json (nt_sign_up_sno, ecno, hierarchy_json, screens_json, created_date, is_active)
    OUTPUT INSERTED.user_perm_json_sno
    VALUES (@UserId, @Ecno, ISNULL(@HierarchyJson,'[]'), ISNULL(@ScreensJson,'[]'), GETDATE(), 'Y');
END;`,
  },
  {
    name: "sp_nt_GetUserPermissionsJson",
    sql: `
CREATE PROCEDURE dbo.sp_nt_GetUserPermissionsJson
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UserId INT;
    SELECT @UserId = userId FROM OPENJSON(@jsonInput) WITH (userId INT '$.userId');

    SELECT TOP 1 user_perm_json_sno, nt_sign_up_sno, ecno, hierarchy_json, screens_json
    FROM nt_user_permissions_json
    WHERE nt_sign_up_sno = @UserId AND is_active = 'Y'
    ORDER BY user_perm_json_sno DESC;
END;`,
  },
  {
    name: "sp_nt_UpdateUserPermissionsJson",
    sql: `
CREATE PROCEDURE dbo.sp_nt_UpdateUserPermissionsJson
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UserId INT, @HierarchyJson NVARCHAR(MAX), @ScreensJson NVARCHAR(MAX);

    SELECT
        @UserId = userId,
        @HierarchyJson = hierarchy,
        @ScreensJson = screens
    FROM OPENJSON(@jsonInput)
    WITH (
        userId INT '$.userId',
        hierarchy NVARCHAR(MAX) '$.hierarchy' AS JSON,
        screens NVARCHAR(MAX) '$.screens' AS JSON
    );

    UPDATE nt_user_permissions_json
    SET hierarchy_json = ISNULL(@HierarchyJson,'[]'),
        screens_json = ISNULL(@ScreensJson,'[]'),
        updated_date = GETDATE()
    WHERE nt_sign_up_sno = @UserId AND is_active = 'Y';

    SELECT @@ROWCOUNT AS rows_affected;
END;`,
  },
  {
    name: "sp_nt_DeleteUserPermissionsJson",
    sql: `
CREATE PROCEDURE dbo.sp_nt_DeleteUserPermissionsJson
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UserId INT;
    SELECT @UserId = userId FROM OPENJSON(@jsonInput) WITH (userId INT '$.userId');

    DECLARE @DeletedEcno TABLE (ecno VARCHAR(50));

    DELETE FROM nt_user_permissions_json
    OUTPUT DELETED.ecno INTO @DeletedEcno
    WHERE nt_sign_up_sno = @UserId;

    SELECT @@ROWCOUNT AS rows_affected, (SELECT TOP 1 ecno FROM @DeletedEcno) AS ecno;
END;`,
  },
  {
    name: "sp_nt_GetUserScreensAndPermissionsJson",
    sql: `
CREATE PROCEDURE dbo.sp_nt_GetUserScreensAndPermissionsJson
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ecno VARCHAR(50);
    SELECT @Ecno = ecno FROM OPENJSON(@jsonInput) WITH (ecno VARCHAR(50) '$.ecno');

    DECLARE @HierarchyJson NVARCHAR(MAX), @ScreensJson NVARCHAR(MAX);
    SELECT TOP 1
        @HierarchyJson = hierarchy_json,
        @ScreensJson   = screens_json
    FROM nt_user_permissions_json
    WHERE ecno = @Ecno AND is_active = 'Y'
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
END;`,
  },
];

for (const proc of procedures) {
  try {
    await pool.request().query(`IF OBJECT_ID('dbo.${proc.name}', 'P') IS NOT NULL DROP PROCEDURE dbo.${proc.name}`);
    await pool.request().batch(proc.sql);
    console.log(`Created: ${proc.name}`);
  } catch (err) {
    console.error(`FAILED: ${proc.name}`, err.message);
    process.exitCode = 1;
  }
}

process.exit();
