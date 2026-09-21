-- ============================================================
-- Restore sp_nt_GetApprovedVendorsForServicePicker — dropped by
-- 71_remove_service_feature.sql on the (wrong) assumption it was
-- Service-exclusive because of its name. It is actually a generic
-- "approved vendors" query with zero Service-table dependency
-- (SELECTs only from kyc_basic_info), and CommonMasterRepo.js's
-- generic "VendorMaster" master entry points at it — real consumers
-- confirmed live in PaymentPage.tsx, VendorBillPage.tsx, and
-- VendorDrivenPRData.tsx (the unrelated Vendor-Driven Purchase
-- Requisition feature, which must not be touched by the Service
-- removal). Restored byte-identical to its pre-removal body.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetApprovedVendorsForServicePicker', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetApprovedVendorsForServicePicker;
GO
CREATE PROCEDURE dbo.sp_nt_GetApprovedVendorsForServicePicker
AS
BEGIN
    SET NOCOUNT ON;

    SELECT kyc_basic_info_sno, company_name, supp_code, email, mobile_number
    FROM dbo.kyc_basic_info
    WHERE status = 'A' AND is_active = 'Y'
    ORDER BY company_name;
END;
GO

-- After running, confirm:
--   SELECT OBJECT_ID('dbo.sp_nt_GetApprovedVendorsForServicePicker');
