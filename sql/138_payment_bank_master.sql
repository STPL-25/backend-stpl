-- ============================================================================
-- 138_payment_bank_master.sql   (Non_trade_Dev)
--
-- Payment Bank master (payment_bank_master): the SENDER side of the bank payment file of a Payment Run (grn-service sql/68).
--
--   * which bank account each company/division/branch pays from
--                                                    bank, bank branch, account holder, account number, IFSC
--   * the TYPE of payment file that bank takes       file_type (today one layout: BANK_UPLOAD = comma separated, 28 positions, no header)
--   * what goes into the file name and the e-mail    file_prefix + client_code + starting file_code
--                                                    (SPACETEX_SPA311_SPA3112210.100), alert_email
--
-- The RECEIVER side (the supplier's account number, IFSC, bank and branch) is not kept here: it is read from the supplier KYC
-- (kyc_bank_info) when the run is made.
--
-- One row per bank account of a company/division/branch; each such scope has at most one default account
-- (the first one added becomes it). file_code is the first daily suffix; sql/68 allocates later suffixes from a dedicated register.
-- Delete is a soft delete (is_active = 'N'). Registered as master key "PaymentBankMaster" (Masters > Finance > Payment Bank);
-- org scoped like the other company masters (CommonMasterRepo.ORG_SCOPED_MASTER_FIELDS). Safe to re-run.
-- Rollback: sql/backups/payment_bank_master_2026-10-22_ROLLBACK.sql
-- ============================================================================

IF OBJECT_ID('dbo.payment_bank_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.payment_bank_master (
        payment_bank_sno INT IDENTITY(1,1) NOT NULL,
        com_sno          INT           NOT NULL,
        div_sno          INT           NULL,
        brn_sno          INT           NULL,
        profile_name     NVARCHAR(100) NOT NULL,                 -- what people call the account, e.g. "HDFC Current A/c"
        bank_name        NVARCHAR(100) NOT NULL,
        branch_name      NVARCHAR(100) NULL,
        ac_holder_name   NVARCHAR(100) NOT NULL,
        ac_number        VARCHAR(30)   NOT NULL,
        ifsc             VARCHAR(11)   NOT NULL,
        file_type        VARCHAR(20)   NOT NULL CONSTRAINT DF_payment_bank_master_file_type DEFAULT 'BANK_UPLOAD',
        file_prefix      VARCHAR(30)   NOT NULL,                 -- first part of the file name, e.g. SPACETEX
        client_code      VARCHAR(30)   NOT NULL,                 -- the bank's client code for the company, e.g. SPA311
        file_code        INT           NOT NULL CONSTRAINT DF_payment_bank_master_file_code DEFAULT 100, -- first suffix each day, e.g. 100 -> .100
        alert_email      VARCHAR(100)  NULL,                     -- goes in the e-mail position of every line
        is_default       CHAR(1)       NOT NULL CONSTRAINT DF_payment_bank_master_is_default DEFAULT 'N',
        is_active        CHAR(1)       NOT NULL CONSTRAINT DF_payment_bank_master_is_active DEFAULT 'Y',
        created_by       VARCHAR(30)   NULL,
        created_at       DATETIME      NOT NULL CONSTRAINT DF_payment_bank_master_created_at DEFAULT GETDATE(),
        modified_by      VARCHAR(30)   NULL,
        modified_at      DATETIME      NULL,
        CONSTRAINT PK_payment_bank_master PRIMARY KEY (payment_bank_sno),
        CONSTRAINT CK_payment_bank_master_is_default CHECK (is_default IN ('Y', 'N')),
        CONSTRAINT CK_payment_bank_master_is_active CHECK (is_active IN ('Y', 'N'))
    );
END;
GO

-- Upgrade an existing sql/138 table in place. Division/branch stay nullable only for legacy rows whose scope still needs to be assigned;
-- every new or edited row is required to have both by the procedures below.
IF COL_LENGTH('dbo.payment_bank_master', 'div_sno') IS NULL ALTER TABLE dbo.payment_bank_master ADD div_sno INT NULL;
IF COL_LENGTH('dbo.payment_bank_master', 'brn_sno') IS NULL ALTER TABLE dbo.payment_bank_master ADD brn_sno INT NULL;
IF COL_LENGTH('dbo.payment_bank_master', 'file_code') IS NULL
    ALTER TABLE dbo.payment_bank_master ADD file_code INT NOT NULL CONSTRAINT DF_payment_bank_master_file_code DEFAULT 100 WITH VALUES;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_payment_bank_master_company' AND object_id = OBJECT_ID('dbo.payment_bank_master'))
    CREATE INDEX IX_payment_bank_master_company ON dbo.payment_bank_master (com_sno, is_active);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_payment_bank_master_scope' AND object_id = OBJECT_ID('dbo.payment_bank_master'))
    CREATE INDEX IX_payment_bank_master_scope ON dbo.payment_bank_master (com_sno, div_sno, brn_sno, is_active);
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_payment_bank_master_file_code' AND parent_object_id = OBJECT_ID('dbo.payment_bank_master'))
    ALTER TABLE dbo.payment_bank_master ADD CONSTRAINT CK_payment_bank_master_file_code CHECK (file_code BETWEEN 100 AND 999999);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_payment_bank_master_scope_default' AND object_id = OBJECT_ID('dbo.payment_bank_master'))
    CREATE UNIQUE INDEX UX_payment_bank_master_scope_default ON dbo.payment_bank_master (com_sno, div_sno, brn_sno)
    WHERE is_active = 'Y' AND is_default = 'Y';
GO

-- ── list ────────────────────────────────────────────────────────────────────
-- @jsonInput: { hierarchy? } - the caller's allowed companies; no hierarchy = every row. Active rows only.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentBankRecords
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @h NVARCHAR(MAX) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0 SET @h = JSON_QUERY(@jsonInput, '$.hierarchy');

    SELECT m.payment_bank_sno, m.com_sno, c.com_name, m.div_sno, d.div_name, m.brn_sno, b.brn_name,
           m.profile_name, m.bank_name, m.branch_name, m.ac_holder_name, m.ac_number, m.ifsc,
           m.file_type, m.file_prefix, m.client_code, m.file_code, m.alert_email, m.is_default, m.is_active
    FROM dbo.payment_bank_master m
    LEFT JOIN dbo.company_master c ON c.com_sno = m.com_sno
    LEFT JOIN dbo.division_master d ON d.div_sno = m.div_sno
    LEFT JOIN dbo.branch_master b ON b.brn_sno = m.brn_sno
    WHERE m.is_active = 'Y'
      AND (@h IS NULL OR EXISTS (
          SELECT 1 FROM OPENJSON(@h) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') x
          WHERE x.com_sno = m.com_sno AND (x.div_sno IS NULL OR x.div_sno = m.div_sno) AND (x.brn_sno IS NULL OR x.brn_sno = m.brn_sno)))
    ORDER BY m.com_sno, m.div_sno, m.brn_sno, m.payment_bank_sno;
END
GO

-- ── create ──────────────────────────────────────────────────────────────────
-- One object (Add) or an array (Excel import). Errors 59201-59217 are THROWN with a message the screen shows as it is.
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreatePaymentBankRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    DECLARE @rows TABLE (
        rn INT IDENTITY(1,1), com_sno INT NULL, div_sno INT NULL, brn_sno INT NULL,
        profile_name NVARCHAR(MAX) NULL, bank_name NVARCHAR(MAX) NULL, branch_name NVARCHAR(MAX) NULL,
        ac_holder_name NVARCHAR(MAX) NULL, ac_number NVARCHAR(MAX) NULL, ifsc NVARCHAR(MAX) NULL, file_type NVARCHAR(MAX) NULL,
        file_prefix NVARCHAR(MAX) NULL, client_code NVARCHAR(MAX) NULL, file_code INT NULL,
        alert_email NVARCHAR(MAX) NULL, is_default CHAR(1) NULL, created_by VARCHAR(30) NULL
    );
    INSERT INTO @rows (com_sno, div_sno, brn_sno, profile_name, bank_name, branch_name, ac_holder_name, ac_number, ifsc, file_type, file_prefix, client_code, file_code, alert_email, is_default, created_by)
    SELECT TRY_CAST(NULLIF(LTRIM(RTRIM(com_sno)), N'') AS INT),
           TRY_CAST(NULLIF(LTRIM(RTRIM(div_sno)), N'') AS INT), TRY_CAST(NULLIF(LTRIM(RTRIM(brn_sno)), N'') AS INT),
           NULLIF(LTRIM(RTRIM(profile_name)), N''), NULLIF(LTRIM(RTRIM(bank_name)), N''), NULLIF(LTRIM(RTRIM(branch_name)), N''),
           NULLIF(LTRIM(RTRIM(ac_holder_name)), N''),
           NULLIF(REPLACE(REPLACE(LTRIM(RTRIM(ac_number)), N' ', N''), N'-', N''), N''),
           NULLIF(UPPER(REPLACE(LTRIM(RTRIM(ifsc)), N' ', N'')), N''),
           ISNULL(NULLIF(UPPER(LTRIM(RTRIM(file_type))), N''), N'BANK_UPLOAD'),
           NULLIF(UPPER(LTRIM(RTRIM(file_prefix))), N''), NULLIF(UPPER(LTRIM(RTRIM(client_code))), N''),
           TRY_CAST(REPLACE(LTRIM(RTRIM(file_code)), N'.', N'') AS INT),
           NULLIF(LTRIM(RTRIM(alert_email)), N''),
           CASE WHEN UPPER(LTRIM(RTRIM(is_default))) IN (N'Y', N'YES', N'TRUE', N'1') THEN 'Y' ELSE 'N' END,
           created_by
    FROM OPENJSON(@json)
    WITH (
        com_sno NVARCHAR(30) '$.com_sno', div_sno NVARCHAR(30) '$.div_sno', brn_sno NVARCHAR(30) '$.brn_sno',
        profile_name NVARCHAR(MAX) '$.profile_name', bank_name NVARCHAR(MAX) '$.bank_name',
        branch_name NVARCHAR(MAX) '$.branch_name', ac_holder_name NVARCHAR(MAX) '$.ac_holder_name', ac_number NVARCHAR(MAX) '$.ac_number',
        ifsc NVARCHAR(MAX) '$.ifsc', file_type NVARCHAR(MAX) '$.file_type', file_prefix NVARCHAR(MAX) '$.file_prefix',
        client_code NVARCHAR(MAX) '$.client_code', file_code NVARCHAR(30) '$.file_code', alert_email NVARCHAR(MAX) '$.alert_email', is_default NVARCHAR(10) '$.is_default',
        created_by VARCHAR(30) '$.created_by'
    );

    IF NOT EXISTS (SELECT 1 FROM @rows) THROW 59201, N'At least one bank account is required.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE com_sno IS NULL OR div_sno IS NULL OR brn_sno IS NULL OR profile_name IS NULL OR bank_name IS NULL
                                       OR ac_holder_name IS NULL OR ac_number IS NULL OR ifsc IS NULL OR file_prefix IS NULL OR client_code IS NULL OR file_code IS NULL)
        THROW 59201, N'Company, division, branch, account name, bank name, account holder, account number, IFSC, file prefix, client code and file code are required.', 1;
    IF EXISTS (SELECT 1 FROM @rows r WHERE NOT EXISTS (SELECT 1 FROM dbo.company_master c WHERE c.com_sno = r.com_sno))
        THROW 59202, N'Company not found.', 1;
    IF EXISTS (SELECT 1 FROM @rows r WHERE NOT EXISTS (SELECT 1 FROM dbo.division_master d WHERE d.div_sno = r.div_sno AND d.com_sno = r.com_sno AND ISNULL(d.is_active, 'Y') = 'Y'))
        THROW 59215, N'The division does not belong to the selected company.', 1;
    IF EXISTS (SELECT 1 FROM @rows r WHERE NOT EXISTS (SELECT 1 FROM dbo.branch_master b WHERE b.brn_sno = r.brn_sno AND b.div_sno = r.div_sno AND ISNULL(b.is_active, 'Y') = 'Y'))
        THROW 59216, N'The branch does not belong to the selected division.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE LEN(profile_name) > 100 OR LEN(bank_name) > 100 OR LEN(branch_name) > 100 OR LEN(ac_holder_name) > 100 OR LEN(alert_email) > 100)
        THROW 59203, N'Account name, bank, branch and account holder can be at most 100 characters; the e-mail at most 100.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE ac_number LIKE N'%[^0-9]%' COLLATE Latin1_General_BIN2 OR LEN(ac_number) < 6 OR LEN(ac_number) > 30)
        THROW 59204, N'The account number must be 6 to 30 digits.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE LEN(ifsc) <> 11 OR ifsc NOT LIKE N'[A-Z][A-Z][A-Z][A-Z]0[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]' COLLATE Latin1_General_BIN2)
        THROW 59205, N'The IFSC must be 11 characters: 4 letters, a zero, then 6 letters or digits (e.g. HDFC0000123).', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE file_type NOT IN (N'BANK_UPLOAD'))
        THROW 59206, N'Unknown payment file type. Choose one from the list.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE file_prefix LIKE N'%[^A-Z0-9-]%' COLLATE Latin1_General_BIN2 OR client_code LIKE N'%[^A-Z0-9-]%' COLLATE Latin1_General_BIN2 OR LEN(file_prefix) > 30 OR LEN(client_code) > 30)
        THROW 59207, N'The file name prefix and client code can only have letters, digits and a hyphen (at most 30) - they become part of the file name.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE file_code < 100 OR file_code > 999999)
        THROW 59217, N'The file code must be from 100 to 999999 (enter 100 or .100).', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE alert_email IS NOT NULL AND (alert_email LIKE N'%[ ,;]%' OR alert_email NOT LIKE N'%_@_%._%'))
        THROW 59208, N'The alert e-mail is not a valid e-mail address.', 1;
    IF EXISTS (SELECT 1 FROM @rows GROUP BY com_sno, div_sno, brn_sno, ac_number HAVING COUNT(*) > 1)
        OR EXISTS (SELECT 1 FROM @rows GROUP BY com_sno, div_sno, brn_sno, profile_name HAVING COUNT(*) > 1)
        THROW 59209, N'The same bank account appears more than once in this request.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE is_default = 'Y' GROUP BY com_sno, div_sno, brn_sno HAVING COUNT(*) > 1)
        THROW 59210, N'Only one account of a company/division/branch can be its default.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @lk INT;
        EXEC @lk = sp_getapplock @Resource = N'payment_bank_master', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;
        IF @lk < 0 THROW 59213, N'Another bank account is being saved right now - please try again in a moment.', 1;

        IF EXISTS (SELECT 1 FROM @rows r JOIN dbo.payment_bank_master m ON m.com_sno = r.com_sno AND m.div_sno = r.div_sno AND m.brn_sno = r.brn_sno AND m.is_active = 'Y' AND m.ac_number = r.ac_number)
            THROW 59211, N'This company/division/branch already has a bank account with this account number.', 1;
        IF EXISTS (SELECT 1 FROM @rows r JOIN dbo.payment_bank_master m ON m.com_sno = r.com_sno AND m.div_sno = r.div_sno AND m.brn_sno = r.brn_sno AND m.is_active = 'Y' AND m.profile_name = r.profile_name)
            THROW 59212, N'This company/division/branch already has a bank account with this account name.', 1;

        DECLARE @Touched TABLE (payment_bank_sno INT);
        INSERT INTO dbo.payment_bank_master (com_sno, div_sno, brn_sno, profile_name, bank_name, branch_name, ac_holder_name, ac_number, ifsc, file_type, file_prefix, client_code, file_code, alert_email, is_default, created_by)
        OUTPUT INSERTED.payment_bank_sno INTO @Touched
        SELECT com_sno, div_sno, brn_sno, profile_name, bank_name, branch_name, ac_holder_name, ac_number, ifsc, file_type, file_prefix, client_code, file_code, alert_email, is_default, created_by
        FROM @rows ORDER BY rn;

        -- a new default takes the flag from the company's previous default
        UPDATE m SET is_default = 'N', modified_at = GETDATE()
        FROM dbo.payment_bank_master m
        JOIN dbo.payment_bank_master n ON n.com_sno = m.com_sno AND n.div_sno = m.div_sno AND n.brn_sno = m.brn_sno
                                      AND n.is_default = 'Y' AND n.payment_bank_sno IN (SELECT payment_bank_sno FROM @Touched)
        WHERE m.payment_bank_sno <> n.payment_bank_sno AND m.is_active = 'Y' AND m.is_default = 'Y';
        -- the first account of a company is its default
        UPDATE m SET is_default = 'Y'
        FROM dbo.payment_bank_master m
        WHERE m.is_active = 'Y' AND m.payment_bank_sno IN (SELECT payment_bank_sno FROM @Touched)
          AND NOT EXISTS (SELECT 1 FROM dbo.payment_bank_master d WHERE d.com_sno = m.com_sno AND d.div_sno = m.div_sno AND d.brn_sno = m.brn_sno AND d.is_active = 'Y' AND d.is_default = 'Y')
          AND m.payment_bank_sno = (SELECT MIN(y.payment_bank_sno) FROM dbo.payment_bank_master y WHERE y.com_sno = m.com_sno AND y.div_sno = m.div_sno AND y.brn_sno = m.brn_sno AND y.is_active = 'Y');

        COMMIT TRANSACTION;

        SELECT m.payment_bank_sno, m.com_sno, c.com_name, m.div_sno, d.div_name, m.brn_sno, b.brn_name,
               m.profile_name, m.bank_name, m.branch_name, m.ac_holder_name, m.ac_number, m.ifsc,
               m.file_type, m.file_prefix, m.client_code, m.file_code, m.alert_email, m.is_default, m.is_active
        FROM dbo.payment_bank_master m
        JOIN @Touched t ON t.payment_bank_sno = m.payment_bank_sno
        LEFT JOIN dbo.company_master c ON c.com_sno = m.com_sno
        LEFT JOIN dbo.division_master d ON d.div_sno = m.div_sno
        LEFT JOIN dbo.branch_master b ON b.brn_sno = m.brn_sno
        ORDER BY m.payment_bank_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ── update ──────────────────────────────────────────────────────────────────
-- @jsonInput: { id | payment_bank_sno, <any field to change> }. A key that is present (even blank) sets branch_name / alert_email,
-- so they can be cleared; an absent key leaves them alone. The required fields cannot be blanked.
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdatePaymentBankRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_bank_sno') AS INT);
    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.payment_bank_master WHERE payment_bank_sno = @id AND is_active = 'Y')
        THROW 59214, N'Bank account not found.', 1;

    -- Working values are NVARCHAR(MAX) so a too-long value is caught by the checks below instead of being cut to the column size.
    DECLARE @com INT, @div INT, @brn INT, @file_code INT,
            @profile NVARCHAR(MAX), @bank NVARCHAR(MAX), @branch NVARCHAR(MAX), @holder NVARCHAR(MAX), @acno NVARCHAR(MAX), @ifsc NVARCHAR(MAX),
            @ftype NVARCHAR(MAX), @prefix NVARCHAR(MAX), @client NVARCHAR(MAX), @email NVARCHAR(MAX), @default CHAR(1);
    SELECT @com = com_sno, @div = div_sno, @brn = brn_sno, @profile = profile_name, @bank = bank_name, @branch = branch_name,
           @holder = ac_holder_name, @acno = ac_number, @ifsc = ifsc, @ftype = file_type, @prefix = file_prefix, @client = client_code,
           @file_code = file_code, @email = alert_email, @default = is_default
    FROM dbo.payment_bank_master WHERE payment_bank_sno = @id;

    -- what the request changes: a blank required field means "no change"
    DECLARE @n_com INT = TRY_CAST(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.com_sno'))), N'') AS INT),
            @n_div INT = TRY_CAST(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.div_sno'))), N'') AS INT),
            @n_brn INT = TRY_CAST(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.brn_sno'))), N'') AS INT),
            @n_profile NVARCHAR(MAX) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.profile_name'))), N''),
            @n_bank    NVARCHAR(MAX) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.bank_name'))), N''),
            @n_holder  NVARCHAR(MAX) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.ac_holder_name'))), N''),
            @n_acno    NVARCHAR(MAX) = NULLIF(REPLACE(REPLACE(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.ac_number'))), N' ', N''), N'-', N''), N''),
            @n_ifsc    NVARCHAR(MAX) = NULLIF(UPPER(REPLACE(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.ifsc'))), N' ', N'')), N''),
            @n_ftype   NVARCHAR(MAX) = NULLIF(UPPER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.file_type')))), N''),
            @n_prefix  NVARCHAR(MAX) = NULLIF(UPPER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.file_prefix')))), N''),
            @n_client  NVARCHAR(MAX) = NULLIF(UPPER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.client_code')))), N''),
            @n_file_code INT = TRY_CAST(REPLACE(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.file_code'))), N'.', N'') AS INT),
            @n_default NVARCHAR(10)  = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.is_default'))), N'');
    SELECT @com = ISNULL(@n_com, @com), @div = ISNULL(@n_div, @div), @brn = ISNULL(@n_brn, @brn),
           @profile = ISNULL(@n_profile, @profile), @bank = ISNULL(@n_bank, @bank), @holder = ISNULL(@n_holder, @holder),
           @acno = ISNULL(@n_acno, @acno), @ifsc = ISNULL(@n_ifsc, @ifsc), @ftype = ISNULL(@n_ftype, @ftype),
           @prefix = ISNULL(@n_prefix, @prefix), @client = ISNULL(@n_client, @client), @file_code = ISNULL(@n_file_code, @file_code),
           @default = CASE WHEN @n_default IS NULL THEN @default WHEN UPPER(@n_default) IN (N'Y', N'YES', N'TRUE', N'1') THEN 'Y' ELSE 'N' END;
    -- branch and e-mail are optional: a key that is present (even blank) sets them, so they can be cleared
    IF EXISTS (SELECT 1 FROM OPENJSON(@jsonInput) WHERE [key] = 'branch_name') SET @branch = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.branch_name'))), N'');
    IF EXISTS (SELECT 1 FROM OPENJSON(@jsonInput) WHERE [key] = 'alert_email') SET @email  = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.alert_email'))), N'');

    IF NOT EXISTS (SELECT 1 FROM dbo.company_master WHERE com_sno = @com) THROW 59202, N'Company not found.', 1;
    IF @div IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.division_master WHERE div_sno = @div AND com_sno = @com AND ISNULL(is_active, 'Y') = 'Y')
        THROW 59215, N'The division does not belong to the selected company.', 1;
    IF @brn IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.branch_master WHERE brn_sno = @brn AND div_sno = @div AND ISNULL(is_active, 'Y') = 'Y')
        THROW 59216, N'The branch does not belong to the selected division.', 1;
    IF LEN(@profile) > 100 OR LEN(@bank) > 100 OR LEN(@branch) > 100 OR LEN(@holder) > 100 OR LEN(@email) > 100
        THROW 59203, N'Account name, bank, branch and account holder can be at most 100 characters; the e-mail at most 100.', 1;
    IF @acno LIKE N'%[^0-9]%' COLLATE Latin1_General_BIN2 OR LEN(@acno) < 6 OR LEN(@acno) > 30 THROW 59204, N'The account number must be 6 to 30 digits.', 1;
    IF LEN(@ifsc) <> 11 OR @ifsc NOT LIKE N'[A-Z][A-Z][A-Z][A-Z]0[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]' COLLATE Latin1_General_BIN2
        THROW 59205, N'The IFSC must be 11 characters: 4 letters, a zero, then 6 letters or digits (e.g. HDFC0000123).', 1;
    IF @ftype NOT IN (N'BANK_UPLOAD') THROW 59206, N'Unknown payment file type. Choose one from the list.', 1;
    IF @prefix LIKE N'%[^A-Z0-9-]%' COLLATE Latin1_General_BIN2 OR @client LIKE N'%[^A-Z0-9-]%' COLLATE Latin1_General_BIN2 OR LEN(@prefix) > 30 OR LEN(@client) > 30
        THROW 59207, N'The file name prefix and client code can only have letters, digits and a hyphen (at most 30) - they become part of the file name.', 1;
    IF @file_code < 100 OR @file_code > 999999 THROW 59217, N'The file code must be from 100 to 999999 (enter 100 or .100).', 1;
    IF @email IS NOT NULL AND (@email LIKE N'%[ ,;]%' OR @email NOT LIKE N'%_@_%._%') THROW 59208, N'The alert e-mail is not a valid e-mail address.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @lk INT;
        EXEC @lk = sp_getapplock @Resource = N'payment_bank_master', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;
        IF @lk < 0 THROW 59213, N'Another bank account is being saved right now - please try again in a moment.', 1;

        IF EXISTS (SELECT 1 FROM dbo.payment_bank_master WHERE com_sno = @com AND div_sno = @div AND brn_sno = @brn AND is_active = 'Y' AND ac_number = @acno AND payment_bank_sno <> @id)
            THROW 59211, N'This company/division/branch already has a bank account with this account number.', 1;
        IF EXISTS (SELECT 1 FROM dbo.payment_bank_master WHERE com_sno = @com AND div_sno = @div AND brn_sno = @brn AND is_active = 'Y' AND profile_name = @profile AND payment_bank_sno <> @id)
            THROW 59212, N'This company/division/branch already has a bank account with this account name.', 1;

        UPDATE dbo.payment_bank_master
        SET com_sno = @com, div_sno = @div, brn_sno = @brn, profile_name = @profile, bank_name = @bank, branch_name = @branch,
            ac_holder_name = @holder, ac_number = @acno, ifsc = @ifsc,
            file_type = @ftype, file_prefix = @prefix, client_code = @client, file_code = @file_code, alert_email = @email, is_default = @default,
            modified_by = JSON_VALUE(@jsonInput, '$.modified_by'), modified_at = GETDATE()
        WHERE payment_bank_sno = @id;

        IF @default = 'Y'
            UPDATE dbo.payment_bank_master SET is_default = 'N', modified_at = GETDATE()
            WHERE com_sno = @com AND div_sno = @div AND brn_sno = @brn AND payment_bank_sno <> @id AND is_active = 'Y' AND is_default = 'Y';

        COMMIT TRANSACTION;

        SELECT m.payment_bank_sno, m.com_sno, c.com_name, m.div_sno, d.div_name, m.brn_sno, b.brn_name,
               m.profile_name, m.bank_name, m.branch_name, m.ac_holder_name, m.ac_number, m.ifsc,
               m.file_type, m.file_prefix, m.client_code, m.file_code, m.alert_email, m.is_default, m.is_active
        FROM dbo.payment_bank_master m
        LEFT JOIN dbo.company_master c ON c.com_sno = m.com_sno
        LEFT JOIN dbo.division_master d ON d.div_sno = m.div_sno
        LEFT JOIN dbo.branch_master b ON b.brn_sno = m.brn_sno
        WHERE m.payment_bank_sno = @id;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ── delete (soft) ───────────────────────────────────────────────────────────
-- A past run keeps its own copy of the sender (payment_batch.sender_*), so a switched-off account does not change history.
CREATE OR ALTER PROCEDURE dbo.sp_nt_DeletePaymentBankRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.payment_bank_master WHERE payment_bank_sno = @id AND is_active = 'Y')
        THROW 59214, N'Bank account not found.', 1;

    UPDATE dbo.payment_bank_master SET is_active = 'N', is_default = 'N', modified_at = GETDATE() WHERE payment_bank_sno = @id;
    SELECT @id AS payment_bank_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO
