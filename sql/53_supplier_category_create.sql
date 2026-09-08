-- ============================================================
-- Supplier Category master — create capability
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/Masters (generic /api/common_master/:masterField
--            pipeline), master key "SupplierCatagoryMaster".
--
-- Why this is needed
-- ------------------
-- supplier_category and usp_GetSupplierCategoryRecords already existed live
-- (predating this repo's sql/*.sql convention entirely, like category_master/
-- product_master — confirmed via direct INFORMATION_SCHEMA/OBJECT_DEFINITION
-- query, not present in any checked-in migration) but had no create
-- procedure and no Masters-grid tile — same read-only-until-now state
-- category_master/subcategory_master were in before an earlier session
-- (27_subcategory_master_create.sql / 28_category_master_create.sql) added
-- create capability to those. This is the same fix, applied to
-- supplier_category.
--
-- Confirmed live columns (via INFORMATION_SCHEMA.COLUMNS): supp_cat_sno
-- (IDENTITY PK), supp_cat_name VARCHAR(50), supp_cat_code VARCHAR(100),
-- is_active CHAR(1), created_date DATE, created_by VARCHAR(20),
-- modified_date DATE, modified_by VARCHAR(20). No FK/parent table (unlike
-- subcategory_master's cat_sno) — this is a flat, single-level master.
-- ============================================================

IF OBJECT_ID('dbo.sp_nt_CreateSupplierCategoryRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateSupplierCategoryRecords;
GO
CREATE PROCEDURE dbo.sp_nt_CreateSupplierCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @supp_cat_name NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.supp_cat_name'),
            @supp_cat_code NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.supp_cat_code'),
            @created_by    VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @supp_cat_name IS NULL OR LTRIM(RTRIM(@supp_cat_name)) = ''
    BEGIN
        THROW 50002, N'supp_cat_name is required.', 1;
        RETURN;
    END;

    IF EXISTS (
        SELECT 1 FROM dbo.supplier_category
        WHERE supp_cat_name = @supp_cat_name AND is_active = 'Y'
    )
    BEGIN
        THROW 50004, N'A supplier category with this name already exists.', 1;
        RETURN;
    END;

    INSERT INTO dbo.supplier_category (
        supp_cat_name, supp_cat_code, is_active, created_date, created_by
    )
    VALUES (
        @supp_cat_name, @supp_cat_code, 'Y', GETDATE(), @created_by
    );

    SELECT SCOPE_IDENTITY() AS supp_cat_sno,
           @supp_cat_name   AS supp_cat_name,
           @supp_cat_code   AS supp_cat_code,
           N'SUCCESS'       AS status,
           N'Supplier category created successfully.' AS message;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.supplier_category ORDER BY supp_cat_sno DESC;
--   SELECT name FROM sys.procedures WHERE name = 'sp_nt_CreateSupplierCategoryRecords';
-- ============================================================
