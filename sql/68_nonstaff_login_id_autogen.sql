-- ============================================================
-- Auto-generate nt_nonstaff_login.login_id (fixes a real collision risk)
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Why this is needed
-- ------------------
-- login_id was admin-typed free text (31_nonstaff_login.sql), only checked
-- for uniqueness within dbo.nt_nonstaff_login itself. Nothing stopped an
-- admin from typing a login_id that collides with a real staff ecno
-- (dbo.nt_sign_up.ecno). That matters because PR/PO approval routing
-- matches approver_ecno / current_approver_id by plain VARCHAR string
-- equality with no table disambiguation (documented in
-- 31_nonstaff_login.sql's own header) — a collision would misroute an
-- approval to the wrong person, not just look confusing in a dropdown.
--
-- Fix: stop accepting login_id from the caller. Generate it here instead,
-- as NSU##### (a prefix that does not collide with the KTM####-style ecno
-- format already seen live in this codebase), sourced from a dedicated
-- sequence so it's guaranteed unique by construction. Defense-in-depth:
-- also reject the generated id if it somehow already exists as a staff
-- ecno (dbo.nt_sign_up is a legacy table, not defined in this repo, so the
-- check is guarded with OBJECT_ID in case it's ever renamed/dropped).
-- ============================================================

IF OBJECT_ID('dbo.seq_nonstaff_login_id', 'SO') IS NULL
    CREATE SEQUENCE dbo.seq_nonstaff_login_id AS INT START WITH 1 INCREMENT BY 1;
GO

-- ── sp_nt_CreateNonStaffLogin — regenerated to auto-generate login_id ───────
-- @jsonInput: {"full_name":"...", "designation_sno":n, "email":"...",
--              "phone":"...", "password_hash":"...", "created_by":"..."}
-- login_id is no longer accepted from the caller — any login_id present in
-- @jsonInput is ignored.
IF OBJECT_ID('dbo.sp_nt_CreateNonStaffLogin', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateNonStaffLogin;
GO
CREATE PROCEDURE dbo.sp_nt_CreateNonStaffLogin
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 51001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @full_name       NVARCHAR(150) = JSON_VALUE(@jsonInput, '$.full_name'),
            @designation_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.designation_sno') AS INT),
            @email           VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.email'),
            @phone           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.phone'),
            @password_hash   VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.password_hash'),
            @created_by      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @full_name IS NULL OR @designation_sno IS NULL
       OR @email IS NULL OR @password_hash IS NULL
    BEGIN
        THROW 51002, N'full_name, designation_sno, email and password_hash are required.', 1;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.designation_master WHERE designation_sno = @designation_sno AND is_active = 'Y')
    BEGIN
        THROW 51003, N'Unknown or inactive designation_sno.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.nt_nonstaff_login WHERE email = @email AND is_active = 'Y')
    BEGIN
        THROW 51005, N'A user with this email already exists.', 1;
        RETURN;
    END;

    DECLARE @login_id VARCHAR(30) =
        'NSU' + RIGHT('00000' + CAST(NEXT VALUE FOR dbo.seq_nonstaff_login_id AS VARCHAR(5)), 5);

    IF OBJECT_ID('dbo.nt_sign_up', 'U') IS NOT NULL
       AND EXISTS (SELECT 1 FROM dbo.nt_sign_up WHERE ecno = @login_id)
    BEGIN
        THROW 51006, N'Generated login ID collided with an existing staff ecno — retry.', 1;
        RETURN;
    END;

    INSERT INTO dbo.nt_nonstaff_login (
        login_id, full_name, designation_sno, email, phone,
        password_hash, must_reset_password, is_active, created_by
    )
    VALUES (
        @login_id, @full_name, @designation_sno, @email, @phone,
        @password_hash, 'Y', 'Y', @created_by
    );

    SELECT nonstaff_login_sno, login_id, full_name, must_reset_password
    FROM dbo.nt_nonstaff_login WHERE login_id = @login_id;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT name FROM sys.sequences WHERE name = 'seq_nonstaff_login_id';
--   SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.sp_nt_CreateNonStaffLogin'));
--
-- Manual smoke test — create a non-staff user from the Non-Staff User
-- Management screen (Login ID field removed from that form in this same
-- change) and confirm the generated id follows the NSU##### pattern:
--   SELECT TOP 5 login_id, full_name FROM dbo.nt_nonstaff_login ORDER BY nonstaff_login_sno DESC;
-- ============================================================
