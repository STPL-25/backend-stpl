-- ROLLBACK for 136_stock_type_master.sql (Non_trade_Dev), 2026-10-21.
-- Restores the three-value CHECK on subcategory_master.subcat_stock_type and the previous
-- sp_nt_CreateSubCategoryRecords / sp_nt_UpdateSubCategoryRecords, then drops the Stock Type
-- master (FK, procedures, table). Refuses to run (changes nothing) if a sub category is on a
-- stock type the old CHECK would not accept - move those to Regular / Non-Regular / Perishable first.

IF EXISTS (SELECT 1 FROM dbo.subcategory_master WHERE subcat_stock_type NOT IN ('Regular', 'Non-Regular', 'Perishable'))
    THROW 59190, N'Some sub categories use a custom stock type. Move them to Regular, Non-Regular or Perishable before rolling back.', 1;
GO

IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_subcategory_stock_type' AND parent_object_id = OBJECT_ID('dbo.subcategory_master'))
    ALTER TABLE dbo.subcategory_master DROP CONSTRAINT FK_subcategory_stock_type;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_subcategory_master_stock_type' AND parent_object_id = OBJECT_ID('dbo.subcategory_master'))
    ALTER TABLE dbo.subcategory_master
        ADD CONSTRAINT CK_subcategory_master_stock_type CHECK (subcat_stock_type IN ('Regular', 'Non-Regular', 'Perishable'));
GO

-- ============================================================================
-- ProductSubCategoryMaster (subcategory_master: subcat_sno PK, subcat_active)
-- ============================================================================
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

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json)
        WITH (subcat_stock_type VARCHAR(20) '$.subcat_stock_type')
        WHERE ISNULL(NULLIF(subcat_stock_type, ''), 'Regular') NOT IN ('Regular', 'Non-Regular', 'Perishable')
    )
        THROW 50005, N'subcat_stock_type must be Regular, Non-Regular or Perishable.', 1;

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

        INSERT INTO dbo.subcategory_master (cat_sno, subcat_name, subcat_description, subcat_notes, subcat_stock_type, perishable_days, subcat_active, subcat_created_date, subcat_created_by)
        OUTPUT INSERTED.subcat_sno INTO @Inserted
        SELECT
            cat_sno, subcat_name, subcat_description, subcat_notes,
            ISNULL(NULLIF(subcat_stock_type, ''), 'Regular'),
            CASE WHEN ISNULL(NULLIF(subcat_stock_type, ''), 'Regular') = 'Perishable' THEN perishable_days ELSE NULL END,
            'Y', GETDATE(), created_by
        FROM OPENJSON(@json)
        WITH (
            cat_sno            INT           '$.cat_sno',
            subcat_name        NVARCHAR(50)  '$.subcat_name',
            subcat_description NVARCHAR(100) '$.subcat_description',
            subcat_notes       NVARCHAR(500) '$.subcat_notes',
            subcat_stock_type  VARCHAR(20)   '$.subcat_stock_type',
            perishable_days    INT           '$.perishable_days',
            created_by         VARCHAR(20)   '$.created_by'
        );

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

    DECLARE @stock_type VARCHAR(20) = ISNULL(JSON_VALUE(@jsonInput, '$.subcat_stock_type'), (SELECT subcat_stock_type FROM dbo.subcategory_master WHERE subcat_sno = @id));
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

DROP PROCEDURE IF EXISTS dbo.sp_nt_GetStockTypeRecords;
DROP PROCEDURE IF EXISTS dbo.sp_nt_CreateStockTypeRecords;
DROP PROCEDURE IF EXISTS dbo.sp_nt_UpdateStockTypeRecords;
DROP PROCEDURE IF EXISTS dbo.sp_nt_DeleteStockTypeRecords;
GO

DROP TABLE IF EXISTS dbo.stock_type_master;
GO
