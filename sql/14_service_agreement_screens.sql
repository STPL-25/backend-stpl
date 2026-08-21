-- ============================================================
-- Service Agreement screens — sidebar registration + a safe per-user grant
-- helper procedure
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : nt-frontend-stpl SideBar.tsx (reads screen_comp/screen_img/
--            group_id to build the menu) — makes ServiceAgreementPage /
--            ServiceAgreementApprovalScreen (already registered in
--            ComponentsDatas.tsx, already building clean) reachable via menu
--            navigation instead of only by URL-less internal component key.
--
-- Why this file is written differently from every other one in this series
-- ---------------------------------------------------------------------
-- Every other sql/*.sql file here was written after reading the live object
-- definition, or an existing seed, for the thing being changed. The
-- `screens` / `permissions` / `nt_user_permissions_json` tables have
-- NEITHER — no CREATE TABLE, no seed INSERT, and no body for
-- sp_nt_CreateScreenRecords or sp_get_screen_groups_with_screens exists
-- anywhere in this repo (confirmed by an Explore pass across every *.sql
-- file, including the full-object backup in sql/backups/).
--
-- The only REAL, VERIFIED (not guessed) column names come from
-- sql/create_user_permissions_json_procs.mjs — a Node script that CREATEs
-- several procedures referencing these tables directly. SQL Server would
-- have rejected those CREATE PROCEDURE statements at deploy time if the
-- columns didn't exist, so this list is trustworthy as far as it goes:
--   screens:                  screen_id, screen_name, comp, comp_img,
--                              group_id, display_order, is_active
--   permissions:               permission_id, permission_name, is_active
--   nt_user_permissions_json:  user_perm_json_sno, nt_sign_up_sno, ecno,
--                              hierarchy_json, screens_json, created_date,
--                              is_active, updated_date
--
-- What this file does NOT know, and how the INSERT below is defended against
-- that gap:
--   - Whether `screens` has other NOT NULL columns beyond the seven above
--     (e.g. screen_code, parent_screen_id, created_by). The INSERT names its
--     columns explicitly (never positional VALUES), so if an unnamed NOT
--     NULL column exists, this FAILS LOUDLY with a constraint-violation
--     error — it cannot silently insert a row with wrong/missing data in a
--     column it doesn't know about.
--   - group_id's real value for whichever menu section ServicePOPage /
--     ServiceEntryPage already sit in, and display_order's real numbering
--     scheme, and comp_img's exact expected string format for a Lucide icon
--     name. All three are parameterized as variables below with a fallback,
--     specifically so they're easy to correct in one place.
--
-- VERIFIED LIVE (2026-08-15) against 10.0.21.8/Non_Trade before running:
--   SELECT screen_id, screen_name, screen_code, display_order, group_id, comp, comp_img
--   FROM dbo.screens WHERE comp IN ('ServicePOPage','ServicePOApprovalScreen','ServiceEntryPage');
-- All three sibling Service* screens share group_id=2, screen_code='S17',
-- display_order=22, comp_img='PackageMinus ' (note: trailing space in the live
-- data — SideBar.tsx's getIcon() does a strict LucideIcons[name] lookup with no
-- trim, so that trailing space silently falls back to the default File icon for
-- all three existing rows. Not fixing their rows here — out of scope — but not
-- copying the typo into the new ones either, since there's no reason to.
--
-- Also: dbo.screens.screen_code is VARCHAR(10) NOT NULL with no default — the
-- original version of this INSERT omitted it entirely and would have failed
-- with a constraint-violation error, exactly as the note below predicted.
-- ============================================================

DECLARE @group_id            INT           = 2;
DECLARE @screen_code         VARCHAR(10)   = N'S17';
DECLARE @display_order_page  INT           = 22;
DECLARE @display_order_appr  INT           = 22;
DECLARE @comp_img_value      NVARCHAR(100) = N'PackageMinus';

-- Both INSERTs share one batch (no GO between them) so the @-variables
-- declared above stay in scope for both — a GO here would end the batch and
-- make the second INSERT fail with "Must declare the scalar variable".
IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceAgreementPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service Agreements', @screen_code, 'ServiceAgreementPage', @comp_img_value, @group_id, @display_order_page, 'Y');

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceAgreementApprovalScreen')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service Agreement Approvals', @screen_code, 'ServiceAgreementApprovalScreen', @comp_img_value, @group_id, @display_order_appr, 'Y');
GO

-- ============================================================
-- sp_nt_GrantScreenToUser — appends one {screen_id, permissions} entry to a
-- single user's existing nt_user_permissions_json.screens_json array,
-- rather than overwriting the whole column (which is what a raw UPDATE
-- would risk if screens_json already holds other grants).
-- @jsonInput: {"ecno":"...", "screen_id":123, "permission_ids":[1,2,3]}
--
-- Deliberately does NOT try to grant "every user" or guess at a default
-- permission set — screen_id and permission_ids must be supplied by the
-- caller after looking them up (SELECT screen_id FROM screens WHERE comp =
-- 'ServiceAgreementPage'; SELECT * FROM permissions;). Blasting a grant
-- across arbitrary users without being told which ones is exactly the kind
-- of unverified write this migration is trying to avoid elsewhere.
--
-- Idempotent: returns ALREADY_GRANTED without modifying anything if this
-- screen_id is already present for that user. Requires the user to already
-- have an active nt_user_permissions_json row — a brand new user's first
-- grant goes through sp_nt_SaveUserPermissionsJson instead, same as the
-- existing UserRoleApprovalScreen.tsx flow.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GrantScreenToUser', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GrantScreenToUser;
GO
CREATE PROCEDURE dbo.sp_nt_GrantScreenToUser
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ecno            VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.ecno');
    DECLARE @screen_id       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.screen_id') AS INT);
    DECLARE @permission_ids  NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.permission_ids');

    IF @ecno IS NULL OR @screen_id IS NULL OR @permission_ids IS NULL
        THROW 60001, 'ecno, screen_id and permission_ids are required.', 1;

    DECLARE @user_perm_json_sno INT, @screens_json NVARCHAR(MAX);
    SELECT TOP 1 @user_perm_json_sno = user_perm_json_sno, @screens_json = RTRIM(screens_json)
    FROM dbo.nt_user_permissions_json
    WHERE ecno = @ecno AND is_active = 'Y'
    ORDER BY user_perm_json_sno DESC;

    IF @user_perm_json_sno IS NULL
        THROW 60002, 'No active nt_user_permissions_json row for this ecno — use sp_nt_SaveUserPermissionsJson for a first-time grant instead.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@screens_json) WITH (screen_id INT '$.screen_id')
        WHERE screen_id = @screen_id
    )
    BEGIN
        SELECT 'ALREADY_GRANTED' AS result, @user_perm_json_sno AS user_perm_json_sno;
        RETURN;
    END

    DECLARE @newEntry NVARCHAR(MAX) = (
        SELECT @screen_id AS screen_id, JSON_QUERY(@permission_ids) AS permissions
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    -- screens_json is always a JSON array; '[]' needs its own branch or the
    -- LEFT()+',' below would produce a leading-comma '[,{...}]' (invalid JSON).
    DECLARE @updatedScreens NVARCHAR(MAX);
    IF @screens_json IS NULL OR @screens_json IN ('[]', '')
        SET @updatedScreens = '[' + @newEntry + ']';
    ELSE
        SET @updatedScreens = LEFT(@screens_json, LEN(@screens_json) - 1) + ',' + @newEntry + ']';

    UPDATE dbo.nt_user_permissions_json
    SET screens_json = @updatedScreens, updated_date = GETDATE()
    WHERE user_perm_json_sno = @user_perm_json_sno;

    SELECT 'GRANTED' AS result, @user_perm_json_sno AS user_perm_json_sno, @updatedScreens AS screens_json;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.screens WHERE comp LIKE 'ServiceAgreement%';
--   -- then, per user who needs access (replace the values):
--   SELECT screen_id FROM dbo.screens WHERE comp = 'ServiceAgreementPage';
--   SELECT permission_id, permission_name FROM dbo.permissions;
--   EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = N'{"ecno":"<ECNO>","screen_id":<id>,"permission_ids":[<ids>]}';
--   SELECT screens_json FROM dbo.nt_user_permissions_json WHERE ecno = '<ECNO>' AND is_active = 'Y';
--
-- If the INSERTs above fail with a NOT NULL / constraint error: that means
-- screens has a column this file didn't know about (see header). Run
-- SELECT * FROM sys.columns WHERE object_id = OBJECT_ID('dbo.screens') to
-- see the full list, add the missing column(s) to both INSERT statements,
-- and re-run.
-- ============================================================
