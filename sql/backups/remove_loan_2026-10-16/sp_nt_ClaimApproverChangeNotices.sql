-- Claims reassignment notices that still have to be delivered (PENDING / FAILED) and returns them with
-- display names and the screen the NEW approver's bell should open.
CREATE   PROCEDURE dbo.sp_nt_ClaimApproverChangeNotices
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @claimed TABLE (notice_sno INT PRIMARY KEY);

    UPDATE dbo.approver_reassignment_log
    SET status = 'CLAIMED', modified_at = GETDATE()
    OUTPUT inserted.notice_sno INTO @claimed
    WHERE status IN ('PENDING', 'FAILED');

    SELECT l.notice_sno, l.entity_type, l.entity_id, l.label, l.recipient_ecno, l.recipient_role,
           l.old_ecno, l.new_ecno,
           COALESCE(oe.ename, ons.full_name, l.old_ecno) AS old_name,
           COALESCE(ne.ename, nns.full_name, l.new_ecno) AS new_name,
           CASE l.entity_type
                WHEN 'PurchaseRequisition' THEN 'PRApprovalScreen'
                WHEN 'PurchaseOrder'       THEN 'POApprovalScreen'
                WHEN 'Quotation'           THEN 'POApprovalScreen'
                WHEN 'KYC'                 THEN 'KYCApprovalScreen'
                WHEN 'ServiceAgreement'    THEN 'ServiceAgreementApprovalScreen'
                WHEN 'ServicePO'           THEN 'ServicePoApprovalScreen'
                WHEN 'BankPaymentVoucher'  THEN 'LoanVoucherApprovalScreen'
           END AS screen
    FROM @claimed c
    JOIN dbo.approver_reassignment_log l ON l.notice_sno = c.notice_sno
    LEFT JOIN dbo.vw_verified_employees oe ON oe.ecno = l.old_ecno
    LEFT JOIN dbo.nt_nonstaff_login ons ON ons.login_id = l.old_ecno
    LEFT JOIN dbo.vw_verified_employees ne ON ne.ecno = l.new_ecno
    LEFT JOIN dbo.nt_nonstaff_login nns ON nns.login_id = l.new_ecno
    ORDER BY l.notice_sno;
END;