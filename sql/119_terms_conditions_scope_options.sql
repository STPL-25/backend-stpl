-- ============================================================
-- Terms & Conditions — list every active entry for an exact scope
-- Database: Non_trade_Dev (MSSQL)
--
-- PO creation used to receive only the single is_default='Y' entry
-- (sp_nt_GetDefaultTermsConditions). The buyer can now also pick any other
-- active entry configured for the same Company/Division/Branch/Department,
-- so this returns all of them, default first.
-- @jsonInput: {"com_sno":1, "div_sno":2, "brn_sno":3, "dept_sno":4}
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetTermsConditionsForScope
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno  INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno')  AS INT),
            @div_sno  INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno')  AS INT),
            @brn_sno  INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno')  AS INT),
            @dept_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);

    SELECT tc_sno, tc_title, tc_text, is_default
    FROM dbo.terms_conditions_master
    WHERE com_sno = @com_sno AND div_sno = @div_sno AND brn_sno = @brn_sno AND dept_sno = @dept_sno
      AND is_active = 'Y'
    ORDER BY CASE WHEN is_default = 'Y' THEN 0 ELSE 1 END, tc_title;
END;
GO
