-- ============================================================
-- Product Stock Level master — product_stock_level_master
-- Database : Non_trade_Dev (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/ProductStockLevel (bespoke module, own routes —
--            NOT the generic /api/common_master pipeline, same reasoning as
--            terms_conditions_master/warehouse_location_master: this needs
--            working Update/Delete plus two mutually-exclusive scope shapes,
--            which the generic Masters grid doesn't support).
--
-- Why this exists
-- ---------------
-- Min Qty / Max Qty / Reorder Level today only exist as flat columns directly
-- on each grn-service nt_inventory_items row (grn-service/sql/02_inventory.sql),
-- entered ad-hoc per item with no per-product policy behind them. This master
-- lets an admin define a reusable Min/Max/Reorder policy PER PRODUCT, scoped
-- either:
--   (a) by Company -> Division -> Branch (ORG), where Division/Branch are
--       optional narrowing — a company-only entry applies to every division/
--       branch under it unless a more specific entry exists for the same
--       product; a division-only entry (no branch) applies to every branch
--       in that division; a branch-level entry is the most specific, OR
--   (b) by a single Warehouse Location (LOCATION) — dbo.warehouse_location_master,
--       for products whose reorder policy is tied to a physical location
--       rather than the org hierarchy (e.g. a shared regional warehouse).
-- Exactly one of these two shapes applies per row (CK_..._scope_shape below);
-- an admin picks whichever fits a given product.
--
-- This is deliberately OPT-IN, not mandatory, per product: "rare" products
-- that don't need reorder tracking simply have no row here at all. Consumers
-- (see grn-service/sql/29_inventory_stock_level_reference.sql) treat "no
-- matching row" as a normal, expected case, not an error.
--
-- Per product decision (2026-09-08 AskUserQuestion): integration into the
-- Inventory Stock page is REFERENCE ONLY — this master's values are shown
-- alongside each inventory item's own independently-editable Min/Max/Reorder
-- fields, never auto-overriding them. So there is deliberately no "apply to
-- inventory items" sync procedure here.
-- ============================================================

IF OBJECT_ID('dbo.product_stock_level_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.product_stock_level_master (
        stock_level_sno INT IDENTITY(1,1) PRIMARY KEY,
        prod_sno        INT            NOT NULL,
        scope_type      VARCHAR(10)    NOT NULL,   -- 'ORG' | 'LOCATION'
        com_sno         INT            NULL,
        div_sno         INT            NULL,
        brn_sno         INT            NULL,
        location_sno    INT            NULL,
        min_qty         DECIMAL(18,2)  NOT NULL,
        max_qty         DECIMAL(18,2)  NOT NULL,
        reorder_level   DECIMAL(18,2)  NOT NULL,
        is_active       CHAR(1)        NOT NULL DEFAULT 'Y',
        created_by      VARCHAR(20)    NULL,
        created_date    DATETIME       NOT NULL DEFAULT GETDATE(),
        modified_by     VARCHAR(20)    NULL,
        modified_date   DATETIME       NULL,
        CONSTRAINT CK_prod_stock_level_scope_type CHECK (scope_type IN ('ORG','LOCATION')),
        CONSTRAINT CK_prod_stock_level_is_active  CHECK (is_active IN ('Y','N')),
        CONSTRAINT CK_prod_stock_level_scope_shape CHECK (
            (scope_type = 'ORG'      AND com_sno IS NOT NULL AND location_sno IS NULL)
         OR (scope_type = 'LOCATION' AND location_sno IS NOT NULL AND com_sno IS NULL AND div_sno IS NULL AND brn_sno IS NULL)
        ),
        CONSTRAINT CK_prod_stock_level_qty_range CHECK (
            min_qty >= 0 AND max_qty >= 0 AND reorder_level >= 0
            AND min_qty <= max_qty
            AND reorder_level BETWEEN min_qty AND max_qty
        )
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_prod_stock_level_prod_sno' AND object_id = OBJECT_ID('dbo.product_stock_level_master'))
    CREATE INDEX IX_prod_stock_level_prod_sno ON dbo.product_stock_level_master (prod_sno);
GO

-- ── sp_nt_GetProductStockLevels ─────────────────────────────────────────────
-- Full grid list (admin screen). scope_label is a human-readable summary of
-- whichever of the two scope shapes the row uses.
IF OBJECT_ID('dbo.sp_nt_GetProductStockLevels', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetProductStockLevels;
GO
CREATE PROCEDURE dbo.sp_nt_GetProductStockLevels
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.stock_level_sno,
        p.prod_sno, pm.prod_name, pm.prod_code,
        p.scope_type,
        p.com_sno,  c.com_name,
        p.div_sno,  d.div_name,
        p.brn_sno,  b.brn_name,
        p.location_sno, wl.location_name, wl.location_code,
        CASE
            WHEN p.scope_type = 'LOCATION' THEN N'Warehouse: ' + ISNULL(wl.location_name, N'(deleted)')
            WHEN p.brn_sno IS NOT NULL THEN c.com_name + N' / ' + d.div_name + N' / ' + b.brn_name
            WHEN p.div_sno IS NOT NULL THEN c.com_name + N' / ' + d.div_name + N' / All Branches'
            ELSE c.com_name + N' / All Divisions'
        END AS scope_label,
        p.min_qty, p.max_qty, p.reorder_level,
        p.is_active,
        p.created_by,
        CONVERT(VARCHAR(30), p.created_date, 120)  AS created_date,
        p.modified_by,
        CONVERT(VARCHAR(30), p.modified_date, 120) AS modified_date
    FROM dbo.product_stock_level_master p
    JOIN dbo.product_master pm            ON pm.prod_sno = p.prod_sno
    LEFT JOIN dbo.company_master c         ON c.com_sno  = p.com_sno
    LEFT JOIN dbo.division_master d        ON d.div_sno  = p.div_sno
    LEFT JOIN dbo.branch_master b          ON b.brn_sno  = p.brn_sno
    LEFT JOIN dbo.warehouse_location_master wl ON wl.location_sno = p.location_sno
    WHERE p.is_active = 'Y'
    ORDER BY pm.prod_name, p.scope_type, c.com_name, d.div_name, b.brn_name;
END;
GO

-- ── sp_nt_CreateProductStockLevel ───────────────────────────────────────────
-- @jsonInput: {"prod_sno":1, "scope_type":"ORG"|"LOCATION",
--              "com_sno":1, "div_sno":null, "brn_sno":null,   -- when ORG
--              "location_sno":null,                            -- when LOCATION
--              "min_qty":10, "max_qty":100, "reorder_level":25, "created_by":"..."}
IF OBJECT_ID('dbo.sp_nt_CreateProductStockLevel', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateProductStockLevel;
GO
CREATE PROCEDURE dbo.sp_nt_CreateProductStockLevel
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 59501, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @prod_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.prod_sno') AS INT),
            @scope_type     VARCHAR(10)   = JSON_VALUE(@jsonInput, '$.scope_type'),
            @com_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT),
            @div_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT),
            @brn_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT),
            @location_sno   INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.location_sno') AS INT),
            @min_qty        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.min_qty') AS DECIMAL(18,2)),
            @max_qty        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.max_qty') AS DECIMAL(18,2)),
            @reorder_level  DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.reorder_level') AS DECIMAL(18,2)),
            @created_by     VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @prod_sno IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.product_master WHERE prod_sno = @prod_sno)
    BEGIN
        THROW 59502, N'A valid product must be selected.', 1;
        RETURN;
    END;

    IF @scope_type NOT IN ('ORG','LOCATION')
    BEGIN
        THROW 59503, N'scope_type must be either ORG or LOCATION.', 1;
        RETURN;
    END;

    IF @min_qty IS NULL OR @max_qty IS NULL OR @reorder_level IS NULL
    BEGIN
        THROW 59504, N'Min Qty, Max Qty and Reorder Level are all required.', 1;
        RETURN;
    END;

    IF @min_qty < 0 OR @max_qty < 0 OR @reorder_level < 0
    BEGIN
        THROW 59505, N'Min Qty, Max Qty and Reorder Level cannot be negative.', 1;
        RETURN;
    END;

    IF @min_qty > @max_qty
    BEGIN
        THROW 59506, N'Min Qty cannot be greater than Max Qty.', 1;
        RETURN;
    END;

    IF @reorder_level < @min_qty OR @reorder_level > @max_qty
    BEGIN
        THROW 59507, N'Reorder Level must be between Min Qty and Max Qty.', 1;
        RETURN;
    END;

    IF @scope_type = 'ORG'
    BEGIN
        SET @location_sno = NULL;

        IF @com_sno IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.company_master WHERE com_sno = @com_sno)
        BEGIN
            THROW 59508, N'A valid company must be selected for an Org-scoped entry.', 1;
            RETURN;
        END;

        IF @div_sno IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.division_master WHERE div_sno = @div_sno AND com_sno = @com_sno)
        BEGIN
            THROW 59509, N'Selected division does not belong to the selected company.', 1;
            RETURN;
        END;

        IF @brn_sno IS NOT NULL AND @div_sno IS NULL
        BEGIN
            THROW 59510, N'A branch cannot be selected without also selecting its division.', 1;
            RETURN;
        END;

        IF @brn_sno IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.branch_master WHERE brn_sno = @brn_sno AND com_sno = @com_sno AND div_sno = @div_sno)
        BEGIN
            THROW 59511, N'Selected branch does not belong to the selected company/division.', 1;
            RETURN;
        END;

        IF EXISTS (
            SELECT 1 FROM dbo.product_stock_level_master
            WHERE prod_sno = @prod_sno AND scope_type = 'ORG' AND is_active = 'Y'
              AND com_sno = @com_sno
              AND ISNULL(div_sno, -1) = ISNULL(@div_sno, -1)
              AND ISNULL(brn_sno, -1) = ISNULL(@brn_sno, -1)
        )
        BEGIN
            THROW 59512, N'This product already has stock levels configured for this exact Company/Division/Branch scope.', 1;
            RETURN;
        END;
    END
    ELSE  -- LOCATION
    BEGIN
        SET @com_sno = NULL; SET @div_sno = NULL; SET @brn_sno = NULL;

        IF @location_sno IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.warehouse_location_master WHERE location_sno = @location_sno AND is_active = 'Y')
        BEGIN
            THROW 59513, N'A valid warehouse location must be selected.', 1;
            RETURN;
        END;

        IF EXISTS (
            SELECT 1 FROM dbo.product_stock_level_master
            WHERE prod_sno = @prod_sno AND scope_type = 'LOCATION' AND is_active = 'Y' AND location_sno = @location_sno
        )
        BEGIN
            THROW 59514, N'This product already has stock levels configured for this warehouse location.', 1;
            RETURN;
        END;
    END;

    INSERT INTO dbo.product_stock_level_master (
        prod_sno, scope_type, com_sno, div_sno, brn_sno, location_sno,
        min_qty, max_qty, reorder_level, is_active, created_by
    )
    VALUES (
        @prod_sno, @scope_type, @com_sno, @div_sno, @brn_sno, @location_sno,
        @min_qty, @max_qty, @reorder_level, 'Y', @created_by
    );

    SELECT SCOPE_IDENTITY() AS stock_level_sno, N'SUCCESS' AS status,
           N'Stock level configuration saved successfully.' AS message;
END;
GO

-- ── sp_nt_UpdateProductStockLevel ───────────────────────────────────────────
-- Scope (prod_sno/scope_type/com_sno/div_sno/brn_sno/location_sno) is
-- immutable after creation, same convention as terms_conditions_master —
-- add a new entry instead of moving an existing one to a different scope.
-- @jsonInput: {"stock_level_sno":1, "min_qty":10, "max_qty":100,
--              "reorder_level":25, "is_active":"Y"|"N", "modified_by":"..."}
IF OBJECT_ID('dbo.sp_nt_UpdateProductStockLevel', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_UpdateProductStockLevel;
GO
CREATE PROCEDURE dbo.sp_nt_UpdateProductStockLevel
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @stock_level_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.stock_level_sno') AS INT),
            @min_qty         DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.min_qty') AS DECIMAL(18,2)),
            @max_qty         DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.max_qty') AS DECIMAL(18,2)),
            @reorder_level   DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.reorder_level') AS DECIMAL(18,2)),
            @is_active       CHAR(1)       = JSON_VALUE(@jsonInput, '$.is_active'),
            @modified_by     VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.modified_by');

    IF @stock_level_sno IS NULL
    BEGIN
        THROW 59515, N'stock_level_sno is required.', 1;
        RETURN;
    END;

    DECLARE @existing_min DECIMAL(18,2), @existing_max DECIMAL(18,2), @existing_reorder DECIMAL(18,2);
    SELECT @existing_min = min_qty, @existing_max = max_qty, @existing_reorder = reorder_level
    FROM dbo.product_stock_level_master WHERE stock_level_sno = @stock_level_sno;

    IF @existing_min IS NULL
    BEGIN
        THROW 59516, N'Stock level configuration not found.', 1;
        RETURN;
    END;

    SET @min_qty       = ISNULL(@min_qty, @existing_min);
    SET @max_qty       = ISNULL(@max_qty, @existing_max);
    SET @reorder_level = ISNULL(@reorder_level, @existing_reorder);

    IF @min_qty < 0 OR @max_qty < 0 OR @reorder_level < 0
    BEGIN
        THROW 59517, N'Min Qty, Max Qty and Reorder Level cannot be negative.', 1;
        RETURN;
    END;

    IF @min_qty > @max_qty
    BEGIN
        THROW 59518, N'Min Qty cannot be greater than Max Qty.', 1;
        RETURN;
    END;

    IF @reorder_level < @min_qty OR @reorder_level > @max_qty
    BEGIN
        THROW 59519, N'Reorder Level must be between Min Qty and Max Qty.', 1;
        RETURN;
    END;

    UPDATE dbo.product_stock_level_master
    SET min_qty       = @min_qty,
        max_qty       = @max_qty,
        reorder_level = @reorder_level,
        is_active     = ISNULL(@is_active, is_active),
        modified_by   = @modified_by,
        modified_date = GETDATE()
    WHERE stock_level_sno = @stock_level_sno;

    SELECT @stock_level_sno AS stock_level_sno, N'SUCCESS' AS status,
           N'Stock level configuration updated successfully.' AS message;
END;
GO

-- ── sp_nt_DeleteProductStockLevel ───────────────────────────────────────────
-- Soft delete — is_active flips to 'N' (same convention as terms_conditions_master).
-- @jsonInput: {"stock_level_sno":1, "modified_by":"..."}
IF OBJECT_ID('dbo.sp_nt_DeleteProductStockLevel', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_DeleteProductStockLevel;
GO
CREATE PROCEDURE dbo.sp_nt_DeleteProductStockLevel
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @stock_level_sno INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.stock_level_sno') AS INT),
            @modified_by     VARCHAR(20) = JSON_VALUE(@jsonInput, '$.modified_by');

    IF @stock_level_sno IS NULL
    BEGIN
        THROW 59520, N'stock_level_sno is required.', 1;
        RETURN;
    END;

    UPDATE dbo.product_stock_level_master
    SET is_active = 'N', modified_by = @modified_by, modified_date = GETDATE()
    WHERE stock_level_sno = @stock_level_sno;

    SELECT @stock_level_sno AS stock_level_sno, N'SUCCESS' AS status,
           N'Stock level configuration deleted successfully.' AS message;
END;
GO

-- ── sp_nt_GetApplicableStockLevel ───────────────────────────────────────────
-- Reference lookup for a single product + scope — returns the single
-- best-matching active row (LOCATION match wins if the item's own location
-- resolves to one, otherwise the most specific ORG match: branch > division >
-- company), or zero rows when nothing is configured for that product at all
-- (the normal case for a "rare"/untracked product).
-- @jsonInput: {"prod_sno":1, "com_sno":1, "div_sno":2, "brn_sno":3, "location_sno":9}
IF OBJECT_ID('dbo.sp_nt_GetApplicableStockLevel', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetApplicableStockLevel;
GO
CREATE PROCEDURE dbo.sp_nt_GetApplicableStockLevel
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @prod_sno     INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.prod_sno') AS INT),
            @com_sno      INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT),
            @div_sno      INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT),
            @brn_sno      INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT),
            @location_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.location_sno') AS INT);

    SELECT TOP 1
        p.stock_level_sno, p.scope_type, p.min_qty, p.max_qty, p.reorder_level,
        CASE
            WHEN p.scope_type = 'LOCATION' THEN 100
            WHEN p.brn_sno IS NOT NULL THEN 3
            WHEN p.div_sno IS NOT NULL THEN 2
            ELSE 1
        END AS specificity
    FROM dbo.product_stock_level_master p
    WHERE p.prod_sno = @prod_sno
      AND p.is_active = 'Y'
      AND (
            (p.scope_type = 'LOCATION' AND @location_sno IS NOT NULL AND p.location_sno = @location_sno)
         OR (p.scope_type = 'ORG' AND p.com_sno = @com_sno
             AND (p.div_sno IS NULL OR p.div_sno = @div_sno)
             AND (p.brn_sno IS NULL OR p.brn_sno = @brn_sno))
          )
    ORDER BY specificity DESC;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.product_stock_level_master ORDER BY stock_level_sno;
--   SELECT name FROM sys.procedures WHERE name LIKE 'sp_nt_%ProductStockLevel%' OR name LIKE 'sp_nt_%ApplicableStockLevel%';
-- ============================================================
