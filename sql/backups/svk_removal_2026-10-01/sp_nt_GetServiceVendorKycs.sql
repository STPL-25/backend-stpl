CREATE PROCEDURE dbo.sp_nt_GetServiceVendorKycs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL, @status VARCHAR(1) = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @com_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        SET @status   = JSON_VALUE(@jsonInput, '$.status');
    END

    SELECT
        svk.service_vendor_kyc_sno, svk.service_vendor_code,
        svk.com_sno, svk.div_sno, svk.brn_sno, svk.dept_sno,
        svk.company_name, svk.contact_person, svk.email, svk.mobile_number, svk.business_type,
        svk.is_gst_avail, svk.gst_no, svk.is_msme_avail, svk.msme_no, svk.pan_no, svk.supplier_cat_code,
        svk.legal_name, svk.trade_name, svk.gst_status, svk.gst_blk_status, svk.date_of_reg,
        svk.taluk, svk.city, svk.state, svk.state_code,
        svk.ac_holder_name, svk.ac_number, svk.ac_type, svk.ifsc, svk.bank_name, svk.bank_branch_name,
        svk.bank_address, svk.preferred_payment_mode,
        svk.document, svk.remarks, svk.workflow_types_id, svk.current_approver_id, svk.status,
        svk.kyc_basic_info_sno, svk.created_by, svk.created_at
    FROM dbo.service_vendor_kyc svk
    WHERE svk.is_active = 'Y'
      AND (@com_sno IS NULL OR svk.com_sno = @com_sno)
      AND (@div_sno IS NULL OR svk.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR svk.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR svk.dept_sno = @dept_sno)
      AND (@status IS NULL OR svk.status = @status)
    ORDER BY svk.service_vendor_kyc_sno DESC;
END;