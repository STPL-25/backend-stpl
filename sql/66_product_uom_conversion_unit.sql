-- ============================================================
-- Product-specific UOM conversion UNIT — product_master.prod_uom_con_uom_sno
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/Masters (ProductMaster create, sp_nt_CreateProductRecord)
--
-- Why this is needed
-- ------------------
-- 26_product_uom_conversion_factor.sql added product_master.prod_uom_con_factor
-- so a per-product packaging unit (uom_master.uom_con_factor IS NULL, e.g. Box)
-- can carry its own ratio (e.g. "1 Box = 20 pieces"). That works cleanly for
-- QUANTITY-class units, where the implied target is always "pieces" and a bare
-- number is unambiguous.
--
-- It breaks down for a container unit whose class is MASS/VOLUME/etc — e.g. a
-- "Tin" purchased in different sizes across products (one product's Tin holds
-- 20 KG, another's holds 5 KG). A bare prod_uom_con_factor of "20" no longer
-- tells you the unit it's denominated in (20 KG? 20 G? 20 LB?), yet issuing/
-- stock tracking happens in a specific base unit (KG). uom_master already
-- groups every unit under a uom_class (MASS, VOLUME, LENGTH, AREA, QUANTITY —
-- confirmed live, already populated, not free text in practice) with exactly
-- one base unit per class (uom_base_uom_flag='Y').
--
-- Fix: capture WHICH unit prod_uom_con_factor is expressed in, restricted to
-- the same uom_class as the product's own purchase uom_sno (so a Tin can only
-- be expressed in MASS units — KG, G, LB, OZ, TON — never Liters). Defaults to
-- the class's base unit when not explicitly chosen. Existing rows (e.g. Box
-- products with prod_uom_con_factor already set) get prod_uom_con_uom_sno =
-- NULL, which every consumer should read as "the class's base unit" (Piece,
-- for the only class in use before this migration) — fully backward compatible.
--
-- sp_nt_GetProductRecords is regenerated (not just left as SELECT *) because
-- the new column is itself a UOM foreign key — callers need the conversion
-- unit's NAME, not just its uom_sno, which requires a second join to
-- uom_master. The existing `SELECT *` is kept as-is (so every previously
-- available column stays available) with the two new joined columns appended.
-- ============================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.product_master') AND name = 'prod_uom_con_uom_sno'
)
BEGIN
    ALTER TABLE dbo.product_master ADD prod_uom_con_uom_sno INT NULL;
END;
GO

-- ── sp_nt_CreateProductRecord ───────────────────────────────────────────────
IF OBJECT_ID('dbo.sp_nt_CreateProductRecord', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateProductRecord;
GO
CREATE   PROCEDURE [dbo].[sp_nt_CreateProductRecord]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    -- ───────────────────────────────────────────
    -- 1. Basic Input Validation
    -- ───────────────────────────────────────────
    IF @jsonInput IS NULL OR LTRIM(RTRIM(@jsonInput)) = ''
    BEGIN
        SELECT 'Failed' AS Status, 'JSON input is required' AS ErrorMessage;
        RETURN;
    END

    IF ISJSON(@jsonInput) = 0
    BEGIN
        SELECT 'Failed' AS Status, 'Invalid JSON format' AS ErrorMessage;
        RETURN;
    END

    -- ───────────────────────────────────────────
    -- 2. Normalize: wrap single object into array
    --    Handles both {} and [{}] inputs transparently
    -- ───────────────────────────────────────────
    DECLARE @normalizedJson NVARCHAR(MAX);

    SET @normalizedJson = CASE
        WHEN LEFT(LTRIM(@jsonInput), 1) = '{'
        THEN '[' + @jsonInput + ']'   -- single object → wrap as array
        ELSE @jsonInput               -- already an array
    END;

    -- Re-validate after normalization
    IF ISJSON(@normalizedJson) = 0
    BEGIN
        SELECT 'Failed' AS Status, 'Invalid JSON structure after normalization' AS ErrorMessage;
        RETURN;
    END

    BEGIN TRY

        -- ───────────────────────────────────────────
        -- 3. Parse JSON Array into Temp Table ONCE
        --    WITH clause = single parse pass (faster)
        --    ROW_NUMBER() used instead of [key]
        --    ([key] not available when WITH clause is used)
        -- ───────────────────────────────────────────
        CREATE TABLE #parsed_input (
            row_index            INT,
            company_sno          INT,
            division_sno         INT,
            branch_sno           INT,
            dept_sno             INT,
            cat_sno              INT,
            subcat_sno           INT,
            prod_name            VARCHAR(255),
            prod_description     VARCHAR(MAX),
            prod_notes           VARCHAR(MAX),
            hsn_code             VARCHAR(50),
            uom_sno              INT,
            tax_sno              INT,
            prod_uom_con_factor  DECIMAL(18,6),
            prod_uom_con_uom_sno INT,
            created_by           VARCHAR(50)
        );

        INSERT INTO #parsed_input
        SELECT
            ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1  AS row_index,
            company_sno,
            division_sno,
            branch_sno,
            dept_sno,
            cat_sno,
            subcat_sno,
            LTRIM(RTRIM(prod_name))                         AS prod_name,
            LTRIM(RTRIM(ISNULL(prod_description, '')))      AS prod_description,
            LTRIM(RTRIM(ISNULL(prod_notes, '')))            AS prod_notes,
            LTRIM(RTRIM(ISNULL(hsn_code, '')))              AS hsn_code,
            uom_sno,
            tax_sno,
            prod_uom_con_factor,
            prod_uom_con_uom_sno,
            created_by
        FROM OPENJSON(@normalizedJson)
        WITH (
            company_sno          INT             '$.company_sno',
            division_sno         INT             '$.division_sno',
            branch_sno           INT             '$.branch_sno',
            dept_sno             INT             '$.dept_sno',
            cat_sno              INT             '$.cat_sno',
            subcat_sno           INT             '$.subcat_sno',
            prod_name            VARCHAR(255)    '$.prod_name',
            prod_description     VARCHAR(MAX)    '$.prod_description',
            prod_notes           VARCHAR(MAX)    '$.prod_notes',
            hsn_code             VARCHAR(50)     '$.hsn_code',
            uom_sno              INT             '$.uom_sno',
            tax_sno              INT             '$.tax_sno',
            prod_uom_con_factor  DECIMAL(18,6)   '$.prod_uom_con_factor',
            prod_uom_con_uom_sno INT             '$.prod_uom_con_uom_sno',
            created_by           VARCHAR(50)     '$.created_by'
        );

        -- ───────────────────────────────────────────
        -- 4. Row-Level Validation
        --    Collects ALL failures across ALL rows before aborting
        -- ───────────────────────────────────────────
        CREATE TABLE #validation_errors (
            row_index    INT,
            ErrorMessage VARCHAR(500)
        );

        INSERT INTO #validation_errors (row_index, ErrorMessage)
        SELECT row_index, 'cat_sno is required'
            FROM #parsed_input WHERE cat_sno IS NULL
        UNION ALL
        SELECT row_index, 'prod_name is required'
            FROM #parsed_input WHERE prod_name IS NULL OR prod_name = ''
        UNION ALL
        SELECT row_index, 'uom_sno is required'
            FROM #parsed_input WHERE uom_sno IS NULL;

        IF EXISTS (SELECT 1 FROM #validation_errors)
        BEGIN
            SELECT
                'Failed'   AS Status,
                row_index  AS RowIndex,
                ErrorMessage
            FROM #validation_errors
            ORDER BY row_index;

            DROP TABLE #parsed_input;
            DROP TABLE #validation_errors;
            RETURN;
        END

        DROP TABLE #validation_errors;

        -- ───────────────────────────────────────────
        -- 5. Validate All Categories Exist (set-based)
        -- ───────────────────────────────────────────
        IF EXISTS (
            SELECT 1
            FROM (SELECT DISTINCT cat_sno FROM #parsed_input) pi
            LEFT JOIN category_master cm ON cm.cat_sno = pi.cat_sno
            WHERE cm.cat_sno IS NULL
        )
        BEGIN
            SELECT
                'Failed'             AS Status,
                pi.cat_sno           AS InvalidCatSno,
                'Category not found' AS ErrorMessage
            FROM (SELECT DISTINCT cat_sno FROM #parsed_input) pi
            LEFT JOIN category_master cm ON cm.cat_sno = pi.cat_sno
            WHERE cm.cat_sno IS NULL;

            DROP TABLE #parsed_input;
            RETURN;
        END

        -- ───────────────────────────────────────────
        -- 5b. Validate product-specific UOM conversion factor + unit
        --     A non-base UOM with no fixed uom_master.uom_con_factor (e.g.
        --     Box, Tin) varies per product, so prod_uom_con_factor AND
        --     prod_uom_con_uom_sno must both be supplied. The chosen
        --     conversion unit must exist and belong to the SAME uom_class as
        --     the product's own uom_sno (a Tin's contents can only be
        --     expressed in a MASS unit, never a VOLUME/LENGTH one).
        -- ───────────────────────────────────────────
        IF EXISTS (
            SELECT 1
            FROM #parsed_input pi
            JOIN uom_master um ON um.uom_sno = pi.uom_sno
            WHERE um.uom_base_uom_flag = 'N'
              AND um.uom_con_factor IS NULL
              AND (pi.prod_uom_con_factor IS NULL OR pi.prod_uom_con_factor <= 0)
        )
        BEGIN
            SELECT
                'Failed'                                                    AS Status,
                pi.row_index                                                AS RowIndex,
                'prod_uom_con_factor is required for unit ' + um.uom_name +
                    ' (its conversion is not fixed and varies per product)' AS ErrorMessage
            FROM #parsed_input pi
            JOIN uom_master um ON um.uom_sno = pi.uom_sno
            WHERE um.uom_base_uom_flag = 'N'
              AND um.uom_con_factor IS NULL
              AND (pi.prod_uom_con_factor IS NULL OR pi.prod_uom_con_factor <= 0);

            DROP TABLE #parsed_input;
            RETURN;
        END

        IF EXISTS (
            SELECT 1
            FROM #parsed_input pi
            JOIN uom_master um ON um.uom_sno = pi.uom_sno
            WHERE um.uom_base_uom_flag = 'N'
              AND um.uom_con_factor IS NULL
              AND pi.prod_uom_con_uom_sno IS NULL
        )
        BEGIN
            SELECT
                'Failed'                                                    AS Status,
                pi.row_index                                                AS RowIndex,
                'prod_uom_con_uom_sno is required for unit ' + um.uom_name +
                    ' (choose the unit the quantity above is expressed in)' AS ErrorMessage
            FROM #parsed_input pi
            JOIN uom_master um ON um.uom_sno = pi.uom_sno
            WHERE um.uom_base_uom_flag = 'N'
              AND um.uom_con_factor IS NULL
              AND pi.prod_uom_con_uom_sno IS NULL;

            DROP TABLE #parsed_input;
            RETURN;
        END

        IF EXISTS (
            SELECT 1
            FROM #parsed_input pi
            JOIN uom_master um    ON um.uom_sno = pi.uom_sno
            LEFT JOIN uom_master cu ON cu.uom_sno = pi.prod_uom_con_uom_sno
            WHERE pi.prod_uom_con_uom_sno IS NOT NULL
              AND (cu.uom_sno IS NULL OR cu.uom_class <> um.uom_class)
        )
        BEGIN
            SELECT
                'Failed'                                                        AS Status,
                pi.row_index                                                    AS RowIndex,
                'prod_uom_con_uom_sno must be a valid unit of the same class (' +
                    um.uom_class + ') as ' + um.uom_name                        AS ErrorMessage
            FROM #parsed_input pi
            JOIN uom_master um    ON um.uom_sno = pi.uom_sno
            LEFT JOIN uom_master cu ON cu.uom_sno = pi.prod_uom_con_uom_sno
            WHERE pi.prod_uom_con_uom_sno IS NOT NULL
              AND (cu.uom_sno IS NULL OR cu.uom_class <> um.uom_class);

            DROP TABLE #parsed_input;
            RETURN;
        END

        -- ───────────────────────────────────────────
        -- 6. Generate Product Codes — set-based per category
        --    MAX existing seq fetched once per category (with lock)
        --    ROW_NUMBER() per cat assigns each new row its offset
        -- ───────────────────────────────────────────
        CREATE TABLE #products_with_code (
            row_index            INT,
            company_sno          INT,
            division_sno         INT,
            branch_sno           INT,
            dept_sno             INT,
            cat_sno              INT,
            subcat_sno           INT,
            prod_name            VARCHAR(255),
            prod_description     VARCHAR(MAX),
            prod_notes           VARCHAR(MAX),
            prod_code            VARCHAR(50),
            hsn_code             VARCHAR(50),
            uom_sno              INT,
            tax_sno              INT,
            prod_uom_con_factor  DECIMAL(18,6),
            prod_uom_con_uom_sno INT,
            created_by           VARCHAR(50)
        );

        ;WITH CategoryPrefix AS (
            SELECT
                cm.cat_sno,
                cm.cat_notes AS cat_prefix,
                ISNULL(MAX(
                    CASE
                        WHEN ISNUMERIC(
                            SUBSTRING(pm.prod_code, LEN(cm.cat_notes) + 1, LEN(pm.prod_code))
                        ) = 1
                        THEN CAST(
                            SUBSTRING(pm.prod_code, LEN(cm.cat_notes) + 1, LEN(pm.prod_code))
                        AS INT)
                        ELSE 0
                    END
                ), 0) AS max_seq
            FROM (SELECT DISTINCT cat_sno FROM #parsed_input) pi
            JOIN category_master cm ON cm.cat_sno = pi.cat_sno
            LEFT JOIN product_master pm WITH (UPDLOCK, ROWLOCK)
                ON  pm.cat_sno   = cm.cat_sno
                AND pm.prod_code LIKE cm.cat_notes + '%'
            GROUP BY cm.cat_sno, cm.cat_notes
        ),
        RankedRows AS (
            SELECT
                pi.*,
                cp.cat_prefix,
                cp.max_seq,
                ROW_NUMBER() OVER (
                    PARTITION BY pi.cat_sno
                    ORDER BY pi.row_index
                ) AS rn
            FROM #parsed_input pi
            JOIN CategoryPrefix cp ON cp.cat_sno = pi.cat_sno
        )
        INSERT INTO #products_with_code
        SELECT
            row_index,
            company_sno,
            division_sno,
            branch_sno,
            dept_sno,
            cat_sno,
            subcat_sno,
            prod_name,
            prod_description,
            prod_notes,
            cat_prefix + RIGHT('00000' + CAST((max_seq + rn) AS VARCHAR(5)), 5) AS prod_code,
            hsn_code,
            uom_sno,
            tax_sno,
            prod_uom_con_factor,
            prod_uom_con_uom_sno,
            created_by
        FROM RankedRows;

        DROP TABLE #parsed_input;

        -- ───────────────────────────────────────────
        -- 7. Bulk Insert with OUTPUT clause
        --    All prod_sno values captured safely — no SCOPE_IDENTITY() race
        -- ───────────────────────────────────────────
        CREATE TABLE #inserted_results (
            prod_sno  INT,
            prod_code VARCHAR(50)
        );

        BEGIN TRANSACTION;

            INSERT INTO [dbo].[product_master] (
                company_sno,
                division_sno,
                branch_sno,
                dept_sno,
                cat_sno,
                subcat_sno,
                prod_name,
                prod_description,
                prod_notes,
                prod_code,
                uom_sno,
                tax_sno,
                prod_hsn_code,
                prod_uom_con_factor,
                prod_uom_con_uom_sno,
                prod_active,
                prod_created_date,
                prod_created_by
            )
            OUTPUT
                INSERTED.prod_sno,
                INSERTED.prod_code
            INTO #inserted_results (prod_sno, prod_code)
            SELECT
                company_sno,
                division_sno,
                branch_sno,
                dept_sno,
                cat_sno,
                subcat_sno,
                prod_name,
                prod_description,
                prod_notes,
                prod_code,
                uom_sno,
                tax_sno,
                hsn_code             AS prod_hsn_code,
                prod_uom_con_factor,
                prod_uom_con_uom_sno,
                'Y'                  AS prod_active,
                GETDATE()            AS prod_created_date,
                created_by           AS prod_created_by
            FROM #products_with_code
            ORDER BY row_index;

        COMMIT TRANSACTION;

        -- ───────────────────────────────────────────
        -- 8. Return Results — joined via prod_code
        -- ───────────────────────────────────────────
        SELECT
            'Success'                       AS Status,
            'Product inserted successfully' AS Message,
            ir.prod_sno,
            ir.prod_code,
            pwc.prod_name,
            pwc.cat_sno,
            pwc.row_index                   AS InputRowIndex
        FROM #inserted_results ir
        JOIN #products_with_code pwc ON pwc.prod_code = ir.prod_code
        ORDER BY pwc.row_index;

        DROP TABLE #products_with_code;
        DROP TABLE #inserted_results;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        IF OBJECT_ID('tempdb..#parsed_input')       IS NOT NULL DROP TABLE #parsed_input;
        IF OBJECT_ID('tempdb..#validation_errors')  IS NOT NULL DROP TABLE #validation_errors;
        IF OBJECT_ID('tempdb..#products_with_code') IS NOT NULL DROP TABLE #products_with_code;
        IF OBJECT_ID('tempdb..#inserted_results')   IS NOT NULL DROP TABLE #inserted_results;

        SELECT
            'Failed'        AS Status,
            ERROR_MESSAGE() AS ErrorMessage,
            ERROR_NUMBER()  AS ErrorNumber,
            ERROR_LINE()    AS ErrorLine;
    END CATCH
END
GO

-- ── sp_nt_GetProductRecords ─────────────────────────────────────────────────
-- Kept as `SELECT *` (so every column previously returned still is) with the
-- new conversion-unit's name/code appended via a second, aliased join.
IF OBJECT_ID('dbo.sp_nt_GetProductRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetProductRecords;
GO
CREATE PROCEDURE [dbo].[sp_nt_GetProductRecords]
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        -- NOTE: must NOT use a bare `SELECT *` here — uom_master is joined
        -- twice (um for the purchase UOM, cuom for the conversion unit), and
        -- node-mssql silently collapses same-named duplicate columns
        -- (uom_name, uom_code, uom_class, ...) into arrays rather than erroring,
        -- which would corrupt every existing consumer expecting a plain string.
        -- pm.*/cm.*/scm.*/um.* reproduces exactly what the old bare `SELECT *`
        -- returned (same 4 tables, no cuom.* mixed in); only the two aliased
        -- cuom columns are new.
        SELECT pm.*, cm.*, scm.*, um.*,
               cuom.uom_name AS con_uom_name,
               cuom.uom_code AS con_uom_code
        FROM product_master pm
        INNER JOIN category_master cm ON pm.cat_sno = cm.cat_sno
        INNER JOIN subcategory_master scm ON scm.subcat_sno = pm.subcat_sno
        INNER JOIN uom_master um ON um.uom_sno = pm.uom_sno
        LEFT JOIN uom_master cuom ON cuom.uom_sno = pm.prod_uom_con_uom_sno
        WHERE prod_active = 'Y'
        ORDER BY prod_sno;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

-- ============================================================
-- After running, confirm:
--   SELECT prod_sno, prod_name, uom_sno, prod_uom_con_factor, prod_uom_con_uom_sno
--   FROM dbo.product_master ORDER BY prod_sno DESC;
--   sp_helptext 'sp_nt_CreateProductRecord';
--   sp_helptext 'sp_nt_GetProductRecords';
-- ============================================================
