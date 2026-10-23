-- ============================================================================
-- 136_stock_type_master.sql   (Non_trade_Dev)
--
-- Stock Type master (stock_type_master).
--
-- subcategory_master.subcat_stock_type has always been a fixed list of three
-- values (Regular / Non-Regular / Perishable), hard-coded in a CHECK constraint
-- (CK_subcategory_master_stock_type), in sp_nt_CreateSubCategoryRecords and in
-- the Sub Category form's dropdown (Data.tsx). This gives it a real master so the
-- list is maintained from the Masters screen, and the Sub Category form's
-- Stock Type dropdown reads from it.
--
-- subcategory_master.subcat_stock_type is DELIBERATELY left as the stock type
-- *name* string (no new id column): GRN auto-issue, Store Requisition filtering,
-- Asset Management, asset tagging and Expiry Stock all compare that string
-- directly, so nothing downstream changes. Integrity moves from the CHECK to a
-- foreign key on the name with ON UPDATE CASCADE (a renamed custom type carries
-- across to its sub categories by itself), and the Sub Category create/update
-- procedures reject a type that is not an active entry of the master.
--
-- The three types that exist today are seeded as BUILT-IN (is_system = 'Y').
-- Their behaviour is keyed to the literal names, so a built-in type cannot be
-- renamed or deleted (its description can be edited):
--     sp_nt_AutoCreateStockIssueFromGRN   Non-Regular, Perishable -> issued straight off GRN
--     sp_nt_GetInventoryItems             Non-Regular, Perishable kept out of the requisition picker; Perishable -> Expiry Stock
--     sp_nt_CreateAssetRequest / sp_nt_GetAssetRegister     Non-Regular
--     sp_nt_GenerateGRNAssetTags / sp_nt_GetGRNsForAssetTags Perishable skipped
-- A stock type added from the master matches none of those names, so it behaves
-- like Regular in all of them. Giving a new type its own rules means extending
-- those procedures.
--
-- Do not re-run 50_subcategory_stock_type.sql / 77_subcategory_perishable_type.sql
-- after this: they re-create the three-value CHECK and would reject custom types.
--
-- Registered as master key "StockTypeMaster". Safe to re-run.
-- ============================================================================

IF OBJECT_ID('dbo.stock_type_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.stock_type_master (
        stock_type_sno  INT IDENTITY(1,1) NOT NULL,
        -- same type/length as subcategory_master.subcat_stock_type: it is the value stored there
        stock_type_name VARCHAR(20)   NOT NULL,
        stock_type_desc NVARCHAR(250) NULL,
        is_system       CHAR(1)       NOT NULL CONSTRAINT DF_stock_type_master_is_system DEFAULT 'N',
        is_active       CHAR(1)       NOT NULL CONSTRAINT DF_stock_type_master_is_active DEFAULT 'Y',
        created_by      VARCHAR(20)   NULL,
        created_at      DATETIME      NOT NULL CONSTRAINT DF_stock_type_master_created_at DEFAULT GETDATE(),
        modified_by     VARCHAR(20)   NULL,
        modified_at     DATETIME      NULL,
        CONSTRAINT PK_stock_type_master PRIMARY KEY (stock_type_sno),
        CONSTRAINT UQ_stock_type_master_name UNIQUE (stock_type_name),
        CONSTRAINT CK_stock_type_master_is_system CHECK (is_system IN ('Y', 'N')),
        CONSTRAINT CK_stock_type_master_is_active CHECK (is_active IN ('Y', 'N'))
    );
END;
GO

-- ── Seed: the three built-in types ──────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.stock_type_master WHERE stock_type_name = 'Regular')
    INSERT INTO dbo.stock_type_master (stock_type_name, stock_type_desc, is_system, created_by)
    VALUES ('Regular', N'Day-to-day stock, issued through a Store Requisition.', 'Y', 'system');

IF NOT EXISTS (SELECT 1 FROM dbo.stock_type_master WHERE stock_type_name = 'Non-Regular')
    INSERT INTO dbo.stock_type_master (stock_type_name, stock_type_desc, is_system, created_by)
    VALUES ('Non-Regular', N'One-off items. Skip Store Requisition; issued straight from GRN.', 'Y', 'system');

IF NOT EXISTS (SELECT 1 FROM dbo.stock_type_master WHERE stock_type_name = 'Perishable')
    INSERT INTO dbo.stock_type_master (stock_type_name, stock_type_desc, is_system, created_by)
    VALUES ('Perishable', N'Short shelf-life items. Issued straight from GRN; expiry tracked.', 'Y', 'system');

UPDATE dbo.stock_type_master SET is_system = 'Y', is_active = 'Y'
WHERE stock_type_name IN ('Regular', 'Non-Regular', 'Perishable') AND (is_system <> 'Y' OR is_active <> 'Y');

-- Safety net before the foreign key: any other value already on a sub category
-- (the old CHECK made this impossible) is carried into the master so nothing is orphaned.
INSERT INTO dbo.stock_type_master (stock_type_name, created_by)
SELECT DISTINCT LTRIM(RTRIM(s.subcat_stock_type)), 'system'
FROM dbo.subcategory_master s
WHERE NOT EXISTS (SELECT 1 FROM dbo.stock_type_master m WHERE m.stock_type_name = s.subcat_stock_type);
GO

-- ── CHECK (fixed list of three) -> FOREIGN KEY (the master) ─────────────────
IF EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE name = 'CK_subcategory_master_stock_type' AND parent_object_id = OBJECT_ID('dbo.subcategory_master')
)
    ALTER TABLE dbo.subcategory_master DROP CONSTRAINT CK_subcategory_master_stock_type;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE name = 'FK_subcategory_stock_type' AND parent_object_id = OBJECT_ID('dbo.subcategory_master')
)
    ALTER TABLE dbo.subcategory_master
        ADD CONSTRAINT FK_subcategory_stock_type
            FOREIGN KEY (subcat_stock_type) REFERENCES dbo.stock_type_master (stock_type_name)
            ON UPDATE CASCADE;
GO

-- ── Master procedures ───────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetStockTypeRecords
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.stock_type_sno, m.stock_type_name, m.stock_type_desc, m.is_system, m.is_active,
           (SELECT COUNT(*) FROM dbo.subcategory_master s
             WHERE s.subcat_stock_type = m.stock_type_name AND s.subcat_active = 'Y') AS subcategory_count
    FROM dbo.stock_type_master m
    WHERE m.is_active = 'Y'
    ORDER BY m.stock_type_sno;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateStockTypeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    -- Single Add posts one object, Excel import posts an array: treat both as rows.
    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    DECLARE @rows TABLE (
        stock_type_name NVARCHAR(MAX) NULL,
        stock_type_desc NVARCHAR(MAX) NULL,
        created_by      VARCHAR(20)   NULL
    );
    INSERT INTO @rows (stock_type_name, stock_type_desc, created_by)
    SELECT NULLIF(LTRIM(RTRIM(stock_type_name)), N''), NULLIF(LTRIM(RTRIM(stock_type_desc)), N''), created_by
    FROM OPENJSON(@json)
    WITH (
        stock_type_name NVARCHAR(MAX) '$.stock_type_name',
        stock_type_desc NVARCHAR(MAX) '$.stock_type_desc',
        created_by      VARCHAR(20)   '$.created_by'
    );

    IF NOT EXISTS (SELECT 1 FROM @rows)
        THROW 59101, N'At least one stock type is required.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE stock_type_name IS NULL)
        THROW 59101, N'stock_type_name is required for every row.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE LEN(stock_type_name) > 20)
        THROW 59102, N'A stock type name can be at most 20 characters.', 1;
    IF EXISTS (SELECT 1 FROM @rows WHERE LEN(stock_type_desc) > 250)
        THROW 59102, N'A stock type description can be at most 250 characters.', 1;
    IF EXISTS (SELECT 1 FROM @rows GROUP BY stock_type_name HAVING COUNT(*) > 1)
        THROW 59103, N'The same stock type name appears more than once in this request.', 1;

    DECLARE @dup NVARCHAR(100) = (
        SELECT TOP (1) r.stock_type_name FROM @rows r
        JOIN dbo.stock_type_master m ON m.stock_type_name = r.stock_type_name AND m.is_active = 'Y'
    );
    IF @dup IS NOT NULL
    BEGIN
        DECLARE @dupMsg NVARCHAR(200) = CONCAT(N'A stock type named "', @dup, N'" already exists.');
        THROW 59104, @dupMsg, 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Touched TABLE (stock_type_sno INT);

        -- A name that was deleted earlier is brought back (soft delete keeps the row),
        -- with the new description when one is given.
        UPDATE m
        SET is_active   = 'Y',
            stock_type_desc = COALESCE(r.stock_type_desc, m.stock_type_desc),
            modified_by = r.created_by,
            modified_at = GETDATE()
        OUTPUT INSERTED.stock_type_sno INTO @Touched
        FROM dbo.stock_type_master m
        JOIN @rows r ON r.stock_type_name = m.stock_type_name
        WHERE m.is_active = 'N';

        INSERT INTO dbo.stock_type_master (stock_type_name, stock_type_desc, is_system, is_active, created_by)
        OUTPUT INSERTED.stock_type_sno INTO @Touched
        SELECT r.stock_type_name, r.stock_type_desc, 'N', 'Y', r.created_by
        FROM @rows r
        WHERE NOT EXISTS (SELECT 1 FROM dbo.stock_type_master m WHERE m.stock_type_name = r.stock_type_name);

        COMMIT TRANSACTION;

        SELECT m.stock_type_sno, m.stock_type_name, m.stock_type_desc, m.is_system, m.is_active,
               (SELECT COUNT(*) FROM dbo.subcategory_master s
                 WHERE s.subcat_stock_type = m.stock_type_name AND s.subcat_active = 'Y') AS subcategory_count
        FROM dbo.stock_type_master m
        JOIN @Touched t ON t.stock_type_sno = m.stock_type_sno
        ORDER BY m.stock_type_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateStockTypeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.stock_type_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.stock_type_master WHERE stock_type_sno = @id AND is_active = 'Y')
        THROW 59105, N'Stock type not found.', 1;

    DECLARE @oldName VARCHAR(20), @isSystem CHAR(1);
    SELECT @oldName = stock_type_name, @isSystem = is_system FROM dbo.stock_type_master WHERE stock_type_sno = @id;

    DECLARE @newName NVARCHAR(MAX) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.stock_type_name'))), N'');
    -- A key that is present (even blank) sets the description, so it can be cleared; an absent key leaves it alone.
    DECLARE @setDesc BIT = CASE WHEN EXISTS (SELECT 1 FROM OPENJSON(@jsonInput) WHERE [key] = 'stock_type_desc') THEN 1 ELSE 0 END;
    DECLARE @newDesc NVARCHAR(MAX) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.stock_type_desc'))), N'');

    IF LEN(@newDesc) > 250
        THROW 59102, N'A stock type description can be at most 250 characters.', 1;

    -- Exact (case-sensitive) comparison: even a case-only change to a built-in name is a rename.
    IF @newName IS NOT NULL AND @newName COLLATE SQL_Latin1_General_CP1_CS_AS <> @oldName COLLATE SQL_Latin1_General_CP1_CS_AS
    BEGIN
        IF @isSystem = 'Y'
            THROW 59106, N'This is a built-in stock type, so its name cannot be changed (GRN auto-issue, asset tracking and expiry tracking depend on it). You can edit its description.', 1;
        IF LEN(@newName) > 20
            THROW 59102, N'A stock type name can be at most 20 characters.', 1;
        IF EXISTS (SELECT 1 FROM dbo.stock_type_master WHERE stock_type_name = @newName AND stock_type_sno <> @id)
            THROW 59104, N'A stock type with this name already exists.', 1;
    END
    ELSE
        SET @newName = NULL;   -- unchanged

    -- Renaming the key cascades to subcategory_master.subcat_stock_type through FK_subcategory_stock_type.
    UPDATE dbo.stock_type_master
    SET stock_type_name = ISNULL(@newName, stock_type_name),
        stock_type_desc = CASE WHEN @setDesc = 1 THEN @newDesc ELSE stock_type_desc END,
        modified_by     = JSON_VALUE(@jsonInput, '$.modified_by'),
        modified_at     = GETDATE()
    WHERE stock_type_sno = @id;

    SELECT m.stock_type_sno, m.stock_type_name, m.stock_type_desc, m.is_system, m.is_active,
           (SELECT COUNT(*) FROM dbo.subcategory_master s
             WHERE s.subcat_stock_type = m.stock_type_name AND s.subcat_active = 'Y') AS subcategory_count
    FROM dbo.stock_type_master m
    WHERE m.stock_type_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteStockTypeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.stock_type_master WHERE stock_type_sno = @id AND is_active = 'Y')
        THROW 59105, N'Stock type not found.', 1;

    IF EXISTS (SELECT 1 FROM dbo.stock_type_master WHERE stock_type_sno = @id AND is_system = 'Y')
        THROW 59107, N'This is a built-in stock type and cannot be deleted.', 1;

    DECLARE @used INT = (
        SELECT COUNT(*) FROM dbo.subcategory_master s
        JOIN dbo.stock_type_master m ON m.stock_type_name = s.subcat_stock_type
        WHERE m.stock_type_sno = @id AND s.subcat_active = 'Y'
    );
    IF @used > 0
    BEGIN
        DECLARE @usedMsg NVARCHAR(250) = CONCAT(N'This stock type is still used by ', @used,
            CASE WHEN @used = 1 THEN N' active sub category' ELSE N' active sub categories' END,
            N'. Move ', CASE WHEN @used = 1 THEN N'it' ELSE N'them' END, N' to another stock type first.');
        THROW 59108, @usedMsg, 1;
    END

    UPDATE dbo.stock_type_master SET is_active = 'N', modified_at = GETDATE() WHERE stock_type_sno = @id;
    SELECT @id AS stock_type_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO

-- ── Sub Category procedures: take the stock type from the master ────────────
-- Pulled from the live definitions (OBJECT_DEFINITION) before editing; the only
-- changes are the marked stock-type checks.
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateSubCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (cat_sno INT '$.cat_sno', subcat_name NVARCHAR(50) '$.subcat_name')
        WHERE cat_sno IS NULL OR subcat_name IS NULL OR LTRIM(RTRIM(subcat_name)) = ''
    )
        THROW 50002, N'cat_sno and subcat_name are required for every row.', 1;

    -- CHANGED: was a hard-coded Regular / Non-Regular / Perishable list. A blank type still means Regular.
    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (subcat_stock_type NVARCHAR(MAX) '$.subcat_stock_type') j
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.stock_type_master st
            WHERE st.stock_type_name = ISNULL(NULLIF(LTRIM(RTRIM(j.subcat_stock_type)), N''), N'Regular')
              AND st.is_active = 'Y'
        )
    )
        THROW 50005, N'subcat_stock_type must be an active stock type from the Stock Type master.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json)
        WITH (subcat_stock_type VARCHAR(20) '$.subcat_stock_type', perishable_days INT '$.perishable_days')
        WHERE ISNULL(NULLIF(subcat_stock_type, ''), 'Regular') = 'Perishable' AND (perishable_days IS NULL OR perishable_days <= 0)
    )
        THROW 50006, N'perishable_days is required and must be greater than zero when subcat_stock_type is Perishable.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (cat_sno INT '$.cat_sno') j
        LEFT JOIN dbo.category_master cm ON cm.cat_sno = j.cat_sno AND cm.cat_active = 'Y'
        WHERE cm.cat_sno IS NULL
    )
        THROW 50003, N'Category not found.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (cat_sno INT '$.cat_sno', subcat_name NVARCHAR(50) '$.subcat_name') j
        JOIN dbo.subcategory_master m ON m.cat_sno = j.cat_sno AND m.subcat_name = j.subcat_name AND m.subcat_active = 'Y'
    )
        THROW 50004, N'A sub category with this name already exists under the selected category.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (subcat_sno INT);

        -- CHANGED: the joined master row supplies the stored (canonical-spelling) stock type name.
        INSERT INTO dbo.subcategory_master (cat_sno, subcat_name, subcat_description, subcat_notes, subcat_stock_type, perishable_days, subcat_active, subcat_created_date, subcat_created_by)
        OUTPUT INSERTED.subcat_sno INTO @Inserted
        SELECT
            j.cat_sno, j.subcat_name, j.subcat_description, j.subcat_notes,
            st.stock_type_name,
            CASE WHEN st.stock_type_name = 'Perishable' THEN j.perishable_days ELSE NULL END,
            'Y', GETDATE(), j.created_by
        FROM OPENJSON(@json)
        WITH (
            cat_sno            INT           '$.cat_sno',
            subcat_name        NVARCHAR(50)  '$.subcat_name',
            subcat_description NVARCHAR(100) '$.subcat_description',
            subcat_notes       NVARCHAR(500) '$.subcat_notes',
            subcat_stock_type  NVARCHAR(MAX) '$.subcat_stock_type',
            perishable_days    INT           '$.perishable_days',
            created_by         VARCHAR(20)   '$.created_by'
        ) j
        JOIN dbo.stock_type_master st
          ON st.stock_type_name = ISNULL(NULLIF(LTRIM(RTRIM(j.subcat_stock_type)), N''), N'Regular');

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.subcategory_master t JOIN @Inserted i ON i.subcat_sno = t.subcat_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateSubCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.subcat_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.subcategory_master WHERE subcat_sno = @id)
    BEGIN
        RAISERROR('Sub category not found.', 16, 1);
        RETURN;
    END

    -- CHANGED: the requested type must be an entry of the Stock Type master (stored in its canonical
    -- spelling). Only a type other than the sub category's current one has to still be active, so a
    -- sub category already on a since-retired type can still be edited. Blank = leave unchanged.
    DECLARE @current_stock_type VARCHAR(20) = (SELECT subcat_stock_type FROM dbo.subcategory_master WHERE subcat_sno = @id);
    DECLARE @requested_stock_type NVARCHAR(MAX) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.subcat_stock_type'))), N'');
    DECLARE @stock_type VARCHAR(20) = @current_stock_type;
    IF @requested_stock_type IS NOT NULL
    BEGIN
        SET @stock_type = (
            SELECT stock_type_name FROM dbo.stock_type_master
            WHERE stock_type_name = @requested_stock_type
              AND (is_active = 'Y' OR stock_type_name = @current_stock_type)
        );
        IF @stock_type IS NULL
            THROW 50005, N'subcat_stock_type must be an active stock type from the Stock Type master.', 1;
    END
    DECLARE @perishable_days INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.perishable_days') AS INT);

    UPDATE dbo.subcategory_master
    SET cat_sno             = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.cat_sno') AS INT), cat_sno),
        subcat_name         = ISNULL(JSON_VALUE(@jsonInput, '$.subcat_name'), subcat_name),
        subcat_description  = ISNULL(JSON_VALUE(@jsonInput, '$.subcat_description'), subcat_description),
        subcat_notes        = ISNULL(JSON_VALUE(@jsonInput, '$.subcat_notes'), subcat_notes),
        subcat_stock_type   = @stock_type,
        perishable_days     = CASE WHEN @stock_type = 'Perishable' THEN ISNULL(@perishable_days, perishable_days) ELSE NULL END,
        subcat_modified_date = GETDATE(),
        subcat_modified_by   = JSON_VALUE(@jsonInput, '$.modified_by')
    WHERE subcat_sno = @id;

    SELECT * FROM dbo.subcategory_master WHERE subcat_sno = @id;
END
GO
