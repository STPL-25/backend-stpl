-- 111: store PAN status and MSME type (Micro / Small / Medium) on kyc_basic_info.
-- Values come from the server-side Cashfree lookups (kyc_verification_response),
-- copied at KYC creation by KycVerification.repository.linkToKyc. Re-runnable.
IF COL_LENGTH('dbo.kyc_basic_info','pan_status') IS NULL ALTER TABLE dbo.kyc_basic_info ADD pan_status VARCHAR(20) NULL;
IF COL_LENGTH('dbo.kyc_basic_info','msme_type')  IS NULL ALTER TABLE dbo.kyc_basic_info ADD msme_type  VARCHAR(20) NULL;
GO
-- Backfill existing KYCs from their latest linked verification
UPDATE k SET
    pan_status = ISNULL(k.pan_status, (SELECT TOP 1 r.pan_status FROM dbo.kyc_verification_response r
                  WHERE r.kyc_basic_info_sno = k.kyc_basic_info_sno AND r.verify_type = 'PAN' AND r.pan_status IS NOT NULL ORDER BY r.id DESC)),
    msme_type  = ISNULL(k.msme_type, (SELECT TOP 1 r.msme_type FROM dbo.kyc_verification_response r
                  WHERE r.kyc_basic_info_sno = k.kyc_basic_info_sno AND r.verify_type = 'UDYAM' AND r.msme_type IS NOT NULL ORDER BY r.id DESC))
FROM dbo.kyc_basic_info k;
GO
EXEC sp_refreshview 'dbo.vw_get_all_kyc_info';
GO
