

-- ============================================================================
-- ProductSubCategoryMaster (subcategory_master: subcat_sno PK, subcat_active)
-- ============================================================================
CREATE   PROCEDURE dbo.sp_nt_CreateSubCategoryRecords
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
