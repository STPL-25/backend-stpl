-- ============================================================
-- Sub Category master — Regular / Non-Regular stock type flag
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/Masters (generic /api/common_master/:masterField
--            pipeline), master key "ProductSubCategoryMaster".
--
-- Why this is needed
-- ------------------
-- Regular items (stationery etc.) are day-to-day stock: GRN receipt tops up
-- nt_inventory_items, and staff draw from that shared pool via a manual
-- Store Requisition -> Store Issue. Non-Regular items are one-off/specific-
-- need purchases raised against a single PR — once GRN receives them, the
-- requester should not have to separately raise a Store Requisition; the
-- stock should become directly issuable against that PR. The classification
-- is set once per subcategory (inherited by every product filed under it)
-- rather than per-product or per-PR, per the chosen design.
--
-- Existing rows default to 'Regular' so nothing already live changes
-- behavior until someone explicitly marks a subcategory Non-Regular.
-- See grn-service/sql/22_nonregular_direct_issue.sql for the auto-issue
-- logic that reads this flag.
-- ============================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.subcategory_master') AND name = 'subcat_stock_type'
)
BEGIN
    ALTER TABLE dbo.subcategory_master
        ADD subcat_stock_type VARCHAR(20) NOT NULL
            CONSTRAINT DF_subcategory_master_stock_type DEFAULT 'Regular';
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE name = 'CK_subcategory_master_stock_type'
)
BEGIN
    ALTER TABLE dbo.subcategory_master
        ADD CONSTRAINT CK_subcategory_master_stock_type
            CHECK (subcat_stock_type IN ('Regular', 'Non-Regular'));
END
GO

-- ── sp_product_sub_catagory (GET) — now also returns subcat_stock_type ─────
IF OBJECT_ID('dbo.sp_product_sub_catagory', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_product_sub_catagory;
GO
CREATE PROCEDURE [dbo].[sp_product_sub_catagory]
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SELECT sc.[subcat_sno]
              ,sc.[subcat_name]
              ,sc.[subcat_description]
              ,sc.[subcat_notes]
              ,sc.[subcat_stock_type]
              ,sc.[cat_sno]
              ,cm.[cat_name]
        FROM [Non_Trade].[dbo].[subcategory_master] sc
        INNER JOIN [Non_Trade].[dbo].[category_master] cm ON cm.cat_sno = sc.cat_sno
        WHERE sc.subcat_active = 'Y'
        ORDER BY sc.subcat_sno;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

-- ── sp_nt_CreateSubCategoryRecords — now accepts subcat_stock_type ─────────
-- @jsonInput: {"cat_sno":1, "subcat_name":"...", "subcat_description":"...",
--              "subcat_notes":"...", "subcat_stock_type":"Regular"|"Non-Regular",
--              "created_by":"..."}
IF OBJECT_ID('dbo.sp_nt_CreateSubCategoryRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateSubCategoryRecords;
GO
CREATE PROCEDURE dbo.sp_nt_CreateSubCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @cat_sno            INT           = JSON_VALUE(@jsonInput, '$.cat_sno'),
            @subcat_name        NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.subcat_name'),
            @subcat_description NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.subcat_description'),
            @subcat_notes       NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.subcat_notes'),
            @subcat_stock_type  VARCHAR(20)   = ISNULL(NULLIF(JSON_VALUE(@jsonInput, '$.subcat_stock_type'), ''), 'Regular'),
            @created_by         VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @cat_sno IS NULL OR @subcat_name IS NULL OR LTRIM(RTRIM(@subcat_name)) = ''
    BEGIN
        THROW 50002, N'cat_sno and subcat_name are required.', 1;
        RETURN;
    END;

    IF @subcat_stock_type NOT IN ('Regular', 'Non-Regular')
    BEGIN
        THROW 50005, N'subcat_stock_type must be Regular or Non-Regular.', 1;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.category_master WHERE cat_sno = @cat_sno AND cat_active = 'Y')
    BEGIN
        THROW 50003, N'Category not found.', 1;
        RETURN;
    END;

    IF EXISTS (
        SELECT 1 FROM dbo.subcategory_master
        WHERE cat_sno = @cat_sno AND subcat_name = @subcat_name AND subcat_active = 'Y'
    )
    BEGIN
        THROW 50004, N'A sub category with this name already exists under the selected category.', 1;
        RETURN;
    END;

    INSERT INTO dbo.subcategory_master (
        cat_sno, subcat_name, subcat_description, subcat_notes, subcat_stock_type,
        subcat_active, subcat_created_date, subcat_created_by
    )
    VALUES (
        @cat_sno, @subcat_name, @subcat_description, @subcat_notes, @subcat_stock_type,
        'Y', GETDATE(), @created_by
    );

    SELECT SCOPE_IDENTITY()  AS subcat_sno,
           @subcat_name      AS subcat_name,
           @subcat_stock_type AS subcat_stock_type,
           N'SUCCESS'        AS status,
           N'Sub category created successfully.' AS message;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT subcat_sno, subcat_name, subcat_stock_type FROM dbo.subcategory_master ORDER BY subcat_sno DESC;
--   SELECT name FROM sys.procedures WHERE name IN ('sp_product_sub_catagory', 'sp_nt_CreateSubCategoryRecords');
-- ============================================================
