-- ============================================================
-- Product-specific UOM conversion factor — product_master.prod_uom_con_factor
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/Masters (ProductMaster create, sp_nt_CreateProductRecord)
--
-- Why this is needed
-- ------------------
-- uom_master already models unit conversion via uom_base_uom_flag +
-- uom_con_factor (e.g. Nos is the base unit with base_uom_flag='Y'; Dozen is
-- a derived unit with base_uom_flag='N' and a FIXED uom_con_factor=12 that is
-- the same for every product). That works for units whose ratio to the base
-- unit never changes.
--
-- It does not work for packaging units like Box, where the piece count
-- varies per product (a box of Apsara pencils and a box of erasers do not
-- hold the same number of pieces). For those, uom_master.uom_con_factor is
-- deliberately left NULL (see frontend: uom_con_factor is no longer a
-- required field on UomMaster create), and the actual count is captured once
-- per product instead, on product_master.
--
-- Convention: for a product whose selected uom_sno is a non-base unit
-- (uom_base_uom_flag='N') AND that unit's own uom_con_factor IS NULL, the
-- product row MUST carry its own prod_uom_con_factor (pieces per 1 unit of
-- the product's uom, e.g. "1 Box = 10 pieces" for Apsara Pencil). If the
-- selected unit already has a fixed uom_con_factor (e.g. Dozen), or is the
-- base unit itself, prod_uom_con_factor stays NULL and the global factor is
-- used as-is — no per-product entry needed.
--
-- sp_nt_GetProductRecords is untouched: it already does `SELECT *` across
-- product_master/category_master/subcategory_master/uom_master, so the new
-- column is picked up automatically. Only sp_nt_CreateProductRecord (which
-- lists columns explicitly via OPENJSON) needs to change.
-- ============================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.product_master') AND name = 'prod_uom_con_factor'
)
BEGIN
    ALTER TABLE dbo.product_master ADD prod_uom_con_factor DECIMAL(18,6) NULL;
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.check_constraints WHERE name = 'CK_product_master_prod_uom_con_factor'
)
BEGIN
    ALTER TABLE dbo.product_master ADD CONSTRAINT CK_product_master_prod_uom_con_factor
        CHECK (prod_uom_con_factor IS NULL OR prod_uom_con_factor > 0);
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
            row_index           INT,
            company_sno         INT,
            division_sno        INT,
            branch_sno          INT,
            dept_sno            INT,
            cat_sno             INT,
            subcat_sno          INT,
            prod_name           VARCHAR(255),
            prod_description    VARCHAR(MAX),
            prod_notes          VARCHAR(MAX),
            hsn_code            VARCHAR(50),
            uom_sno             INT,
            tax_sno             INT,
            prod_uom_con_factor DECIMAL(18,6),
            created_by          VARCHAR(50)
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
            created_by
        FROM OPENJSON(@normalizedJson)
        WITH (
            company_sno         INT             '$.company_sno',
            division_sno        INT             '$.division_sno',
            branch_sno           INT            '$.branch_sno',
            dept_sno             INT            '$.dept_sno',
            cat_sno              INT            '$.cat_sno',
            subcat_sno           INT            '$.subcat_sno',
            prod_name            VARCHAR(255)   '$.prod_name',
            prod_description     VARCHAR(MAX)   '$.prod_description',
            prod_notes           VARCHAR(MAX)   '$.prod_notes',
            hsn_code             VARCHAR(50)    '$.hsn_code',
            uom_sno              INT            '$.uom_sno',
            tax_sno              INT            '$.tax_sno',
            prod_uom_con_factor  DECIMAL(18,6)  '$.prod_uom_con_factor',
            created_by           VARCHAR(50)    '$.created_by'
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
        -- 5b. Validate product-specific UOM conversion factor
        --     A non-base UOM with no fixed uom_master.uom_con_factor (e.g.
        --     Box) varies per product, so prod_uom_con_factor must be
        --     supplied. A non-base UOM that already has a fixed factor (e.g.
        --     Dozen), or the base unit itself, needs no per-product entry.
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

        -- ───────────────────────────────────────────
        -- 6. Generate Product Codes — set-based per category
        --    MAX existing seq fetched once per category (with lock)
        --    ROW_NUMBER() per cat assigns each new row its offset
        -- ───────────────────────────────────────────
        CREATE TABLE #products_with_code (
            row_index           INT,
            company_sno         INT,
            division_sno        INT,
            branch_sno          INT,
            dept_sno            INT,
            cat_sno             INT,
            subcat_sno          INT,
            prod_name           VARCHAR(255),
            prod_description    VARCHAR(MAX),
            prod_notes          VARCHAR(MAX),
            prod_code           VARCHAR(50),
            hsn_code            VARCHAR(50),
            uom_sno             INT,
            tax_sno             INT,
            prod_uom_con_factor DECIMAL(18,6),
            created_by          VARCHAR(50)
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

-- ============================================================
-- After running, confirm:
--   SELECT prod_sno, prod_name, uom_sno, prod_uom_con_factor FROM dbo.product_master ORDER BY prod_sno DESC;
--   SELECT name, definition FROM sys.check_constraints WHERE name = 'CK_product_master_prod_uom_con_factor';
--   sp_helptext 'sp_nt_CreateProductRecord';
-- ============================================================
