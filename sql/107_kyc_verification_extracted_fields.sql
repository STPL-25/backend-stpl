-- Key facts pulled out of each stored verification response so they can be
-- reported on without parsing response_json. IFSC lookups are stored with
-- verify_type = 'IFSC' (Cashfree replaces the old Razorpay IFSC lookup).
IF COL_LENGTH('dbo.kyc_verification_response', 'pan_status') IS NULL
  ALTER TABLE dbo.kyc_verification_response ADD
    pan_status                    NVARCHAR(20)  NULL,
    gst_status                    NVARCHAR(30)  NULL,
    gst_taxpayer_type             NVARCHAR(50)  NULL,
    gst_last_update_date          NVARCHAR(20)  NULL,
    nature_of_business_activities NVARCHAR(MAX) NULL,   -- JSON array
    msme_type                     NVARCHAR(30)  NULL,
    major_activity                NVARCHAR(100) NULL,
    udyam_registered_date         NVARCHAR(20)  NULL;
GO
-- verify_type was VARCHAR(10); 'IFSC' fits, nothing to widen.
-- Backfill rows stored before this migration from their JSON.
UPDATE dbo.kyc_verification_response SET
  pan_status = CASE WHEN ISJSON(response_json)=1 THEN CASE JSON_VALUE(response_json,'$.valid') WHEN 'true' THEN 'ACTIVE' ELSE 'INACTIVE' END END
WHERE verify_type = 'PAN' AND pan_status IS NULL;
UPDATE dbo.kyc_verification_response SET
  gst_status = JSON_VALUE(response_json,'$.gst_in_status'),
  gst_taxpayer_type = JSON_VALUE(response_json,'$.taxpayer_type'),
  gst_last_update_date = JSON_VALUE(response_json,'$.last_update_date'),
  nature_of_business_activities = JSON_QUERY(response_json,'$.nature_of_business_activities')
WHERE verify_type = 'GSTIN' AND ISJSON(response_json)=1 AND gst_status IS NULL;
UPDATE dbo.kyc_verification_response SET
  msme_type = JSON_VALUE(response_json,'$.enterprise_type'),
  major_activity = JSON_VALUE(response_json,'$.major_activity'),
  udyam_registered_date = JSON_VALUE(response_json,'$.date_of_udyam_registration')
WHERE verify_type = 'UDYAM' AND ISJSON(response_json)=1 AND msme_type IS NULL;
GO
