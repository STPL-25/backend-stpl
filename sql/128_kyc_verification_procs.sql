-- All KycVerification repository queries as stored procedures.
CREATE OR ALTER PROCEDURE dbo.sp_kyc_verification_save
    @verify_type VARCHAR(10), @identifier NVARCHAR(60), @reference_id NVARCHAR(50) = NULL,
    @is_valid BIT, @response_json NVARCHAR(MAX), @certificate_url NVARCHAR(500) = NULL,
    @pan_status NVARCHAR(20) = NULL, @gst_status NVARCHAR(30) = NULL, @gst_taxpayer_type NVARCHAR(50) = NULL,
    @gst_last_update_date NVARCHAR(20) = NULL, @nature_of_business_activities NVARCHAR(MAX) = NULL,
    @msme_type NVARCHAR(30) = NULL, @major_activity NVARCHAR(100) = NULL, @udyam_registered_date NVARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.kyc_verification_response
        (verify_type, identifier, reference_id, is_valid, response_json, certificate_url,
         pan_status, gst_status, gst_taxpayer_type, gst_last_update_date, nature_of_business_activities,
         msme_type, major_activity, udyam_registered_date)
    VALUES (@verify_type, @identifier, @reference_id, @is_valid, @response_json, @certificate_url,
         @pan_status, @gst_status, @gst_taxpayer_type, @gst_last_update_date, @nature_of_business_activities,
         @msme_type, @major_activity, @udyam_registered_date);
END
GO
CREATE OR ALTER PROCEDURE dbo.sp_kyc_verification_link_to_kyc
    @sno INT, @verify_type VARCHAR(10), @identifier NVARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.kyc_verification_response
       SET kyc_basic_info_sno = @sno
     WHERE kyc_basic_info_sno IS NULL AND verify_type = @verify_type AND identifier = @identifier;
END
GO
CREATE OR ALTER PROCEDURE dbo.sp_kyc_verification_sync_basic_info
    @sno INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE k SET
        pan_status = ISNULL((SELECT TOP 1 r.pan_status FROM dbo.kyc_verification_response r
                      WHERE r.kyc_basic_info_sno = k.kyc_basic_info_sno AND r.verify_type = 'PAN' AND r.pan_status IS NOT NULL ORDER BY r.id DESC), k.pan_status),
        msme_type  = ISNULL((SELECT TOP 1 r.msme_type FROM dbo.kyc_verification_response r
                      WHERE r.kyc_basic_info_sno = k.kyc_basic_info_sno AND r.verify_type = 'UDYAM' AND r.msme_type IS NOT NULL ORDER BY r.id DESC), k.msme_type)
    FROM dbo.kyc_basic_info k WHERE k.kyc_basic_info_sno = @sno;
END
GO
-- Live (approved or pending) KYCs only; @column is whitelisted to gst_no / pan_no.
CREATE OR ALTER PROCEDURE dbo.sp_kyc_verification_find_live_kyc
    @column VARCHAR(10), @value VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    IF @column NOT IN ('gst_no', 'pan_no') THROW 50000, 'Invalid column', 1;
    SELECT TOP 1 kyc_basic_info_sno, status FROM dbo.kyc_basic_info
     WHERE is_active = 'Y' AND status IN ('A', 'P')
       AND ((@column = 'gst_no' AND gst_no = @value) OR (@column = 'pan_no' AND pan_no = @value))
     ORDER BY kyc_basic_info_sno DESC;
END
GO
CREATE OR ALTER PROCEDURE dbo.sp_kyc_verification_latest_certificate_url
    @identifier NVARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 certificate_url FROM dbo.kyc_verification_response
     WHERE verify_type = 'UDYAM' AND identifier = @identifier AND certificate_url IS NOT NULL
     ORDER BY id DESC;
END
GO
CREATE OR ALTER PROCEDURE dbo.sp_kyc_verification_get_by_kyc
    @sno INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT verify_type, identifier, reference_id, is_valid, response_json, certificate_url, created_at,
           pan_status, gst_status, gst_taxpayer_type, gst_last_update_date, nature_of_business_activities,
           msme_type, major_activity, udyam_registered_date
      FROM dbo.kyc_verification_response WHERE kyc_basic_info_sno = @sno ORDER BY id;
END
GO
