-- ============================================================
-- Fix nt_user_permissions_json unique-key collision for non-staff users
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Why this is needed
-- ------------------
-- dbo.nt_user_permissions_json has a plain (non-filtered) UNIQUE constraint,
-- UQ_nt_user_permissions_json_user, on nt_sign_up_sno. That column is NULL
-- for every non-staff row (32_nonstaff_role_approval.sql added login_id as
-- the non-staff identity and relaxed nt_sign_up_sno to nullable, but left
-- this pre-existing constraint untouched). SQL Server treats a plain unique
-- constraint as allowing at most ONE NULL across the whole table, so the
-- moment a second non-staff user's permissions are saved for the first time,
-- sp_nt_SaveUserPermissionsJson's INSERT (nt_sign_up_sno = NULL for both
-- rows) fails:
--   Violation of UNIQUE KEY constraint 'UQ_nt_user_permissions_json_user'.
--   The duplicate key value is (<NULL>).
-- Reproduced live: Vikram V (login_id ED001) already holds the table's one
-- allowed NULL; granting permissions to a newly created second non-staff
-- user (NSU00002, "Interal Auditor") failed with the above error via
-- POST /api/user_approval/save_user_permissions_json.
--
-- Only the CREATE path is affected (sp_nt_UpdateUserPermissionsJson is
-- UPDATE-only, unaffected). This impacts every second-and-later non-staff
-- user's first permissions save, not just this one case.
--
-- Fix: drop the plain constraint and replace it with two FILTERED unique
-- indexes, one per identity space (mirrors the nt_sign_up_sno / login_id
-- split the application already enforces per this table's own convention —
-- see 32_nonstaff_role_approval.sql header):
--   - staff:     UNIQUE on nt_sign_up_sno WHERE nt_sign_up_sno IS NOT NULL
--   - non-staff: UNIQUE on login_id       WHERE login_id       IS NOT NULL
-- This preserves "at most one permissions row per staff user" exactly as
-- before, adds the equivalent guarantee for non-staff users, and lets
-- unlimited non-staff rows (all NULL in nt_sign_up_sno) coexist.
--
-- Verified before writing this file (throwaway, transaction-rolled-back
-- script against the live dev DB, never committed) via a 3-agent adversarial
-- review (correctness / safety / scope), all three approving:
--   - UQ_nt_user_permissions_json_user is a single-column, non-filtered
--     UNIQUE constraint on nt_sign_up_sno (confirmed via sys.key_constraints).
--   - With the constraint dropped and both filtered indexes in place: a
--     second non-staff INSERT (NULL nt_sign_up_sno, distinct login_id)
--     succeeds; a third likewise succeeds (generalizes to any count).
--   - A true duplicate login_id is still correctly rejected by the new
--     nonstaff filtered index (case-insensitive, matching the column's
--     default collation SQL_Latin1_General_CP1_CI_AS — login_id is always
--     admin/system-generated in a fixed uppercase format, so no collision
--     risk from case drift).
--   - Staff-side regression check: two staff rows with the same
--     nt_sign_up_sno still correctly fail on the new staff filtered index.
--   - No other object in the repo references the constraint name
--     UQ_nt_user_permissions_json_user (grepped all tracked .sql/.js) —
--     safe to drop, nothing else depends on its name.
--   - No application code change required — every catch block in
--     UserApproval.controller.js does generic error.message pass-through,
--     none pattern-match on this constraint's name.
-- ============================================================

-- Drop the old single-column UNIQUE constraint (blocks a 2nd non-staff NULL nt_sign_up_sno)
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_nt_user_permissions_json_user')
    ALTER TABLE dbo.nt_user_permissions_json DROP CONSTRAINT UQ_nt_user_permissions_json_user;
GO

-- Replace with a FILTERED unique index: staff rows only (nt_sign_up_sno IS NOT NULL) — preserves
-- "at most one active permissions row per staff user" while letting unlimited non-staff rows
-- (which are always NULL here) coexist.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_nt_user_permissions_json_staff_user' AND object_id = OBJECT_ID('dbo.nt_user_permissions_json'))
    CREATE UNIQUE INDEX UX_nt_user_permissions_json_staff_user
    ON dbo.nt_user_permissions_json (nt_sign_up_sno)
    WHERE nt_sign_up_sno IS NOT NULL;
GO

-- New FILTERED unique index: at most one active permissions row per non-staff login_id (the
-- analogous guarantee sp_nt_SaveUserPermissionsJson's callers rely on for staff today).
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_nt_user_permissions_json_nonstaff_user' AND object_id = OBJECT_ID('dbo.nt_user_permissions_json'))
    CREATE UNIQUE INDEX UX_nt_user_permissions_json_nonstaff_user
    ON dbo.nt_user_permissions_json (login_id)
    WHERE login_id IS NOT NULL;
GO

-- ============================================================
-- After running, confirm:
--   SELECT kc.name FROM sys.key_constraints kc
--     WHERE kc.name = 'UQ_nt_user_permissions_json_user';
--     -- expect 0 rows (old constraint gone)
--
--   SELECT name, filter_definition FROM sys.indexes
--     WHERE object_id = OBJECT_ID('dbo.nt_user_permissions_json')
--       AND name IN ('UX_nt_user_permissions_json_staff_user','UX_nt_user_permissions_json_nonstaff_user');
--     -- expect both rows, each with its WHERE filter_definition
--
--   -- Optional sanity check (no duplicates expected today — only one
--   -- non-NULL login_id row exists, ED001):
--   SELECT login_id, COUNT(*) AS cnt
--     FROM dbo.nt_user_permissions_json
--     WHERE login_id IS NOT NULL
--     GROUP BY login_id
--     HAVING COUNT(*) > 1;
--
-- Manual smoke test — in Role Approval, select the second non-staff user
-- (NSU00002 / "Interal Auditor"), grant a permission, click Save, and
-- confirm POST /api/user_approval/save_user_permissions_json now returns
-- success (no more "Violation of UNIQUE KEY constraint" 500):
--   SELECT * FROM dbo.nt_user_permissions_json WHERE login_id IS NOT NULL;
-- ============================================================
