CREATE PROCEDURE dbo.sp_nt_GetServiceVendorKycsForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

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
        (
            SELECT ws.stage_order_json
            FROM dbo.workflow_stage ws
            WHERE ws.workflow_types_id = svk.workflow_types_id AND ws.is_active = 'Y'
        ) AS stage_order_json
    FROM dbo.service_vendor_kyc svk
    WHERE svk.current_approver_id = @Ecno
      AND svk.status = 'P'
      AND svk.is_active = 'Y'
    ORDER BY svk.service_vendor_kyc_sno DESC;
END;