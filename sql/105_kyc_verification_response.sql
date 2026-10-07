-- Stores every Cashfree PAN / GSTIN / Udyam / bank-account verification
-- response, then links it to the KYC created from those identifiers.
IF OBJECT_ID('dbo.kyc_verification_response') IS NULL
BEGIN
    CREATE TABLE dbo.kyc_verification_response (
        id                 INT IDENTITY(1,1) PRIMARY KEY,
        verify_type        VARCHAR(10)   NOT NULL,          -- PAN | GSTIN | UDYAM | BANK
        identifier         NVARCHAR(60)  NOT NULL,          -- pan / gstin / udyam no / account no
        reference_id       NVARCHAR(50)  NULL,              -- Cashfree reference_id
        is_valid           BIT           NOT NULL DEFAULT 0,
        response_json      NVARCHAR(MAX) NOT NULL,
        certificate_url    NVARCHAR(500) NULL,              -- MSME certificate copied to FTP
        kyc_basic_info_sno INT           NULL,
        created_at         DATETIME      NOT NULL DEFAULT GETDATE()
    );
    CREATE INDEX IX_kyc_verif_lookup ON dbo.kyc_verification_response (verify_type, identifier);
    CREATE INDEX IX_kyc_verif_kyc    ON dbo.kyc_verification_response (kyc_basic_info_sno);
END
GO
