-- ============================================================
-- Add a third subcat_stock_type value: 'Perishable'
-- Database: Non_trade_Dev (MSSQL)
--
-- Until now subcategory_master.subcat_stock_type was Regular | Non-Regular
-- (see 50_subcategory_stock_type.sql). Vendor-driven canteen items
-- (vegetables, milk, eggs) need a third classification: Perishable, with
-- a per-subcategory shelf-life (perishable_days). Two things ride on this:
--   1. Perishable items auto-issue off GRN exactly like Non-Regular does
--      (see grn-service/sql/30_perishable_expiry_stock.sql for the
--      sp_nt_AutoCreateStockIssueFromGRN gating change) — the existing
--      Pending -> Partially Issued -> Issued lifecycle in
--      sp_nt_IssueStockRequest already supports issuing part of a request
--      now and the rest later, so nothing there needs to change.
--   2. The Inventory Stock page can flag "still on hand after its shelf
--      life" (see the same grn-service file for sp_nt_GetInventoryItems).
-- ============================================================

-- ── subcat_stock_type: widen the CHECK constraint ──────────────────────────
IF EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE name = 'CK_subcategory_master_stock_type'
      AND parent_object_id = OBJECT_ID('dbo.subcategory_master')
)
    ALTER TABLE dbo.subcategory_master DROP CONSTRAINT CK_subcategory_master_stock_type;
GO

ALTER TABLE dbo.subcategory_master
    ADD CONSTRAINT CK_subcategory_master_stock_type
        CHECK (subcat_stock_type IN ('Regular', 'Non-Regular', 'Perishable'));
GO

-- ── perishable_days: shelf life in days, only meaningful for Perishable ────
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.subcategory_master') AND name = 'perishable_days'
)
    ALTER TABLE dbo.subcategory_master ADD perishable_days INT NULL;
GO

IF EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE name = 'CK_subcategory_master_perishable_days'
      AND parent_object_id = OBJECT_ID('dbo.subcategory_master')
)
    ALTER TABLE dbo.subcategory_master DROP CONSTRAINT CK_subcategory_master_perishable_days;
GO

ALTER TABLE dbo.subcategory_master
    ADD CONSTRAINT CK_subcategory_master_perishable_days
        CHECK (perishable_days IS NULL OR perishable_days > 0);
GO

-- ============================================================
-- sp_nt_CreateSubCategoryRecords — accept + validate perishable_days
-- Only additive: everything except the marked lines is unchanged from the
-- live definition (pulled via OBJECT_DEFINITION before editing).
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateSubCategoryRecords
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
            @perishable_days    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.perishable_days') AS INT),
            @created_by         VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @cat_sno IS NULL OR @subcat_name IS NULL OR LTRIM(RTRIM(@subcat_name)) = ''
    BEGIN
        THROW 50002, N'cat_sno and subcat_name are required.', 1;
        RETURN;
    END;

    IF @subcat_stock_type NOT IN ('Regular', 'Non-Regular', 'Perishable')
    BEGIN
        THROW 50005, N'subcat_stock_type must be Regular, Non-Regular or Perishable.', 1;
        RETURN;
    END;

    -- New: perishable_days is mandatory (and > 0, enforced by the CHECK
    -- constraint too) only when the subcategory is Perishable; ignored/
    -- cleared otherwise so a stray value from the form can't leak in.
    IF @subcat_stock_type = 'Perishable' AND (@perishable_days IS NULL OR @perishable_days <= 0)
    BEGIN
        THROW 50006, N'perishable_days is required and must be greater than zero when subcat_stock_type is Perishable.', 1;
        RETURN;
    END;

    IF @subcat_stock_type <> 'Perishable'
        SET @perishable_days = NULL;

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
        cat_sno, subcat_name, subcat_description, subcat_notes, subcat_stock_type, perishable_days,
        subcat_active, subcat_created_date, subcat_created_by
    )
    VALUES (
        @cat_sno, @subcat_name, @subcat_description, @subcat_notes, @subcat_stock_type, @perishable_days,
        'Y', GETDATE(), @created_by
    );

    SELECT SCOPE_IDENTITY()   AS subcat_sno,
           @subcat_name       AS subcat_name,
           @subcat_stock_type AS subcat_stock_type,
           @perishable_days   AS perishable_days,
           N'SUCCESS'         AS status,
           N'Sub category created successfully.' AS message;
END;
GO
