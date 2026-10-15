-- Latest stored successful Cashfree lookup (is_valid = 1) for an identifier,
-- so the API can skip a paid call when the answer is already on file.
CREATE OR ALTER PROCEDURE dbo.sp_kyc_verification_find_valid
    @verify_type VARCHAR(10),
    @identifier  NVARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 response_json, certificate_url, gst_status
      FROM dbo.kyc_verification_response
     WHERE verify_type = @verify_type AND identifier = @identifier AND is_valid = 1
     ORDER BY id DESC;
END
GO
