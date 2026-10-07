CREATE PROCEDURE dbo.sp_nt_SaveServiceAgreementSuppliers
    @agreement_sno INT,
    @vendors_json NVARCHAR(MAX),
    @fallback_vendor_sno INT,
    @total_amount DECIMAL(18,2),
    @out_primary_vendor_sno INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @parsed TABLE (ord INT NOT NULL, vendor_sno INT NULL, share_amount DECIMAL(18,2) NULL);

    IF @vendors_json IS NOT NULL AND ISJSON(@vendors_json) = 1 AND LEFT(LTRIM(@vendors_json), 1) = '['
        INSERT INTO @parsed (ord, vendor_sno, share_amount)
        SELECT CAST(j.[key] AS INT) + 1,
               TRY_CAST(JSON_VALUE(j.[value], '$.vendor_sno') AS INT),
               TRY_CAST(JSON_VALUE(j.[value], '$.share_amount') AS DECIMAL(18,2))
        FROM OPENJSON(@vendors_json) AS j;

    IF NOT EXISTS (SELECT 1 FROM @parsed) AND @fallback_vendor_sno IS NOT NULL
        INSERT INTO @parsed (ord, vendor_sno, share_amount) VALUES (1, @fallback_vendor_sno, @total_amount);

    IF NOT EXISTS (SELECT 1 FROM @parsed)
        THROW 58150, 'At least one supplier is required.', 1;
    IF EXISTS (SELECT 1 FROM @parsed WHERE vendor_sno IS NULL OR share_amount IS NULL OR share_amount <= 0)
        THROW 58151, 'Every supplier needs a vendor and a share amount greater than zero.', 1;
    IF EXISTS (SELECT vendor_sno FROM @parsed GROUP BY vendor_sno HAVING COUNT(*) > 1)
        THROW 58152, 'The same supplier is listed more than once in the split.', 1;
    IF EXISTS (
        SELECT 1 FROM @parsed p
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.kyc_basic_info k
            WHERE k.kyc_basic_info_sno = p.vendor_sno AND k.status = 'A' AND k.is_active = 'Y'
              AND k.vendor_category = 'SERVICE'
        )
    )
        THROW 58153, 'One or more suppliers are not approved Service Vendor KYC vendors.', 1;

    DECLARE @sum DECIMAL(18,2) = (SELECT SUM(share_amount) FROM @parsed);
    IF ABS(@sum - @total_amount) > 0.01
    BEGIN
        DECLARE @msg NVARCHAR(400) =
            N'Supplier shares total ' + CONVERT(NVARCHAR(30), @sum) +
            N' but the amount per cycle (rate x quantity) is ' + CONVERT(NVARCHAR(30), @total_amount) +
            N'. The shares must add up exactly.';
        THROW 58154, @msg, 1;
    END

    DELETE FROM dbo.service_agreement_vendor WHERE agreement_sno = @agreement_sno;

    INSERT INTO dbo.service_agreement_vendor (agreement_sno, vendor_sno, share_amount, share_pct, sort_order)
    SELECT @agreement_sno, vendor_sno, share_amount, ROUND(share_amount * 100.0 / @total_amount, 6), ord
    FROM @parsed
    ORDER BY ord;

    SELECT TOP 1 @out_primary_vendor_sno = vendor_sno FROM @parsed ORDER BY ord;
END;