-- ============================================================
-- PO Terms & Conditions: resolve by Company/Division/Branch/Department scope.
-- 1) fn_nt_DefaultTermsText: default entry, else the oldest active entry of the
--    scope (a scope with T&C but none flagged default used to get nothing).
-- 2) sp_nt_GetDefaultTermsConditions (PO dialog prefill): same fallback.
-- 3) sp_nt_CreatePOFromQuotation: blank terms -> scope text server-side.
-- Database: Non_trade_Dev. Originals: sql/backups/po_terms_fallback_2026-10-03/
-- ============================================================
CREATE OR ALTER FUNCTION dbo.fn_nt_DefaultTermsText (@com INT, @div INT, @brn INT, @dept INT)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    RETURN (
        SELECT TOP 1 tc_text
        FROM dbo.terms_conditions_master
        WHERE com_sno = @com AND div_sno = @div AND brn_sno = @brn AND dept_sno = @dept
          AND is_active = 'Y'
        ORDER BY CASE WHEN is_default = 'Y' THEN 0 ELSE 1 END, tc_sno
    );
END;
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetDefaultTermsConditions
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno  INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno')  AS INT),
            @div_sno  INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno')  AS INT),
            @brn_sno  INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno')  AS INT),
            @dept_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);

    SELECT TOP 1 tc_sno, tc_title, tc_text
    FROM dbo.terms_conditions_master
    WHERE com_sno = @com_sno AND div_sno = @div_sno AND brn_sno = @brn_sno AND dept_sno = @dept_sno
      AND is_active = 'Y'
    ORDER BY CASE WHEN is_default = 'Y' THEN 0 ELSE 1 END, tc_sno;
END;
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreatePOFromQuotation
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @pr_basic_sno       INT            = CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT);
        DECLARE @vendor_sno         INT            = CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @com_sno            INT            = CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno            INT            = CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno            INT            = CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno           INT            = CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @budget_sno         INT            = CAST(JSON_VALUE(@jsonInput, '$.budget_sno') AS INT);
        DECLARE @budget_code        VARCHAR(20)    = LEFT(ISNULL(JSON_VALUE(@jsonInput, '$.budget_code'), ''), 20);
        DECLARE @priority_sno       INT            = CAST(JSON_VALUE(@jsonInput, '$.priority_sno') AS INT);
        DECLARE @po_date            DATE           = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.po_date') AS DATE), CAST(GETDATE() AS DATE));
        DECLARE @required_date      DATE           = TRY_CAST(JSON_VALUE(@jsonInput, '$.required_date') AS DATE);
        DECLARE @purpose            VARCHAR(200)   = LEFT(ISNULL(JSON_VALUE(@jsonInput, '$.purpose'), ''), 200);
        DECLARE @terms_conditions   VARCHAR(MAX)   = JSON_VALUE(@jsonInput, '$.terms_conditions');
        DECLARE @delivery_address   VARCHAR(500)   = LEFT(ISNULL(JSON_VALUE(@jsonInput, '$.delivery_address'), ''), 500);
        DECLARE @split_pr_no        NVARCHAR(30)   = JSON_VALUE(@jsonInput, '$.split_pr_no');
        DECLARE @created_by         VARCHAR(20)    = JSON_VALUE(@jsonInput, '$.created_by');

        IF @pr_basic_sno IS NULL OR @vendor_sno IS NULL
            THROW 51001, 'pr_basic_sno and vendor_sno are required.', 1;

        DECLARE @pr_no VARCHAR(30);
        SELECT @pr_no = pr_no FROM pr_basic_info WHERE pr_basic_sno = @pr_basic_sno;
        IF @pr_no IS NULL
            THROW 51002, 'pr_no not found in pr_basic_info for given pr_basic_sno.', 1;

        IF @split_pr_no IS NULL SET @split_pr_no = @pr_no;

        -- No terms supplied (or blank) -> fall back to the scope's T&C master text.
        IF NULLIF(LTRIM(RTRIM(@terms_conditions)), '') IS NULL
            SET @terms_conditions = dbo.fn_nt_DefaultTermsText(@com_sno, @div_sno, @brn_sno, @dept_sno);

        IF NOT EXISTS (SELECT 1 FROM OPENJSON(@jsonInput, '$.items'))
            THROW 51003, 'No items found in JSON.', 1;

        INSERT INTO po_request_info (
            vendor_sno, brn_sno, dept_sno, com_sno, div_sno,
            budget_sno, budget_code, pr_basic_sno,
            po_date, required_date,
            priority_sno, purpose, terms_conditions, delivery_address,
            is_active, workflow_types_id, current_approver_id,
            status, po_df_no, split_pr_no
        )
        VALUES (
            @vendor_sno, @brn_sno, @dept_sno, @com_sno, @div_sno,
            @budget_sno, @budget_code, @pr_basic_sno,
            @po_date, @required_date,
            @priority_sno, @purpose, @terms_conditions, @delivery_address,
            'Y', 0, '0',
            'A', NULL, @split_pr_no
        );

        DECLARE @po_basic_sno INT = SCOPE_IDENTITY();
        DECLARE @po_no VARCHAR(30) = 'PO-' + CAST(YEAR(@po_date) AS VARCHAR(4)) + '-' + RIGHT('0000' + CAST(@po_basic_sno AS VARCHAR(10)), 4);

        UPDATE po_request_info SET po_df_no = @po_no WHERE po_basic_sno = @po_basic_sno;

        INSERT INTO po_item_details (
            po_basic_sno, pr_item_sno, prod_sno, prod_name,
            budget_sno, specification,
            qty, unit, unit_name,
            agreed_unit_price, total_cost,
            discount_pct, tax_pct, net_cost,
            remarks,
            created_by, created_date,
            is_active, split_pr_no
        )
        SELECT
            @po_basic_sno,
            TRY_CAST(JSON_VALUE(item.value, '$.pr_item_sno') AS INT),
            TRY_CAST(JSON_VALUE(item.value, '$.prod_sno') AS INT),
            LEFT(JSON_VALUE(item.value, '$.prod_name'), 200),
            @budget_sno,
            LEFT(ISNULL(JSON_VALUE(item.value, '$.specification'), ''), 200),
            TRY_CAST(JSON_VALUE(item.value, '$.qty') AS DECIMAL(18,4)),
            TRY_CAST(JSON_VALUE(item.value, '$.unit') AS INT),
            LEFT(JSON_VALUE(item.value, '$.unit_name'), 200),
            TRY_CAST(JSON_VALUE(item.value, '$.unit_price') AS DECIMAL(18,4)),
            ISNULL(TRY_CAST(JSON_VALUE(item.value, '$.qty') AS DECIMAL(18,4)), 0)
                * ISNULL(TRY_CAST(JSON_VALUE(item.value, '$.unit_price') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(JSON_VALUE(item.value, '$.discount_pct') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(JSON_VALUE(item.value, '$.tax_pct') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(JSON_VALUE(item.value, '$.total_amount') AS DECIMAL(18,4)),
                   ISNULL(TRY_CAST(JSON_VALUE(item.value, '$.qty') AS DECIMAL(18,4)), 0)
                       * ISNULL(TRY_CAST(JSON_VALUE(item.value, '$.unit_price') AS DECIMAL(18,4)), 0)),
            LEFT(ISNULL(JSON_VALUE(item.value, '$.remarks'), ''), 200),
            @created_by, GETDATE(),
            'Y', @split_pr_no
        FROM OPENJSON(@jsonInput, '$.items') AS item;

        COMMIT TRANSACTION;

        SELECT
            @po_basic_sno AS po_basic_sno,
            @po_no        AS po_no,
            @pr_no        AS pr_no,
            @vendor_sno   AS vendor_sno,
            'SUCCESS'     AS result;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        SELECT
            ERROR_NUMBER()  AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage,
            ERROR_LINE()    AS ErrorLine,
            'FAILED'        AS result;
    END CATCH
END
GO
GO
