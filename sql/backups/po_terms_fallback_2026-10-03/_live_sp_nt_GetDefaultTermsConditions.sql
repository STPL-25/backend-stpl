CREATE PROCEDURE dbo.sp_nt_GetDefaultTermsConditions
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
      AND is_default = 'Y' AND is_active = 'Y';
END;