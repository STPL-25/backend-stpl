CREATE PROCEDURE dbo.sp_nt_GetApprovedServiceVendorKycs
AS
BEGIN
    SET NOCOUNT ON;

    SELECT service_vendor_kyc_sno, service_vendor_code, company_name, contact_person,
           email, mobile_number, kyc_basic_info_sno
    FROM dbo.service_vendor_kyc
    WHERE status = 'A' AND is_active = 'Y'
    ORDER BY company_name;
END;