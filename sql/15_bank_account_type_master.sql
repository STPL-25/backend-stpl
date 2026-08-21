-- ============================================================
-- Bank Account Type master — bank_account_type_master
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/Masters (generic /api/common_master/:masterField
--            pipeline), registered as master key "BankAccountTypeMaster" —
--            same shape as service_type_master (see
--            backend-stpl/sql/05_service_masters.sql), which this file mirrors.
--
-- Why this is needed
-- ------------------
-- Vendor KYC bank details (ac_type — see backend-stpl/src/Kyc/validation/
-- kycValidation.js BANK_REQUIRED) previously took the account type as a free
-- text field with a "Savings / Current" placeholder — no master, no validated
-- list. This gives it a proper master so the KYC forms can offer a dropdown
-- instead, same as every other KYC bank field that already has a source of
-- truth. The KYC bank_details column stores this as free text (no
-- ac_type_sno column exists), so the option VALUE is deliberately the
-- account_type_name text itself, not the surrogate sno — matching what's
-- already stored today and requiring no KYC table/SP changes.
--
-- Only GET-all and CREATE are wired, matching PriorityMaster/UomMaster/
-- ServiceTypeMaster's existing pattern in this app (no update/delete
-- procedures registered for this master either).
-- ============================================================

IF OBJECT_ID('dbo.bank_account_type_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.bank_account_type_master (
        bank_account_type_sno INT IDENTITY(1,1) PRIMARY KEY,
        account_type_code     VARCHAR(30)   NOT NULL,
        account_type_name     NVARCHAR(100) NOT NULL,
        is_active              CHAR(1)       NOT NULL DEFAULT 'Y',
        created_by             VARCHAR(20)   NULL,
        created_at             DATETIME      NOT NULL DEFAULT GETDATE(),
        modified_by            VARCHAR(20)   NULL,
        modified_at            DATETIME      NULL,
        CONSTRAINT UQ_bank_account_type_master_code UNIQUE (account_type_code),
        CONSTRAINT UQ_bank_account_type_master_name UNIQUE (account_type_name)
    );
END;
GO

-- ── sp_nt_GetBankAccountTypeRecords ─────────────────────────────────────────
IF OBJECT_ID('dbo.sp_nt_GetBankAccountTypeRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetBankAccountTypeRecords;
GO
CREATE PROCEDURE dbo.sp_nt_GetBankAccountTypeRecords
AS
BEGIN
    SET NOCOUNT ON;

    SELECT bank_account_type_sno,
           account_type_code,
           account_type_name,
           is_active
    FROM dbo.bank_account_type_master
    WHERE is_active = 'Y'
    ORDER BY bank_account_type_sno;
END;
GO

-- ── sp_nt_CreateBankAccountTypeRecords ──────────────────────────────────────
-- @jsonInput: {"account_type_code":"...", "account_type_name":"...", "created_by":"..."}
IF OBJECT_ID('dbo.sp_nt_CreateBankAccountTypeRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateBankAccountTypeRecords;
GO
CREATE PROCEDURE dbo.sp_nt_CreateBankAccountTypeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @account_type_code NVARCHAR(30)  = JSON_VALUE(@jsonInput, '$.account_type_code'),
            @account_type_name NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.account_type_name'),
            @created_by        VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @account_type_code IS NULL OR @account_type_name IS NULL
    BEGIN
        THROW 50002, N'account_type_code and account_type_name are required.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.bank_account_type_master WHERE account_type_code = @account_type_code)
    BEGIN
        THROW 50003, N'A bank account type with this code already exists.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.bank_account_type_master WHERE account_type_name = @account_type_name)
    BEGIN
        THROW 50004, N'A bank account type with this name already exists.', 1;
        RETURN;
    END;

    INSERT INTO dbo.bank_account_type_master (
        account_type_code, account_type_name, is_active, created_by
    )
    VALUES (
        @account_type_code, @account_type_name, 'Y', @created_by
    );

    SELECT SCOPE_IDENTITY()   AS bank_account_type_sno,
           @account_type_code AS account_type_code,
           N'SUCCESS'         AS status,
           N'Bank account type created successfully.' AS message;
END;
GO

-- ── Seed the common bank account types used on vendor KYC ───────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.bank_account_type_master)
BEGIN
    INSERT INTO dbo.bank_account_type_master (
        account_type_code, account_type_name, is_active, created_by
    )
    VALUES
        (N'SAVINGS',  N'Savings',      'Y', N'system'),
        (N'CURRENT',  N'Current',      'Y', N'system'),
        (N'CC',       N'Cash Credit',  'Y', N'system'),
        (N'OD',       N'Overdraft',    'Y', N'system');
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.bank_account_type_master ORDER BY bank_account_type_sno;
--   SELECT name FROM sys.procedures WHERE name LIKE 'sp_nt_%BankAccountType%';
-- ============================================================
