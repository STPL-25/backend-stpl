-- ============================================================
-- Category master — create capability
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/Masters (generic /api/common_master/:masterField
--            pipeline), registered as master key "ProductCategoryMaster".
--
-- Why this is needed
-- ------------------
-- category_master and sp_product_catagory (the read SP) already existed
-- live and already had a Masters-grid tile, but there was no create
-- procedure — the tile was read-only.
--
-- cat_notes is NOT free-text notes despite the name: sp_nt_CreateProductRecord's
-- CategoryPrefix CTE uses it as the product-code PREFIX (cat_notes + a
-- 5-digit sequence = prod_code, e.g. "STA" -> "STA00001"). It must be
-- non-null/non-empty for product code generation to work (LEN(NULL) breaks
-- the SUBSTRING math there), so it's validated as required here, same as
-- cat_name, and enforced unique so two categories can't generate colliding
-- product code prefixes.
-- ============================================================

IF OBJECT_ID('dbo.sp_nt_CreateCategoryRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateCategoryRecords;
GO
CREATE PROCEDURE dbo.sp_nt_CreateCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @cat_name        NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.cat_name'),
            @cat_description NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.cat_description'),
            @cat_notes       NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.cat_notes'),
            @created_by      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @cat_name IS NULL OR LTRIM(RTRIM(@cat_name)) = ''
       OR @cat_notes IS NULL OR LTRIM(RTRIM(@cat_notes)) = ''
    BEGIN
        THROW 50002, N'cat_name and cat_notes (product code prefix) are required.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.category_master WHERE cat_name = @cat_name AND cat_active = 'Y')
    BEGIN
        THROW 50003, N'A category with this name already exists.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.category_master WHERE cat_notes = @cat_notes AND cat_active = 'Y')
    BEGIN
        THROW 50004, N'A category with this code prefix already exists.', 1;
        RETURN;
    END;

    INSERT INTO dbo.category_master (
        cat_name, cat_description, cat_notes, cat_active, cat_created_date, cat_created_by
    )
    VALUES (
        @cat_name, @cat_description, @cat_notes, 'Y', GETDATE(), @created_by
    );

    SELECT SCOPE_IDENTITY() AS cat_sno,
           @cat_name        AS cat_name,
           N'SUCCESS'       AS status,
           N'Category created successfully.' AS message;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.category_master ORDER BY cat_sno DESC;
--   SELECT name FROM sys.procedures WHERE name = 'sp_nt_CreateCategoryRecords';
-- ============================================================
