-- ============================================================
-- Stored Procedure : sp_fetch_vendor_datas
-- Database         : Non_Trade (MSSQL)
-- Returns          : All supplier / vendor KYC records as JSON
--
-- Optional @jsonInput filter keys:
--   status     VARCHAR  'approved' | 'rejected' | 'pending' | 'all'  (default 'all')
--   is_active  CHAR(1)  'Y' | 'N' | 'all'                            (default 'Y')
--   search     VARCHAR  partial match on company_name or vendor_code
-- ============================================================

IF OBJECT_ID('dbo.sp_fetch_vendor_datas', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_fetch_vendor_datas;
GO

CREATE PROCEDURE dbo.sp_fetch_vendor_datas
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- ── Parse optional filter parameters ────────────────────
    DECLARE @status     VARCHAR(20) = 'all';
    DECLARE @is_active  CHAR(1)     = 'Y';
    DECLARE @search     NVARCHAR(200) = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        IF JSON_VALUE(@jsonInput, '$.status')    IS NOT NULL
            SET @status    = JSON_VALUE(@jsonInput, '$.status');

        IF JSON_VALUE(@jsonInput, '$.is_active') IS NOT NULL
            SET @is_active = JSON_VALUE(@jsonInput, '$.is_active');

        IF JSON_VALUE(@jsonInput, '$.search')    IS NOT NULL
            SET @search    = JSON_VALUE(@jsonInput, '$.search');
    END

    -- ── Build result set ────────────────────────────────────
    SELECT
        k.kyc_basic_info_sno,
        k.vendor_code,
        k.company_name,
        k.contact_person,
        k.mobile_no,
        k.email,
        k.address,
        k.city,
        k.state,
        k.pincode,
        k.country,

        -- GST details
        k.is_gst_avail,
        k.gst_no,

        -- MSME details
        k.is_msme_avail,
        k.msme_no,

        -- PAN
        k.pan_no,

        -- Bank details
        k.bank_name,
        k.account_no,
        k.ifsc_code,
        k.account_type,

        -- Documents (stored as JSON string)
        ISNULL(k.document, '[]') AS document,

        -- Status & audit
        k.kyc_status,
        k.is_active,
        k.created_by,
        CONVERT(VARCHAR(30), k.created_at, 120)  AS created_at,
        k.approved_by,
        CONVERT(VARCHAR(30), k.approved_at, 120) AS approved_at,
        k.remarks

    FROM kyc_basic_info k
    WHERE
        -- status filter
        (
            @status = 'all'
            OR k.kyc_status = @status
        )
        -- is_active filter
        AND (
            @is_active = 'all'
            OR k.is_active = @is_active
        )
        -- search filter
        AND (
            @search IS NULL
            OR k.company_name LIKE '%' + @search + '%'
            OR k.vendor_code  LIKE '%' + @search + '%'
        )
    ORDER BY k.kyc_basic_info_sno DESC

    FOR JSON PATH, ROOT('vendors');
END;
GO
