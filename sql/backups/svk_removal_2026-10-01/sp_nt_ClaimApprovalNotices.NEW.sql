CREATE   PROCEDURE dbo.sp_nt_ClaimApprovalNotices
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #pending (
        entity_type VARCHAR(40) COLLATE DATABASE_DEFAULT, entity_id INT, approver_ecno VARCHAR(50) COLLATE DATABASE_DEFAULT,
        label NVARCHAR(200) COLLATE DATABASE_DEFAULT, screen VARCHAR(60) COLLATE DATABASE_DEFAULT
    );

    INSERT INTO #pending
    SELECT 'PurchaseRequisition', pr_basic_sno, current_approver_id, N'PR ' + pr_no, 'PRApprovalScreen'
    FROM dbo.pr_basic_info WHERE status = 'P' AND current_approver_id IS NOT NULL;

    INSERT INTO #pending
    SELECT 'PurchaseOrder', po_basic_sno, current_approver_id, N'PO ' + ISNULL(po_df_no, CAST(po_basic_sno AS VARCHAR(20))), 'POApprovalScreen'
    FROM dbo.po_request_info WHERE status = 'P' AND current_approver_id IS NOT NULL;

    INSERT INTO #pending
    SELECT 'Quotation', sq_basic_sno, approver_ecno, N'Quotation ' + ISNULL(quotation_ref_no, pr_no), 'POApprovalScreen'
    FROM dbo.supplier_quotation_info WHERE status = 'P' AND approver_ecno IS NOT NULL;

    INSERT INTO #pending
    SELECT 'KYC', kyc_basic_info_sno, approver_ecno, N'KYC ' + ISNULL(company_name, ''), 'KYCApprovalScreen'
    FROM dbo.kyc_basic_info WHERE status = 'P' AND approver_ecno IS NOT NULL;

    INSERT INTO #pending
    SELECT 'ServiceAgreement', agreement_sno, current_approver_id, N'Service Agreement ' + agreement_no, 'ServiceAgreementApprovalScreen'
    FROM dbo.service_agreement WHERE status = 'P' AND current_approver_id IS NOT NULL;

    INSERT INTO #pending
    SELECT 'ServicePO', c.cycle_sno, c.current_approver_id, N'Service PO ' + c.pr_no + N' (' + sa.agreement_no + N')', 'ServicePoApprovalScreen'
    FROM dbo.service_po_cycle c JOIN dbo.service_agreement sa ON sa.agreement_sno = c.agreement_sno
    WHERE c.status = 'PENDING_APPROVAL' AND c.current_approver_id IS NOT NULL;

    INSERT INTO #pending
    SELECT 'BankPaymentVoucher', voucher_sno, current_approver_id, N'Loan Voucher ' + ISNULL(voucher_no, ''), 'LoanVoucherApprovalScreen'
    FROM dbo.bank_payment_voucher WHERE status = 'PENDING' AND current_approver_id IS NOT NULL;

    CREATE TABLE #claimed (notice_sno INT PRIMARY KEY);

    UPDATE l SET status = 'PENDING', error_message = NULL, modified_at = GETDATE()
    OUTPUT inserted.notice_sno INTO #claimed (notice_sno)
    FROM dbo.approval_notice_log l
    JOIN #pending p ON p.entity_type = l.entity_type AND p.entity_id = l.entity_id AND p.approver_ecno = l.approver_ecno
    WHERE l.status = 'FAILED';

    BEGIN TRY
        INSERT INTO dbo.approval_notice_log (entity_type, entity_id, approver_ecno, status)
        OUTPUT inserted.notice_sno INTO #claimed (notice_sno)
        SELECT p.entity_type, p.entity_id, p.approver_ecno, 'PENDING'
        FROM #pending p
        WHERE NOT EXISTS (SELECT 1 FROM dbo.approval_notice_log l
                          WHERE l.entity_type = p.entity_type AND l.entity_id = p.entity_id AND l.approver_ecno = p.approver_ecno);
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (2601, 2627) THROW;   -- a concurrent sweep owns those rows
    END CATCH

    SELECT l.notice_sno, l.entity_type, l.entity_id, l.approver_ecno AS recipient_ecno, p.label, p.screen
    FROM #claimed c
    JOIN dbo.approval_notice_log l ON l.notice_sno = c.notice_sno
    JOIN #pending p ON p.entity_type = l.entity_type AND p.entity_id = l.entity_id AND p.approver_ecno = l.approver_ecno
    ORDER BY l.notice_sno;
END;