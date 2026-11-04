-- ============================================================================
-- 149_bank_file_format_master.sql   (Non_trade_Dev, re-runnable)
--
-- Bank File Format masters: the layout of the payment file is no longer fixed in code, it is defined here, bank by bank.
--
--   bank_file_format         one row per layout: name, separator, header line yes/no, line ending, quote text yes/no
--   bank_file_format_column  one row per field of the layout: position, header, WHERE THE VALUE COMES FROM (source_field - a fixed
--                            list: account no, amount, IFSC, payment date, sender account ...), fixed text, max length, padding, date format
--   payment_bank_master      gains file_format_sno: the layout that bank account's Payment Run file is written in.
--                            Blank = the built-in "standard 28-position" layout, so every existing account keeps producing the same file.
--
-- The built-in layout is also seeded as a format ("Standard 28-position (NEFT / RTGS)") so it can be copied for a new bank.
-- Registered as master keys BankFileFormatMaster and BankFileFormatColumnMaster (Masters > Finance). Global reference data (no org scope).
-- Delete is a soft delete; a format that a bank account still uses cannot be deleted.
-- Re-defines the three payment_bank_master procedures of sql/138 (list / create / update) with file_format_sno added - generated from 138.
-- Rollback: sql/backups/bank_file_format_2026-11-03_ROLLBACK.sql
-- ============================================================================

IF OBJECT_ID('dbo.bank_file_format', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.bank_file_format (
        format_sno   INT IDENTITY(1,1) NOT NULL,
        format_name  NVARCHAR(100) NOT NULL,
        delimiter    VARCHAR(10)   NOT NULL CONSTRAINT DF_bank_file_format_delimiter DEFAULT 'COMMA',   -- COMMA / PIPE / TAB / SEMICOLON / NONE (no separator, fixed width)
        has_header   CHAR(1)       NOT NULL CONSTRAINT DF_bank_file_format_has_header DEFAULT 'N',      -- first line = the column headers
        line_ending  VARCHAR(4)    NOT NULL CONSTRAINT DF_bank_file_format_line_ending DEFAULT 'LF',    -- LF / CRLF
        quote_text   CHAR(1)       NOT NULL CONSTRAINT DF_bank_file_format_quote_text DEFAULT 'N',      -- wrap every value in double quotes
        remarks      NVARCHAR(300) NULL,
        is_active    CHAR(1)       NOT NULL CONSTRAINT DF_bank_file_format_is_active DEFAULT 'Y',
        created_by   VARCHAR(30)   NULL,
        created_at   DATETIME      NOT NULL CONSTRAINT DF_bank_file_format_created_at DEFAULT GETDATE(),
        modified_by  VARCHAR(30)   NULL,
        modified_at  DATETIME      NULL,
        CONSTRAINT PK_bank_file_format PRIMARY KEY (format_sno),
        CONSTRAINT CK_bank_file_format_delimiter CHECK (delimiter IN ('COMMA', 'PIPE', 'TAB', 'SEMICOLON', 'NONE')),
        CONSTRAINT CK_bank_file_format_has_header CHECK (has_header IN ('Y', 'N')),
        CONSTRAINT CK_bank_file_format_line_ending CHECK (line_ending IN ('LF', 'CRLF')),
        CONSTRAINT CK_bank_file_format_quote_text CHECK (quote_text IN ('Y', 'N')),
        CONSTRAINT CK_bank_file_format_is_active CHECK (is_active IN ('Y', 'N'))
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_bank_file_format_name' AND object_id = OBJECT_ID('dbo.bank_file_format'))
    CREATE UNIQUE INDEX UX_bank_file_format_name ON dbo.bank_file_format (format_name) WHERE is_active = 'Y';
GO

IF OBJECT_ID('dbo.bank_file_format_column', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.bank_file_format_column (
        column_sno   INT IDENTITY(1,1) NOT NULL,
        format_sno   INT           NOT NULL,
        position     INT           NOT NULL,                  -- 1-based place of the field on the line
        header_text  NVARCHAR(100) NULL,                      -- written on the header line when the format has one
        source_field VARCHAR(30)   NOT NULL,                  -- where the value comes from (list in the procedures below / grn-service bankFileFormat.js)
        fixed_value  NVARCHAR(100) NULL,                      -- the text when source_field = FIXED
        max_len      INT           NULL,                      -- cut the value to this many characters
        pad_side     CHAR(1)       NULL,                      -- L = pad on the left, R = pad on the right (needs max_len + pad_char)
        pad_char     CHAR(1)       NULL,
        date_format  VARCHAR(12)   NULL,                      -- for PAYMENT_DATE: DD/MM/YYYY, DD-MM-YYYY, YYYY-MM-DD, DDMMYYYY, YYYYMMDD
        is_active    CHAR(1)       NOT NULL CONSTRAINT DF_bank_file_format_column_is_active DEFAULT 'Y',
        created_by   VARCHAR(30)   NULL,
        created_at   DATETIME      NOT NULL CONSTRAINT DF_bank_file_format_column_created_at DEFAULT GETDATE(),
        modified_by  VARCHAR(30)   NULL,
        modified_at  DATETIME      NULL,
        CONSTRAINT PK_bank_file_format_column PRIMARY KEY (column_sno),
        CONSTRAINT FK_bank_file_format_column_format FOREIGN KEY (format_sno) REFERENCES dbo.bank_file_format (format_sno),
        CONSTRAINT CK_bank_file_format_column_position CHECK (position BETWEEN 1 AND 200),
        CONSTRAINT CK_bank_file_format_column_pad CHECK (pad_side IS NULL OR (pad_side IN ('L', 'R') AND pad_char IS NOT NULL AND max_len IS NOT NULL)),
        CONSTRAINT CK_bank_file_format_column_is_active CHECK (is_active IN ('Y', 'N'))
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_bank_file_format_column_pos' AND object_id = OBJECT_ID('dbo.bank_file_format_column'))
    CREATE UNIQUE INDEX UX_bank_file_format_column_pos ON dbo.bank_file_format_column (format_sno, position) WHERE is_active = 'Y';
GO

IF COL_LENGTH('dbo.payment_bank_master', 'file_format_sno') IS NULL ALTER TABLE dbo.payment_bank_master ADD file_format_sno INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_payment_bank_master_file_format')
    ALTER TABLE dbo.payment_bank_master ADD CONSTRAINT FK_payment_bank_master_file_format FOREIGN KEY (file_format_sno) REFERENCES dbo.bank_file_format (format_sno);
GO

-- ── seed: the built-in layout, as a format ──────────────────────────────────
-- 28 comma-separated positions, no header, LF. Must stay in step with grn-service paymentFile.js (a test compares the two).
IF NOT EXISTS (SELECT 1 FROM dbo.bank_file_format WHERE format_name = N'Standard 28-position (NEFT / RTGS)')
BEGIN
    INSERT INTO dbo.bank_file_format (format_name, delimiter, has_header, line_ending, quote_text, remarks, created_by)
    VALUES (N'Standard 28-position (NEFT / RTGS)', 'COMMA', 'N', 'LF', 'N', N'The layout built into the system. Copy its columns to start a new bank''s format.', 'SYSTEM');
    DECLARE @std INT = SCOPE_IDENTITY();
    INSERT INTO dbo.bank_file_format_column (format_sno, position, header_text, source_field, fixed_value, max_len, date_format, created_by)
    SELECT @std, v.pos, v.hdr, v.src, NULL, v.mx, v.df, 'SYSTEM'
    FROM (VALUES
        (1,  N'Transfer type',    'TRANSFER_TYPE',     NULL, NULL),
        (2,  N'',                 'BLANK',             NULL, NULL),
        (3,  N'Account number',   'ACCOUNT_NO',        NULL, NULL),
        (4,  N'Amount',           'AMOUNT',            NULL, NULL),
        (5,  N'Name',             'BENEFICIARY_NAME',  20,   NULL),
        (6,  N'',                 'BLANK',             NULL, NULL), (7,  N'', 'BLANK', NULL, NULL), (8,  N'', 'BLANK', NULL, NULL),
        (9,  N'',                 'BLANK',             NULL, NULL), (10, N'', 'BLANK', NULL, NULL), (11, N'', 'BLANK', NULL, NULL),
        (12, N'',                 'BLANK',             NULL, NULL), (13, N'', 'BLANK', NULL, NULL),
        (14, N'Reference',        'REFERENCE',         NULL, NULL),
        (15, N'Payment details 1','DETAIL_1',          NULL, NULL),
        (16, N'Payment details 2','DETAIL_2',          NULL, NULL),
        (17, N'Payment details 3','DETAIL_3',          NULL, NULL),
        (18, N'',                 'BLANK',             NULL, NULL), (19, N'', 'BLANK', NULL, NULL), (20, N'', 'BLANK', NULL, NULL),
        (21, N'',                 'BLANK',             NULL, NULL), (22, N'', 'BLANK', NULL, NULL),
        (23, N'Payment date',     'PAYMENT_DATE',      NULL, 'DD/MM/YYYY'),
        (24, N'',                 'BLANK',             NULL, NULL),
        (25, N'IFSC',             'IFSC',              NULL, NULL),
        (26, N'Bank',             'BANK_NAME',         NULL, NULL),
        (27, N'Branch',           'BRANCH_NAME',       NULL, NULL),
        (28, N'',                 'BLANK',             NULL, NULL)
    ) v (pos, hdr, src, mx, df);
END;
GO

-- ── Bank File Format: list / create / update / delete ───────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetBankFileFormatRecords
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.format_sno, f.format_name, f.delimiter, f.has_header, f.line_ending, f.quote_text, f.remarks, f.is_active,
           (SELECT COUNT(*) FROM dbo.bank_file_format_column c WHERE c.format_sno = f.format_sno AND c.is_active = 'Y') AS column_count
    FROM dbo.bank_file_format f
    WHERE f.is_active = 'Y'
    ORDER BY f.format_name;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateBankFileFormatRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 50000, N'Invalid JSON payload provided.', 1;
    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    DECLARE @rows TABLE (rn INT IDENTITY(1,1), format_name NVARCHAR(MAX), delimiter NVARCHAR(MAX), has_header CHAR(1), line_ending NVARCHAR(MAX),
                         quote_text CHAR(1), remarks NVARCHAR(MAX), created_by VARCHAR(30));
    INSERT INTO @rows (format_name, delimiter, has_header, line_ending, quote_text, remarks, created_by)
    SELECT NULLIF(LTRIM(RTRIM(format_name)), N''),
           ISNULL(NULLIF(UPPER(LTRIM(RTRIM(delimiter))), N''), N'COMMA'),
           CASE WHEN UPPER(LTRIM(RTRIM(has_header))) IN (N'Y', N'YES', N'TRUE', N'1') THEN 'Y' ELSE 'N' END,
           ISNULL(NULLIF(UPPER(LTRIM(RTRIM(line_ending))), N''), N'LF'),
           CASE WHEN UPPER(LTRIM(RTRIM(quote_text))) IN (N'Y', N'YES', N'TRUE', N'1') THEN 'Y' ELSE 'N' END,
           NULLIF(LTRIM(RTRIM(remarks)), N''), created_by
    FROM OPENJSON(@json) WITH (format_name NVARCHAR(MAX) '$.format_name', delimiter NVARCHAR(MAX) '$.delimiter', has_header NVARCHAR(10) '$.has_header',
                               line_ending NVARCHAR(MAX) '$.line_ending', quote_text NVARCHAR(10) '$.quote_text', remarks NVARCHAR(MAX) '$.remarks', created_by VARCHAR(30) '$.created_by');

    IF NOT EXISTS (SELECT 1 FROM @rows) THROW 59231, N'At least one bank file format is required.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE format_name IS NULL) THROW 59231, N'The format name is required.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE LEN(format_name) > 100 OR LEN(remarks) > 300) THROW 59232, N'The format name can be at most 100 characters and the remarks 300.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE delimiter NOT IN (N'COMMA', N'PIPE', N'TAB', N'SEMICOLON', N'NONE')) THROW 59233, N'The separator must be COMMA, PIPE, TAB, SEMICOLON or NONE.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE line_ending NOT IN (N'LF', N'CRLF')) THROW 59234, N'The line ending must be LF or CRLF.', 1;
    IF EXISTS (SELECT 1 FROM @rows GROUP BY format_name HAVING COUNT(*) > 1) THROW 59235, N'The same format name appears more than once in this request.', 1;
    IF EXISTS (SELECT 1 FROM @rows r JOIN dbo.bank_file_format f ON f.format_name = r.format_name AND f.is_active = 'Y') THROW 59235, N'A bank file format with this name already exists.', 1;

    DECLARE @Touched TABLE (format_sno INT);
    INSERT INTO dbo.bank_file_format (format_name, delimiter, has_header, line_ending, quote_text, remarks, created_by)
    OUTPUT INSERTED.format_sno INTO @Touched
    SELECT format_name, delimiter, has_header, line_ending, quote_text, remarks, created_by FROM @rows ORDER BY rn;

    SELECT f.format_sno, f.format_name, f.delimiter, f.has_header, f.line_ending, f.quote_text, f.remarks, f.is_active, 0 AS column_count
    FROM dbo.bank_file_format f JOIN @Touched t ON t.format_sno = f.format_sno ORDER BY f.format_sno;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateBankFileFormatRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 50000, N'Invalid JSON payload provided.', 1;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.format_sno') AS INT);
    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.bank_file_format WHERE format_sno = @id AND is_active = 'Y') THROW 59236, N'Bank file format not found.', 1;

    DECLARE @name NVARCHAR(MAX), @delim NVARCHAR(MAX), @header CHAR(1), @eol NVARCHAR(MAX), @quote CHAR(1), @remarks NVARCHAR(MAX);
    SELECT @name = format_name, @delim = delimiter, @header = has_header, @eol = line_ending, @quote = quote_text, @remarks = remarks
    FROM dbo.bank_file_format WHERE format_sno = @id;

    DECLARE @n_name NVARCHAR(MAX) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.format_name'))), N''),
            @n_delim NVARCHAR(MAX) = NULLIF(UPPER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.delimiter')))), N''),
            @n_header NVARCHAR(10) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.has_header'))), N''),
            @n_eol NVARCHAR(MAX) = NULLIF(UPPER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.line_ending')))), N''),
            @n_quote NVARCHAR(10) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.quote_text'))), N'');
    SELECT @name = ISNULL(@n_name, @name), @delim = ISNULL(@n_delim, @delim), @eol = ISNULL(@n_eol, @eol),
           @header = CASE WHEN @n_header IS NULL THEN @header WHEN UPPER(@n_header) IN (N'Y', N'YES', N'TRUE', N'1') THEN 'Y' ELSE 'N' END,
           @quote  = CASE WHEN @n_quote  IS NULL THEN @quote  WHEN UPPER(@n_quote)  IN (N'Y', N'YES', N'TRUE', N'1') THEN 'Y' ELSE 'N' END;
    IF EXISTS (SELECT 1 FROM OPENJSON(@jsonInput) WHERE [key] = 'remarks') SET @remarks = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.remarks'))), N'');

    IF LEN(@name) > 100 OR LEN(@remarks) > 300 THROW 59232, N'The format name can be at most 100 characters and the remarks 300.', 1;
    IF @delim NOT IN (N'COMMA', N'PIPE', N'TAB', N'SEMICOLON', N'NONE') THROW 59233, N'The separator must be COMMA, PIPE, TAB, SEMICOLON or NONE.', 1;
    IF @eol NOT IN (N'LF', N'CRLF') THROW 59234, N'The line ending must be LF or CRLF.', 1;
    IF EXISTS (SELECT 1 FROM dbo.bank_file_format WHERE format_name = @name AND is_active = 'Y' AND format_sno <> @id) THROW 59235, N'A bank file format with this name already exists.', 1;

    UPDATE dbo.bank_file_format SET format_name = @name, delimiter = @delim, has_header = @header, line_ending = @eol, quote_text = @quote, remarks = @remarks,
           modified_by = JSON_VALUE(@jsonInput, '$.modified_by'), modified_at = GETDATE()
    WHERE format_sno = @id;

    SELECT f.format_sno, f.format_name, f.delimiter, f.has_header, f.line_ending, f.quote_text, f.remarks, f.is_active,
           (SELECT COUNT(*) FROM dbo.bank_file_format_column c WHERE c.format_sno = f.format_sno AND c.is_active = 'Y') AS column_count
    FROM dbo.bank_file_format f WHERE f.format_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteBankFileFormatRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.bank_file_format WHERE format_sno = @id AND is_active = 'Y') THROW 59236, N'Bank file format not found.', 1;
    IF EXISTS (SELECT 1 FROM dbo.payment_bank_master WHERE file_format_sno = @id AND is_active = 'Y')
        THROW 59237, N'This format is still used by a Payment Bank account - choose another format for that account first.', 1;
    UPDATE dbo.bank_file_format SET is_active = 'N', modified_at = GETDATE() WHERE format_sno = @id;
    UPDATE dbo.bank_file_format_column SET is_active = 'N', modified_at = GETDATE() WHERE format_sno = @id AND is_active = 'Y';
    SELECT @id AS format_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO

-- ── Bank File Format Column: list / create / update / delete ────────────────
-- source_field values: TRANSFER_TYPE (N/R) MODE (NEFT/RTGS) ACCOUNT_NO AMOUNT BENEFICIARY_NAME REFERENCE PAYMENT_NO SUPPLIER_CODE
--   DETAIL_1 DETAIL_2 DETAIL_3 PAYMENT_DATE IFSC BANK_NAME BRANCH_NAME SERIAL_NO SENDER_ACCOUNT_NO SENDER_NAME SENDER_IFSC SENDER_BANK_NAME
--   SENDER_CLIENT_CODE SENDER_EMAIL FIXED BLANK
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetBankFileFormatColumnRecords
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.column_sno, c.format_sno, f.format_name, c.position, c.header_text, c.source_field, c.fixed_value, c.max_len, c.pad_side, c.pad_char, c.date_format, c.is_active
    FROM dbo.bank_file_format_column c
    JOIN dbo.bank_file_format f ON f.format_sno = c.format_sno AND f.is_active = 'Y'
    WHERE c.is_active = 'Y'
    ORDER BY f.format_name, c.position;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateBankFileFormatColumnRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 50000, N'Invalid JSON payload provided.', 1;
    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    DECLARE @rows TABLE (rn INT IDENTITY(1,1), format_sno INT, position INT, header_text NVARCHAR(MAX), source_field NVARCHAR(MAX), fixed_value NVARCHAR(MAX),
                         max_len INT, pad_side NVARCHAR(MAX), pad_char NVARCHAR(MAX), date_format NVARCHAR(MAX), created_by VARCHAR(30));
    INSERT INTO @rows (format_sno, position, header_text, source_field, fixed_value, max_len, pad_side, pad_char, date_format, created_by)
    SELECT TRY_CAST(NULLIF(LTRIM(RTRIM(format_sno)), N'') AS INT), TRY_CAST(NULLIF(LTRIM(RTRIM(position)), N'') AS INT),
           NULLIF(LTRIM(RTRIM(header_text)), N''), NULLIF(UPPER(LTRIM(RTRIM(source_field))), N''), NULLIF(LTRIM(RTRIM(fixed_value)), N''),
           TRY_CAST(NULLIF(LTRIM(RTRIM(max_len)), N'') AS INT), NULLIF(UPPER(LTRIM(RTRIM(pad_side))), N''), NULLIF(pad_char, N''),
           NULLIF(UPPER(LTRIM(RTRIM(date_format))), N''), created_by
    FROM OPENJSON(@json) WITH (format_sno NVARCHAR(30) '$.format_sno', position NVARCHAR(30) '$.position', header_text NVARCHAR(MAX) '$.header_text',
                               source_field NVARCHAR(MAX) '$.source_field', fixed_value NVARCHAR(MAX) '$.fixed_value', max_len NVARCHAR(30) '$.max_len',
                               pad_side NVARCHAR(MAX) '$.pad_side', pad_char NVARCHAR(MAX) '$.pad_char', date_format NVARCHAR(MAX) '$.date_format', created_by VARCHAR(30) '$.created_by');

    IF NOT EXISTS (SELECT 1 FROM @rows) THROW 59238, N'At least one format column is required.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE format_sno IS NULL OR position IS NULL OR source_field IS NULL) THROW 59238, N'Format, position and source field are required.', 1;
    IF EXISTS (SELECT 1 FROM @rows r WHERE NOT EXISTS (SELECT 1 FROM dbo.bank_file_format f WHERE f.format_sno = r.format_sno AND f.is_active = 'Y')) THROW 59236, N'Bank file format not found.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE position < 1 OR position > 200) THROW 59239, N'The position must be from 1 to 200.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE source_field NOT IN (N'TRANSFER_TYPE', N'MODE', N'ACCOUNT_NO', N'AMOUNT', N'BENEFICIARY_NAME', N'REFERENCE', N'PAYMENT_NO', N'SUPPLIER_CODE',
                                                              N'DETAIL_1', N'DETAIL_2', N'DETAIL_3', N'PAYMENT_DATE', N'IFSC', N'BANK_NAME', N'BRANCH_NAME', N'SERIAL_NO',
                                                              N'SENDER_ACCOUNT_NO', N'SENDER_NAME', N'SENDER_IFSC', N'SENDER_BANK_NAME', N'SENDER_CLIENT_CODE', N'SENDER_EMAIL', N'FIXED', N'BLANK'))
        THROW 59240, N'Unknown source field. Choose one from the list.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE source_field = N'FIXED' AND fixed_value IS NULL) THROW 59241, N'A FIXED column needs the fixed text.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE max_len IS NOT NULL AND (max_len < 1 OR max_len > 500)) THROW 59242, N'The maximum length must be from 1 to 500.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE pad_side IS NOT NULL AND (pad_side NOT IN (N'L', N'R') OR pad_char IS NULL OR LEN(pad_char) <> 1 OR max_len IS NULL)) THROW 59243, N'Padding needs a side (L or R), ONE pad character and a maximum length.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE date_format IS NOT NULL AND date_format NOT IN (N'DD/MM/YYYY', N'DD-MM-YYYY', N'YYYY-MM-DD', N'DDMMYYYY', N'YYYYMMDD')) THROW 59244, N'The date format must be DD/MM/YYYY, DD-MM-YYYY, YYYY-MM-DD, DDMMYYYY or YYYYMMDD.', 1;
    IF EXISTS (SELECT 1 FROM @rows GROUP BY format_sno, position HAVING COUNT(*) > 1) THROW 59245, N'The same position appears more than once in this request.', 1;
    IF EXISTS (SELECT 1 FROM @rows r JOIN dbo.bank_file_format_column c ON c.format_sno = r.format_sno AND c.position = r.position AND c.is_active = 'Y') THROW 59245, N'This format already has a column at this position.', 1;

    DECLARE @Touched TABLE (column_sno INT);
    INSERT INTO dbo.bank_file_format_column (format_sno, position, header_text, source_field, fixed_value, max_len, pad_side, pad_char, date_format, created_by)
    OUTPUT INSERTED.column_sno INTO @Touched
    SELECT format_sno, position, header_text, source_field, fixed_value, max_len, pad_side, pad_char, date_format, created_by FROM @rows ORDER BY rn;

    SELECT c.column_sno, c.format_sno, f.format_name, c.position, c.header_text, c.source_field, c.fixed_value, c.max_len, c.pad_side, c.pad_char, c.date_format, c.is_active
    FROM dbo.bank_file_format_column c JOIN @Touched t ON t.column_sno = c.column_sno JOIN dbo.bank_file_format f ON f.format_sno = c.format_sno ORDER BY c.column_sno;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateBankFileFormatColumnRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 50000, N'Invalid JSON payload provided.', 1;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.column_sno') AS INT);
    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.bank_file_format_column WHERE column_sno = @id AND is_active = 'Y') THROW 59246, N'Format column not found.', 1;

    DECLARE @fmt INT, @pos INT, @hdr NVARCHAR(MAX), @src NVARCHAR(MAX), @fix NVARCHAR(MAX), @mx INT, @side NVARCHAR(MAX), @pc NVARCHAR(MAX), @df NVARCHAR(MAX);
    SELECT @fmt = format_sno, @pos = position, @hdr = header_text, @src = source_field, @fix = fixed_value, @mx = max_len, @side = pad_side, @pc = pad_char, @df = date_format
    FROM dbo.bank_file_format_column WHERE column_sno = @id;

    DECLARE @n_fmt INT = TRY_CAST(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.format_sno'))), N'') AS INT),
            @n_pos INT = TRY_CAST(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.position'))), N'') AS INT),
            @n_src NVARCHAR(MAX) = NULLIF(UPPER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.source_field')))), N'');
    SELECT @fmt = ISNULL(@n_fmt, @fmt), @pos = ISNULL(@n_pos, @pos), @src = ISNULL(@n_src, @src);
    -- optional fields: a key that is present (even blank) sets them, so they can be cleared
    IF EXISTS (SELECT 1 FROM OPENJSON(@jsonInput) WHERE [key] = 'header_text') SET @hdr = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.header_text'))), N'');
    IF EXISTS (SELECT 1 FROM OPENJSON(@jsonInput) WHERE [key] = 'fixed_value') SET @fix = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.fixed_value'))), N'');
    IF EXISTS (SELECT 1 FROM OPENJSON(@jsonInput) WHERE [key] = 'max_len') SET @mx = TRY_CAST(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.max_len'))), N'') AS INT);
    IF EXISTS (SELECT 1 FROM OPENJSON(@jsonInput) WHERE [key] = 'pad_side') SET @side = NULLIF(UPPER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.pad_side')))), N'');
    IF EXISTS (SELECT 1 FROM OPENJSON(@jsonInput) WHERE [key] = 'pad_char') SET @pc = NULLIF(JSON_VALUE(@jsonInput, '$.pad_char'), N'');
    IF EXISTS (SELECT 1 FROM OPENJSON(@jsonInput) WHERE [key] = 'date_format') SET @df = NULLIF(UPPER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.date_format')))), N'');
    IF @side IS NULL SET @pc = NULL;

    IF NOT EXISTS (SELECT 1 FROM dbo.bank_file_format WHERE format_sno = @fmt AND is_active = 'Y') THROW 59236, N'Bank file format not found.', 1;
    IF @pos < 1 OR @pos > 200 THROW 59239, N'The position must be from 1 to 200.', 1;
    IF @src NOT IN (N'TRANSFER_TYPE', N'MODE', N'ACCOUNT_NO', N'AMOUNT', N'BENEFICIARY_NAME', N'REFERENCE', N'PAYMENT_NO', N'SUPPLIER_CODE', N'DETAIL_1', N'DETAIL_2', N'DETAIL_3',
                    N'PAYMENT_DATE', N'IFSC', N'BANK_NAME', N'BRANCH_NAME', N'SERIAL_NO', N'SENDER_ACCOUNT_NO', N'SENDER_NAME', N'SENDER_IFSC', N'SENDER_BANK_NAME',
                    N'SENDER_CLIENT_CODE', N'SENDER_EMAIL', N'FIXED', N'BLANK') THROW 59240, N'Unknown source field. Choose one from the list.', 1;
    IF @src = N'FIXED' AND @fix IS NULL THROW 59241, N'A FIXED column needs the fixed text.', 1;
    IF @mx IS NOT NULL AND (@mx < 1 OR @mx > 500) THROW 59242, N'The maximum length must be from 1 to 500.', 1;
    IF @side IS NOT NULL AND (@side NOT IN (N'L', N'R') OR @pc IS NULL OR LEN(@pc) <> 1 OR @mx IS NULL) THROW 59243, N'Padding needs a side (L or R), ONE pad character and a maximum length.', 1;
    IF @df IS NOT NULL AND @df NOT IN (N'DD/MM/YYYY', N'DD-MM-YYYY', N'YYYY-MM-DD', N'DDMMYYYY', N'YYYYMMDD') THROW 59244, N'The date format must be DD/MM/YYYY, DD-MM-YYYY, YYYY-MM-DD, DDMMYYYY or YYYYMMDD.', 1;
    IF EXISTS (SELECT 1 FROM dbo.bank_file_format_column WHERE format_sno = @fmt AND position = @pos AND is_active = 'Y' AND column_sno <> @id) THROW 59245, N'This format already has a column at this position.', 1;

    UPDATE dbo.bank_file_format_column
    SET format_sno = @fmt, position = @pos, header_text = @hdr, source_field = @src, fixed_value = @fix, max_len = @mx, pad_side = @side, pad_char = @pc, date_format = @df,
        modified_by = JSON_VALUE(@jsonInput, '$.modified_by'), modified_at = GETDATE()
    WHERE column_sno = @id;

    SELECT c.column_sno, c.format_sno, f.format_name, c.position, c.header_text, c.source_field, c.fixed_value, c.max_len, c.pad_side, c.pad_char, c.date_format, c.is_active
    FROM dbo.bank_file_format_column c JOIN dbo.bank_file_format f ON f.format_sno = c.format_sno WHERE c.column_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteBankFileFormatColumnRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.bank_file_format_column WHERE column_sno = @id AND is_active = 'Y') THROW 59246, N'Format column not found.', 1;
    UPDATE dbo.bank_file_format_column SET is_active = 'N', modified_at = GETDATE() WHERE column_sno = @id;
    SELECT @id AS column_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO

-- ── Payment Bank master (sql/138) with file_format_sno ──────────────────────
-- A format can be chosen, or left blank for the built-in layout. Errors 59218 = format not found.

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
           m.file_type, m.file_format_sno, ff.format_name AS file_format_name, m.file_prefix, m.client_code, m.file_code, m.alert_email, m.is_default, m.is_active
    FROM dbo.payment_bank_master m
    LEFT JOIN dbo.company_master c ON c.com_sno = m.com_sno
    LEFT JOIN dbo.division_master d ON d.div_sno = m.div_sno
    LEFT JOIN dbo.branch_master b ON b.brn_sno = m.brn_sno
    LEFT JOIN dbo.bank_file_format ff ON ff.format_sno = m.file_format_sno
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
        ac_holder_name NVARCHAR(MAX) NULL, ac_number NVARCHAR(MAX) NULL, ifsc NVARCHAR(MAX) NULL, file_type NVARCHAR(MAX) NULL, file_format_sno INT NULL,
        file_prefix NVARCHAR(MAX) NULL, client_code NVARCHAR(MAX) NULL, file_code INT NULL,
        alert_email NVARCHAR(MAX) NULL, is_default CHAR(1) NULL, created_by VARCHAR(30) NULL
    );
    INSERT INTO @rows (com_sno, div_sno, brn_sno, profile_name, bank_name, branch_name, ac_holder_name, ac_number, ifsc, file_type, file_format_sno, file_prefix, client_code, file_code, alert_email, is_default, created_by)
    SELECT TRY_CAST(NULLIF(LTRIM(RTRIM(com_sno)), N'') AS INT),
           TRY_CAST(NULLIF(LTRIM(RTRIM(div_sno)), N'') AS INT), TRY_CAST(NULLIF(LTRIM(RTRIM(brn_sno)), N'') AS INT),
           NULLIF(LTRIM(RTRIM(profile_name)), N''), NULLIF(LTRIM(RTRIM(bank_name)), N''), NULLIF(LTRIM(RTRIM(branch_name)), N''),
           NULLIF(LTRIM(RTRIM(ac_holder_name)), N''),
           NULLIF(REPLACE(REPLACE(LTRIM(RTRIM(ac_number)), N' ', N''), N'-', N''), N''),
           NULLIF(UPPER(REPLACE(LTRIM(RTRIM(ifsc)), N' ', N'')), N''),
           ISNULL(NULLIF(UPPER(LTRIM(RTRIM(file_type))), N''), N'BANK_UPLOAD'),
           TRY_CAST(NULLIF(LTRIM(RTRIM(file_format_sno)), N'') AS INT),
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
        ifsc NVARCHAR(MAX) '$.ifsc', file_type NVARCHAR(MAX) '$.file_type', file_format_sno NVARCHAR(30) '$.file_format_sno', file_prefix NVARCHAR(MAX) '$.file_prefix',
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
    IF EXISTS (SELECT 1 FROM @rows r WHERE r.file_format_sno IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.bank_file_format f WHERE f.format_sno = r.file_format_sno AND f.is_active = 'Y'))
        THROW 59218, N'The bank file format was not found. Choose one from the list.', 1;
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
        INSERT INTO dbo.payment_bank_master (com_sno, div_sno, brn_sno, profile_name, bank_name, branch_name, ac_holder_name, ac_number, ifsc, file_type, file_format_sno, file_prefix, client_code, file_code, alert_email, is_default, created_by)
        OUTPUT INSERTED.payment_bank_sno INTO @Touched
        SELECT com_sno, div_sno, brn_sno, profile_name, bank_name, branch_name, ac_holder_name, ac_number, ifsc, file_type, file_format_sno, file_prefix, client_code, file_code, alert_email, is_default, created_by
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
               m.file_type, m.file_format_sno, ff.format_name AS file_format_name, m.file_prefix, m.client_code, m.file_code, m.alert_email, m.is_default, m.is_active
        FROM dbo.payment_bank_master m
        JOIN @Touched t ON t.payment_bank_sno = m.payment_bank_sno
        LEFT JOIN dbo.company_master c ON c.com_sno = m.com_sno
        LEFT JOIN dbo.division_master d ON d.div_sno = m.div_sno
        LEFT JOIN dbo.branch_master b ON b.brn_sno = m.brn_sno
        LEFT JOIN dbo.bank_file_format ff ON ff.format_sno = m.file_format_sno
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
    DECLARE @com INT, @div INT, @brn INT, @file_code INT, @fmt INT,
            @profile NVARCHAR(MAX), @bank NVARCHAR(MAX), @branch NVARCHAR(MAX), @holder NVARCHAR(MAX), @acno NVARCHAR(MAX), @ifsc NVARCHAR(MAX),
            @ftype NVARCHAR(MAX), @prefix NVARCHAR(MAX), @client NVARCHAR(MAX), @email NVARCHAR(MAX), @default CHAR(1);
    SELECT @com = com_sno, @div = div_sno, @brn = brn_sno, @profile = profile_name, @bank = bank_name, @branch = branch_name,
           @holder = ac_holder_name, @acno = ac_number, @ifsc = ifsc, @ftype = file_type, @fmt = file_format_sno, @prefix = file_prefix, @client = client_code,
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
    -- the file format is optional too: a blank value goes back to the built-in layout
    IF EXISTS (SELECT 1 FROM OPENJSON(@jsonInput) WHERE [key] = 'file_format_sno') SET @fmt = TRY_CAST(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.file_format_sno'))), N'') AS INT);

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
    IF @fmt IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.bank_file_format WHERE format_sno = @fmt AND is_active = 'Y') THROW 59218, N'The bank file format was not found. Choose one from the list.', 1;
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
            file_type = @ftype, file_format_sno = @fmt, file_prefix = @prefix, client_code = @client, file_code = @file_code, alert_email = @email, is_default = @default,
            modified_by = JSON_VALUE(@jsonInput, '$.modified_by'), modified_at = GETDATE()
        WHERE payment_bank_sno = @id;

        IF @default = 'Y'
            UPDATE dbo.payment_bank_master SET is_default = 'N', modified_at = GETDATE()
            WHERE com_sno = @com AND div_sno = @div AND brn_sno = @brn AND payment_bank_sno <> @id AND is_active = 'Y' AND is_default = 'Y';

        COMMIT TRANSACTION;

        SELECT m.payment_bank_sno, m.com_sno, c.com_name, m.div_sno, d.div_name, m.brn_sno, b.brn_name,
               m.profile_name, m.bank_name, m.branch_name, m.ac_holder_name, m.ac_number, m.ifsc,
               m.file_type, m.file_format_sno, ff.format_name AS file_format_name, m.file_prefix, m.client_code, m.file_code, m.alert_email, m.is_default, m.is_active
        FROM dbo.payment_bank_master m
        LEFT JOIN dbo.company_master c ON c.com_sno = m.com_sno
        LEFT JOIN dbo.division_master d ON d.div_sno = m.div_sno
        LEFT JOIN dbo.branch_master b ON b.brn_sno = m.brn_sno
        LEFT JOIN dbo.bank_file_format ff ON ff.format_sno = m.file_format_sno
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
