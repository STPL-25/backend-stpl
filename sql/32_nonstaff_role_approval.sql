-- ============================================================
-- Non-staff users in Role Approval (Permission Manager)
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Why this is needed
-- ------------------
-- Non-staff users (dbo.nt_nonstaff_login, login_id-keyed — see
-- 31_nonstaff_login.sql) already work as PR/PO approvers and are already
-- selectable in the Approval Workflow admin screen's approver picker
-- (ApprovalWorkflowManager.tsx merges apiNonStaffList into its dropdown —
-- no backend change needed there, since approver_ecno is a free-text
-- VARCHAR column). This file extends the ONE remaining admin screen where
-- they're missing: Role Approval / "Permission Manager"
-- (UserRoleApprovalScreen.tsx), which lets an admin grant menu/screen
-- access to a user.
--
-- That screen's CRUD (sp_nt_Save/Get/Update/DeleteUserPermissionsJson,
-- originally created by sql/create_user_permissions_json_procs.mjs) is
-- hard-keyed on nt_user_permissions_json.nt_sign_up_sno, an INT identity
-- that only exists for staff (nt_sign_up) rows. Non-staff identity is
-- login_id VARCHAR(30) (dbo.nt_nonstaff_login) — a different identity
-- space entirely, with its own PK (nonstaff_login_sno). This file adds a
-- nullable login_id column alongside the existing nt_sign_up_sno column
-- (also relaxed to nullable) and updates the 4 CRUD procs to branch on
-- whichever identity is present. Exactly one of the two is populated per
-- row — enforced by the calling application (Node), not a DB constraint,
-- matching this table's existing style (no CHECK constraints, no FKs —
-- confirmed live: nt_user_permissions_json has zero foreign keys).
--
-- Verified live before writing this file (throwaway .mjs, deleted after):
--   nt_sign_up_sno is INT NOT NULL, no FKs on the table at all.
--   dbo.nt_nonstaff_login and dbo.designation_master both already exist
--   live (31_nonstaff_login.sql has already been run).
--
-- sp_nt_GetAllUsersSignUp (the staff user-picker's source) is NOT touched —
-- it has no SQL definition anywhere in this repo (legacy). The frontend
-- merges apiNonStaffList (already exists, GET /api/nonstaff/list) into the
-- same picker client-side instead, exactly like Approval Workflow already
-- does — zero risk to that legacy, undocumented proc.
--
-- No change to sp_nt_GetUserScreensAndPermissionsJson (the sidebar reader)
-- — non-staff users don't use the staff Dashboard shell, so nothing
-- consumes these permissions for them yet. This is admin-side
-- record-keeping/parity, matching what was asked for.
-- ============================================================

-- ============================================================
-- nt_user_permissions_json — add login_id, relax nt_sign_up_sno to nullable
-- ============================================================
IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'nt_user_permissions_json' AND COLUMN_NAME = 'login_id'
)
BEGIN
    ALTER TABLE dbo.nt_user_permissions_json ADD login_id VARCHAR(30) NULL;
END;
GO

ALTER TABLE dbo.nt_user_permissions_json ALTER COLUMN nt_sign_up_sno INT NULL;
GO

-- ── sp_nt_SaveUserPermissionsJson ───────────────────────────────────────────
-- @jsonInput: {"user_id":n,"ecno":"...","login_id":"...","hierarchy":[...],"screens":[...]}
-- user_id (staff) and login_id (non-staff) are mutually exclusive — whichever
-- the caller sends is stored; the other stays NULL on the row.
IF OBJECT_ID('dbo.sp_nt_SaveUserPermissionsJson', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_SaveUserPermissionsJson;
GO
CREATE PROCEDURE dbo.sp_nt_SaveUserPermissionsJson
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UserId INT, @Ecno VARCHAR(50), @LoginId VARCHAR(30),
            @HierarchyJson NVARCHAR(MAX), @ScreensJson NVARCHAR(MAX);

    SELECT
        @UserId = user_id,
        @Ecno = ecno,
        @LoginId = login_id,
        @HierarchyJson = hierarchy,
        @ScreensJson = screens
    FROM OPENJSON(@jsonInput)
    WITH (
        user_id INT '$.user_id',
        ecno VARCHAR(50) '$.ecno',
        login_id VARCHAR(30) '$.login_id',
        hierarchy NVARCHAR(MAX) '$.hierarchy' AS JSON,
        screens NVARCHAR(MAX) '$.screens' AS JSON
    );

    INSERT INTO nt_user_permissions_json (nt_sign_up_sno, ecno, login_id, hierarchy_json, screens_json, created_date, is_active)
    OUTPUT INSERTED.user_perm_json_sno
    VALUES (@UserId, @Ecno, @LoginId, ISNULL(@HierarchyJson,'[]'), ISNULL(@ScreensJson,'[]'), GETDATE(), 'Y');
END;
GO

-- ── sp_nt_GetUserPermissionsJson ────────────────────────────────────────────
-- @jsonInput: {"userId":n} for staff, or {"loginId":"..."} for non-staff.
IF OBJECT_ID('dbo.sp_nt_GetUserPermissionsJson', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetUserPermissionsJson;
GO
CREATE PROCEDURE dbo.sp_nt_GetUserPermissionsJson
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UserId INT, @LoginId VARCHAR(30);
    SELECT @UserId = userId, @LoginId = loginId
    FROM OPENJSON(@jsonInput) WITH (userId INT '$.userId', loginId VARCHAR(30) '$.loginId');

    SELECT TOP 1 user_perm_json_sno, nt_sign_up_sno, ecno, login_id, hierarchy_json, screens_json
    FROM nt_user_permissions_json
    WHERE is_active = 'Y'
      AND (
            (@LoginId IS NOT NULL AND login_id = @LoginId)
         OR (@LoginId IS NULL AND nt_sign_up_sno = @UserId)
          )
    ORDER BY user_perm_json_sno DESC;
END;
GO

-- ── sp_nt_UpdateUserPermissionsJson ─────────────────────────────────────────
-- @jsonInput: {"userId":n,"hierarchy":[...],"screens":[...]} for staff, or
--             {"loginId":"...","hierarchy":[...],"screens":[...]} for non-staff.
IF OBJECT_ID('dbo.sp_nt_UpdateUserPermissionsJson', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_UpdateUserPermissionsJson;
GO
CREATE PROCEDURE dbo.sp_nt_UpdateUserPermissionsJson
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UserId INT, @LoginId VARCHAR(30), @HierarchyJson NVARCHAR(MAX), @ScreensJson NVARCHAR(MAX);

    SELECT
        @UserId = userId,
        @LoginId = loginId,
        @HierarchyJson = hierarchy,
        @ScreensJson = screens
    FROM OPENJSON(@jsonInput)
    WITH (
        userId INT '$.userId',
        loginId VARCHAR(30) '$.loginId',
        hierarchy NVARCHAR(MAX) '$.hierarchy' AS JSON,
        screens NVARCHAR(MAX) '$.screens' AS JSON
    );

    UPDATE nt_user_permissions_json
    SET hierarchy_json = ISNULL(@HierarchyJson,'[]'),
        screens_json = ISNULL(@ScreensJson,'[]'),
        updated_date = GETDATE()
    WHERE is_active = 'Y'
      AND (
            (@LoginId IS NOT NULL AND login_id = @LoginId)
         OR (@LoginId IS NULL AND nt_sign_up_sno = @UserId)
          );

    SELECT @@ROWCOUNT AS rows_affected;
END;
GO

-- ── sp_nt_DeleteUserPermissionsJson ─────────────────────────────────────────
-- @jsonInput: {"userId":n} for staff, or {"loginId":"..."} for non-staff.
-- Returns ecno so the controller can push a "permissions revoked" socket
-- event to that user's room — NULL for non-staff rows (they have no ecno
-- and don't use the staff Dashboard shell this event refreshes).
IF OBJECT_ID('dbo.sp_nt_DeleteUserPermissionsJson', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_DeleteUserPermissionsJson;
GO
CREATE PROCEDURE dbo.sp_nt_DeleteUserPermissionsJson
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UserId INT, @LoginId VARCHAR(30);
    SELECT @UserId = userId, @LoginId = loginId
    FROM OPENJSON(@jsonInput) WITH (userId INT '$.userId', loginId VARCHAR(30) '$.loginId');

    DECLARE @DeletedEcno TABLE (ecno VARCHAR(50));

    DELETE FROM nt_user_permissions_json
    OUTPUT DELETED.ecno INTO @DeletedEcno
    WHERE (@LoginId IS NOT NULL AND login_id = @LoginId)
       OR (@LoginId IS NULL AND nt_sign_up_sno = @UserId);

    SELECT @@ROWCOUNT AS rows_affected, (SELECT TOP 1 ecno FROM @DeletedEcno) AS ecno;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT COLUMN_NAME, IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS
--     WHERE TABLE_NAME = 'nt_user_permissions_json';
--   SELECT name FROM sys.procedures
--     WHERE name IN ('sp_nt_SaveUserPermissionsJson','sp_nt_GetUserPermissionsJson',
--                     'sp_nt_UpdateUserPermissionsJson','sp_nt_DeleteUserPermissionsJson');
--
-- Manual smoke test — in Role Approval, pick a non-staff user (e.g. an
-- Executive Director / MD / IA-* designation), grant a couple of screens,
-- save, reload the page, confirm it loads back, then revoke and confirm
-- the record is gone:
--   SELECT * FROM nt_user_permissions_json WHERE login_id IS NOT NULL;
-- ============================================================
