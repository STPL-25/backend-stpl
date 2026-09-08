-- ============================================================
-- Terms & Conditions master — terms_conditions_master
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/TermsConditions (bespoke module, own routes —
--            NOT the generic /api/common_master pipeline, since this needs
--            working Update/Delete and default-flag flip logic that the
--            generic Masters grid doesn't support, see
--            sql/16_warehouse_location_master.sql's header for why
--            Update/Delete are broken for every generic master today).
--
-- Why this exists
-- ---------------
-- Purchase Order creation (CreatePODialog.tsx) currently has a free-text
-- "Terms & Conditions" textarea the buyer must retype every time (see
-- FieldDatas/PurchaseTeamFieldDatas.tsx field 'terms_conditions'). This
-- master lets an admin author reusable T&C text once per
-- Company+Division+Branch+Department scope, flag one entry per scope as the
-- default, and have PO creation auto-fill that default — while the buyer
-- can still freely edit the text for that specific PO (the textarea is not
-- locked/read-only).
--
-- Scoping: a row's com_sno/div_sno/brn_sno/dept_sno is one exact scope
-- (same single-chain pattern dept_master/branch_master already use — NOT
-- the JSON-array multi-select warehouse_location_master uses, since here
-- each entry belongs to exactly one department, not many at once).
-- Per product decision, a scope MAY have multiple named T&C entries (e.g.
-- "Standard", "Import", "Urgent") with exactly one flagged is_default='Y' —
-- enforced by a filtered unique index, not just application logic.
-- ============================================================

IF OBJECT_ID('dbo.terms_conditions_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.terms_conditions_master (
        tc_sno         INT IDENTITY(1,1) PRIMARY KEY,
        tc_title       NVARCHAR(150)  NOT NULL,
        tc_text        NVARCHAR(MAX)  NOT NULL,
        com_sno        INT            NOT NULL,
        div_sno        INT            NOT NULL,
        brn_sno        INT            NOT NULL,
        dept_sno       INT            NOT NULL,
        is_default     CHAR(1)        NOT NULL DEFAULT 'N',
        is_active      CHAR(1)        NOT NULL DEFAULT 'Y',
        created_by     VARCHAR(20)    NULL,
        created_date   DATETIME       NOT NULL DEFAULT GETDATE(),
        modified_by    VARCHAR(20)    NULL,
        modified_date  DATETIME       NULL,
        CONSTRAINT CK_terms_conditions_master_is_default CHECK (is_default IN ('Y','N')),
        CONSTRAINT CK_terms_conditions_master_is_active  CHECK (is_active  IN ('Y','N'))
    );
END;
GO

-- At most one active default per exact scope — a second attempt to insert/
-- update a row to is_default='Y' for the same scope while another active
-- default already exists fails at the index, not just in the SP.
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'UQ_terms_conditions_master_default_scope'
      AND object_id = OBJECT_ID('dbo.terms_conditions_master')
)
BEGIN
    CREATE UNIQUE INDEX UQ_terms_conditions_master_default_scope
    ON dbo.terms_conditions_master (com_sno, div_sno, brn_sno, dept_sno)
    WHERE is_default = 'Y' AND is_active = 'Y';
END;
GO

-- ── sp_nt_GetTermsConditionsRecords ─────────────────────────────────────────
-- Full grid list (admin screen) with resolved company/division/branch/
-- department names for display.
IF OBJECT_ID('dbo.sp_nt_GetTermsConditionsRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetTermsConditionsRecords;
GO
CREATE PROCEDURE dbo.sp_nt_GetTermsConditionsRecords
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.tc_sno,
        t.tc_title,
        t.tc_text,
        t.com_sno,  c.com_name,
        t.div_sno,  d.div_name,
        t.brn_sno,  b.brn_name,
        t.dept_sno, dm.dept_name,
        t.is_default,
        t.is_active,
        t.created_by,
        CONVERT(VARCHAR(30), t.created_date, 120)  AS created_date,
        t.modified_by,
        CONVERT(VARCHAR(30), t.modified_date, 120) AS modified_date
    FROM dbo.terms_conditions_master t
    JOIN dbo.company_master  c  ON c.com_sno   = t.com_sno
    JOIN dbo.division_master d  ON d.div_sno   = t.div_sno
    JOIN dbo.branch_master   b  ON b.brn_sno   = t.brn_sno
    JOIN dbo.dept_master     dm ON dm.dept_sno = t.dept_sno
    WHERE t.is_active = 'Y'
    ORDER BY c.com_name, d.div_name, b.brn_name, dm.dept_name, t.is_default DESC, t.tc_title;
END;
GO

-- ── sp_nt_CreateTermsConditions ─────────────────────────────────────────────
-- @jsonInput: {"tc_title":"...", "tc_text":"...", "com_sno":1, "div_sno":2,
--              "brn_sno":3, "dept_sno":4, "is_default":"Y"|"N", "created_by":"..."}
-- If is_default='Y', any existing active default for the same exact scope is
-- flipped to 'N' first (single caller, no concurrent-writer race handling
-- beyond the unique index already in place as a backstop).
IF OBJECT_ID('dbo.sp_nt_CreateTermsConditions', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateTermsConditions;
GO
CREATE PROCEDURE dbo.sp_nt_CreateTermsConditions
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 51001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @tc_title    NVARCHAR(150) = JSON_VALUE(@jsonInput, '$.tc_title'),
            @tc_text     NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.tc_text'),
            @com_sno     INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno')  AS INT),
            @div_sno     INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno')  AS INT),
            @brn_sno     INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno')  AS INT),
            @dept_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT),
            @is_default  CHAR(1)       = ISNULL(JSON_VALUE(@jsonInput, '$.is_default'), 'N'),
            @created_by  VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @tc_title IS NULL OR @tc_text IS NULL OR @com_sno IS NULL OR @div_sno IS NULL
       OR @brn_sno IS NULL OR @dept_sno IS NULL
    BEGIN
        THROW 51002, N'tc_title, tc_text, com_sno, div_sno, brn_sno and dept_sno are required.', 1;
        RETURN;
    END;

    IF @is_default = 'Y'
        UPDATE dbo.terms_conditions_master
        SET is_default = 'N', modified_by = @created_by, modified_date = GETDATE()
        WHERE com_sno = @com_sno AND div_sno = @div_sno AND brn_sno = @brn_sno AND dept_sno = @dept_sno
          AND is_default = 'Y' AND is_active = 'Y';

    INSERT INTO dbo.terms_conditions_master (
        tc_title, tc_text, com_sno, div_sno, brn_sno, dept_sno, is_default, is_active, created_by
    )
    VALUES (
        @tc_title, @tc_text, @com_sno, @div_sno, @brn_sno, @dept_sno, @is_default, 'Y', @created_by
    );

    SELECT SCOPE_IDENTITY() AS tc_sno, N'SUCCESS' AS status, N'Terms & conditions saved successfully.' AS message;
END;
GO

-- ── sp_nt_UpdateTermsConditions ─────────────────────────────────────────────
-- @jsonInput: {"tc_sno":1, "tc_title":"...", "tc_text":"...", "is_default":"Y"|"N",
--              "is_active":"Y"|"N", "modified_by":"..."}
-- Scope (com/div/brn/dept) is immutable after creation — add a new entry
-- instead of moving an existing one to a different department.
IF OBJECT_ID('dbo.sp_nt_UpdateTermsConditions', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_UpdateTermsConditions;
GO
CREATE PROCEDURE dbo.sp_nt_UpdateTermsConditions
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 51003, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @tc_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.tc_sno') AS INT),
            @tc_title     NVARCHAR(150) = JSON_VALUE(@jsonInput, '$.tc_title'),
            @tc_text      NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.tc_text'),
            @is_default   CHAR(1)       = JSON_VALUE(@jsonInput, '$.is_default'),
            @is_active    CHAR(1)       = JSON_VALUE(@jsonInput, '$.is_active'),
            @modified_by  VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.modified_by');

    IF @tc_sno IS NULL
    BEGIN
        THROW 51004, N'tc_sno is required.', 1;
        RETURN;
    END;

    DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT;
    SELECT @com_sno = com_sno, @div_sno = div_sno, @brn_sno = brn_sno, @dept_sno = dept_sno
    FROM dbo.terms_conditions_master WHERE tc_sno = @tc_sno;

    IF @com_sno IS NULL
    BEGIN
        THROW 51005, N'Terms & conditions entry not found.', 1;
        RETURN;
    END;

    IF @is_default = 'Y'
        UPDATE dbo.terms_conditions_master
        SET is_default = 'N', modified_by = @modified_by, modified_date = GETDATE()
        WHERE com_sno = @com_sno AND div_sno = @div_sno AND brn_sno = @brn_sno AND dept_sno = @dept_sno
          AND is_default = 'Y' AND is_active = 'Y' AND tc_sno <> @tc_sno;

    UPDATE dbo.terms_conditions_master
    SET tc_title      = ISNULL(@tc_title, tc_title),
        tc_text       = ISNULL(@tc_text, tc_text),
        is_default    = ISNULL(@is_default, is_default),
        is_active     = ISNULL(@is_active, is_active),
        modified_by   = @modified_by,
        modified_date = GETDATE()
    WHERE tc_sno = @tc_sno;

    SELECT @tc_sno AS tc_sno, N'SUCCESS' AS status, N'Terms & conditions updated successfully.' AS message;
END;
GO

-- ── sp_nt_DeleteTermsConditions ─────────────────────────────────────────────
-- Soft delete — is_active flips to 'N'. No auto-promotion of another entry
-- to default within the vacated scope; an admin re-flags one explicitly.
IF OBJECT_ID('dbo.sp_nt_DeleteTermsConditions', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_DeleteTermsConditions;
GO
CREATE PROCEDURE dbo.sp_nt_DeleteTermsConditions
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @tc_sno      INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.tc_sno') AS INT),
            @modified_by VARCHAR(20) = JSON_VALUE(@jsonInput, '$.modified_by');

    IF @tc_sno IS NULL
    BEGIN
        THROW 51006, N'tc_sno is required.', 1;
        RETURN;
    END;

    UPDATE dbo.terms_conditions_master
    SET is_active = 'N', is_default = 'N', modified_by = @modified_by, modified_date = GETDATE()
    WHERE tc_sno = @tc_sno;

    SELECT @tc_sno AS tc_sno, N'SUCCESS' AS status, N'Terms & conditions deleted successfully.' AS message;
END;
GO

-- ── sp_nt_GetDefaultTermsConditions ─────────────────────────────────────────
-- Exact-scope lookup used by CreatePODialog.tsx to prefill the terms_conditions
-- textarea. Returns zero rows if no default is configured for that scope —
-- the frontend falls back to its existing behavior in that case.
-- @jsonInput: {"com_sno":1, "div_sno":2, "brn_sno":3, "dept_sno":4}
IF OBJECT_ID('dbo.sp_nt_GetDefaultTermsConditions', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetDefaultTermsConditions;
GO
CREATE PROCEDURE dbo.sp_nt_GetDefaultTermsConditions
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno  INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno')  AS INT),
            @div_sno  INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno')  AS INT),
            @brn_sno  INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno')  AS INT),
            @dept_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);

    SELECT TOP 1 tc_sno, tc_title, tc_text
    FROM dbo.terms_conditions_master
    WHERE com_sno = @com_sno AND div_sno = @div_sno AND brn_sno = @brn_sno AND dept_sno = @dept_sno
      AND is_default = 'Y' AND is_active = 'Y';
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.terms_conditions_master ORDER BY tc_sno;
--   SELECT name FROM sys.procedures WHERE name LIKE 'sp_nt_%TermsConditions%';
-- ============================================================
