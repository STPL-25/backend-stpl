-- ============================================================
-- Non-Staff Login (designation-based portal) — designation_master,
-- nt_nonstaff_login, and the login/reset/list procedures
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Why this is needed
-- ------------------
-- New login type for people who hold special designations (Executive
-- Director, Managing Director, IA-CBE3, IA-MTP, IA-HO, ...) but are NOT in
-- the staff/employee table (no ecno). They need to log in and act as PR/PO
-- approvers, the same way a staff approver does today.
--
-- This works with ZERO changes to the WorkFlowApproval engine or the PR/PO
-- approve/pending-list procedures: `approver_ecno` (inside
-- workflow_stage.stage_order_json) and `current_approver_id` (on
-- pr_basic_info / po/quotation tables) are plain, unconstrained VARCHAR
-- columns compared by string equality — confirmed in sp_nt_ApproveServicePO
-- and sp_nt_GetServicePOsForApproval (07_po_service_extensions.sql) and
-- sp_nt_SaveFullWorkflow (03_workflow_types_description.sql), none of which
-- join against any staff table. A non-staff login_id therefore works as a
-- first-class approver identity exactly like a staff ecno, with no schema
-- change to PR/PO. See docs/ discussion in this session for the full trace.
--
-- designation_master follows the exact same shape/pattern as
-- bank_account_type_master (15_bank_account_type_master.sql) — a simple
-- admin-extensible master with Get-all + Create only.
--
-- nt_nonstaff_login mirrors grn-service/sql/09_supplier_portal.sql's
-- nt_supplier_login (temp password + must_reset_password forced-reset
-- pattern), except login_id is admin-entered (not auto-generated) and there
-- is no parent KYC-style record — full_name/designation/email/phone live
-- directly on this table.
--
-- Screens: registers one new sidebar screen (NonStaffUserManagement, the
-- admin create/list page) and grants it to KTM1148, the existing
-- admin/test account already granted every other new screen in this
-- project (verified live before writing this: KTM1148 has an active
-- nt_user_permissions_json row). Login/reset-password/my-approvals are a
-- separate unauthenticated portal (like /Supplier) and do NOT go through
-- the screens/permissions system.
-- ============================================================

-- ============================================================
-- designation_master
-- ============================================================
IF OBJECT_ID('dbo.designation_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.designation_master (
        designation_sno   INT IDENTITY(1,1) PRIMARY KEY,
        designation_code  VARCHAR(30)   NOT NULL,
        designation_name  NVARCHAR(100) NOT NULL,
        is_active         CHAR(1)       NOT NULL DEFAULT 'Y',
        created_by        VARCHAR(20)   NULL,
        created_at        DATETIME      NOT NULL DEFAULT GETDATE(),
        modified_by       VARCHAR(20)   NULL,
        modified_at       DATETIME      NULL,
        CONSTRAINT UQ_designation_master_code UNIQUE (designation_code),
        CONSTRAINT UQ_designation_master_name UNIQUE (designation_name)
    );
END;
GO

-- ── sp_nt_GetDesignationRecords ─────────────────────────────────────────────
IF OBJECT_ID('dbo.sp_nt_GetDesignationRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetDesignationRecords;
GO
CREATE PROCEDURE dbo.sp_nt_GetDesignationRecords
AS
BEGIN
    SET NOCOUNT ON;

    SELECT designation_sno,
           designation_code,
           designation_name,
           is_active
    FROM dbo.designation_master
    WHERE is_active = 'Y'
    ORDER BY designation_sno;
END;
GO

-- ── sp_nt_CreateDesignationRecords ──────────────────────────────────────────
-- @jsonInput: {"designation_code":"...", "designation_name":"...", "created_by":"..."}
IF OBJECT_ID('dbo.sp_nt_CreateDesignationRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateDesignationRecords;
GO
CREATE PROCEDURE dbo.sp_nt_CreateDesignationRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 51001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @designation_code NVARCHAR(30)  = JSON_VALUE(@jsonInput, '$.designation_code'),
            @designation_name NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.designation_name'),
            @created_by       VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @designation_code IS NULL OR @designation_name IS NULL
    BEGIN
        THROW 51002, N'designation_code and designation_name are required.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.designation_master WHERE designation_code = @designation_code)
    BEGIN
        THROW 51003, N'A designation with this code already exists.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.designation_master WHERE designation_name = @designation_name)
    BEGIN
        THROW 51004, N'A designation with this name already exists.', 1;
        RETURN;
    END;

    INSERT INTO dbo.designation_master (
        designation_code, designation_name, is_active, created_by
    )
    VALUES (
        @designation_code, @designation_name, 'Y', @created_by
    );

    SELECT SCOPE_IDENTITY()   AS designation_sno,
           @designation_code AS designation_code,
           N'SUCCESS'        AS status,
           N'Designation created successfully.' AS message;
END;
GO

-- ── Seed the designations named in the original request ────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.designation_master)
BEGIN
    INSERT INTO dbo.designation_master (
        designation_code, designation_name, is_active, created_by
    )
    VALUES
        (N'ED_SIR',   N'Executive Director - Sir',   'Y', N'system'),
        (N'ED_MADAM', N'Executive Director - Madam', 'Y', N'system'),
        (N'MD',       N'Managing Director',          'Y', N'system'),
        (N'IA_CBE3',  N'IA-CBE3',                    'Y', N'system'),
        (N'IA_MTP',   N'IA-MTP',                     'Y', N'system'),
        (N'IA_HO',    N'IA-HO',                      'Y', N'system');
END;
GO

-- ============================================================
-- nt_nonstaff_login
-- ============================================================
IF OBJECT_ID('dbo.nt_nonstaff_login', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_nonstaff_login (
        nonstaff_login_sno   INT IDENTITY(1,1) PRIMARY KEY,
        login_id             VARCHAR(30)   NOT NULL,
        full_name             NVARCHAR(150) NOT NULL,
        designation_sno       INT           NOT NULL,
        email                 VARCHAR(255)  NOT NULL,
        phone                 VARCHAR(20)   NULL,
        password_hash         VARCHAR(255)  NOT NULL,
        must_reset_password   CHAR(1)       NOT NULL DEFAULT 'Y',
        is_active             CHAR(1)       NOT NULL DEFAULT 'Y',
        created_by             VARCHAR(20)   NULL,
        created_at             DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT UQ_nt_nonstaff_login_login_id UNIQUE (login_id),
        CONSTRAINT FK_nt_nonstaff_login_designation FOREIGN KEY (designation_sno)
            REFERENCES dbo.designation_master(designation_sno)
    );
END;
GO

-- ── sp_nt_CreateNonStaffLogin ───────────────────────────────────────────────
-- @jsonInput: {"login_id":"...", "full_name":"...", "designation_sno":n,
--              "email":"...", "phone":"...", "password_hash":"...", "created_by":"..."}
-- Straight create (not an upsert) — there is no parent record to re-invite
-- against, unlike Supplier's KYC-backed flow. THROWs if login_id already exists.
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
        THROW 51101, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @login_id        VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.login_id'),
            @full_name       NVARCHAR(150) = JSON_VALUE(@jsonInput, '$.full_name'),
            @designation_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.designation_sno') AS INT),
            @email           VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.email'),
            @phone           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.phone'),
            @password_hash   VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.password_hash'),
            @created_by      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @login_id IS NULL OR @full_name IS NULL OR @designation_sno IS NULL
       OR @email IS NULL OR @password_hash IS NULL
    BEGIN
        THROW 51102, N'login_id, full_name, designation_sno, email and password_hash are required.', 1;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.designation_master WHERE designation_sno = @designation_sno AND is_active = 'Y')
    BEGIN
        THROW 51103, N'Unknown or inactive designation_sno.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.nt_nonstaff_login WHERE login_id = @login_id)
    BEGIN
        THROW 51104, N'A user with this login ID already exists.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.nt_nonstaff_login WHERE email = @email AND is_active = 'Y')
    BEGIN
        THROW 51105, N'A user with this email already exists.', 1;
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

-- ── sp_nt_GetNonStaffLoginById ──────────────────────────────────────────────
-- @jsonInput: {"login_id":"..."} — used by the login endpoint; the
-- caller (Node side) compares password_hash with bcrypt, this proc only
-- resolves the row.
IF OBJECT_ID('dbo.sp_nt_GetNonStaffLoginById', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetNonStaffLoginById;
GO
CREATE PROCEDURE dbo.sp_nt_GetNonStaffLoginById
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @login_id VARCHAR(30) = JSON_VALUE(@jsonInput, '$.login_id');

    SELECT l.nonstaff_login_sno, l.login_id, l.full_name, l.email, l.phone,
           l.password_hash, l.must_reset_password, l.is_active,
           d.designation_sno, d.designation_name
    FROM dbo.nt_nonstaff_login l
    JOIN dbo.designation_master d ON d.designation_sno = l.designation_sno
    WHERE l.login_id = @login_id;
END;
GO

-- ── sp_nt_SetNonStaffPassword ───────────────────────────────────────────────
-- @jsonInput: {"login_id":"...", "password_hash":"..."}
IF OBJECT_ID('dbo.sp_nt_SetNonStaffPassword', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_SetNonStaffPassword;
GO
CREATE PROCEDURE dbo.sp_nt_SetNonStaffPassword
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @login_id      VARCHAR(30)  = JSON_VALUE(@jsonInput, '$.login_id'),
            @password_hash VARCHAR(255) = JSON_VALUE(@jsonInput, '$.password_hash');

    UPDATE dbo.nt_nonstaff_login
    SET password_hash = @password_hash, must_reset_password = 'N'
    WHERE login_id = @login_id;

    SELECT nonstaff_login_sno, login_id, must_reset_password
    FROM dbo.nt_nonstaff_login WHERE login_id = @login_id;
END;
GO

-- ── sp_nt_GetNonStaffUsers ──────────────────────────────────────────────────
-- Admin management grid — every non-staff login, most recent first.
IF OBJECT_ID('dbo.sp_nt_GetNonStaffUsers', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetNonStaffUsers;
GO
CREATE PROCEDURE dbo.sp_nt_GetNonStaffUsers
AS
BEGIN
    SET NOCOUNT ON;

    SELECT l.nonstaff_login_sno, l.login_id, l.full_name, l.email, l.phone,
           l.must_reset_password, l.is_active, l.created_by, l.created_at,
           d.designation_sno, d.designation_name
    FROM dbo.nt_nonstaff_login l
    JOIN dbo.designation_master d ON d.designation_sno = l.designation_sno
    ORDER BY l.nonstaff_login_sno DESC;
END;
GO

-- ============================================================
-- Screens: NonStaffUserManagement (admin create/list page)
-- VERIFIED LIVE before writing this file: group_id=3 already holds
-- 'RoleApproval' (screen_code S6, display_order 3) and
-- 'ApprovalWorkflowPage' (screen_code S10, display_order 4) — this screen
-- is the same "user/role administration" family, so it goes in group_id=3
-- with the next free display_order (5) and a fresh screen_code (S12, not
-- already used anywhere). KTM1148 confirmed to have an active
-- nt_user_permissions_json row (user_perm_json_sno=18) — same account
-- granted every other new screen in this project.
-- ============================================================
DECLARE @group_id       INT           = 3;
DECLARE @screen_code    VARCHAR(10)   = N'S12';
DECLARE @display_order  INT           = 5;
DECLARE @comp_img_value NVARCHAR(100) = N'UserPlus';

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'NonStaffUserManagement')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Non-Staff User Management', @screen_code, 'NonStaffUserManagement', @comp_img_value, @group_id, @display_order, 'Y');
GO

DECLARE @nonstaff_screen_id INT = (SELECT screen_id FROM dbo.screens WHERE comp = 'NonStaffUserManagement');
DECLARE @grant_json NVARCHAR(MAX) = N'{"ecno":"KTM1148","screen_id":' + CAST(@nonstaff_screen_id AS VARCHAR(10)) + N',"permission_ids":[2,3,4,5,7,8]}';
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @grant_json;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.designation_master ORDER BY designation_sno;
--   SELECT name FROM sys.procedures WHERE name LIKE 'sp_nt_%NonStaff%' OR name LIKE 'sp_nt_%Designation%';
--   SELECT * FROM dbo.screens WHERE comp = 'NonStaffUserManagement';
--   SELECT screens_json FROM dbo.nt_user_permissions_json WHERE ecno = 'KTM1148' AND is_active = 'Y';
-- ============================================================
