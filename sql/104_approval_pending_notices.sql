-- ============================================================
-- 104: "Waiting for your approval" bell notifications for every approval type
-- Database: Non_trade_Dev (MSSQL). Re-runnable.
--
-- sp_nt_ClaimApprovalNotices finds every item currently pending with a named approver
-- (PR, PO, quotation, KYC, Service Agreement, Service PO cycle, Service Vendor KYC, Bank
-- Payment Voucher) that the approver has not been told about yet, claims it in
-- approval_notice_log (unique per entity + approver, so each approver is told once per
-- item — and again if it later reaches a different approver), and returns it with the
-- screen component the notification should open. A FAILED claim is retried next sweep.
-- ============================================================

IF OBJECT_ID('dbo.approval_notice_log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.approval_notice_log (
        notice_sno    INT IDENTITY(1,1) PRIMARY KEY,
        entity_type   VARCHAR(40)  NOT NULL,
        entity_id     INT          NOT NULL,
        approver_ecno VARCHAR(50)  NOT NULL,
        status        VARCHAR(10)  NOT NULL DEFAULT 'PENDING',   -- PENDING | SENT | FAILED
        error_message NVARCHAR(500) NULL,
        created_at    DATETIME     NOT NULL DEFAULT GETDATE(),
        modified_at   DATETIME     NULL,
        CONSTRAINT CK_approval_notice_status CHECK (status IN ('PENDING','SENT','FAILED')),
        CONSTRAINT UQ_approval_notice UNIQUE (entity_type, entity_id, approver_ecno)
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_ClaimApprovalNotices
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
    SELECT 'ServiceVendorKYC', service_vendor_kyc_sno, current_approver_id, N'Service Vendor KYC ' + ISNULL(company_name, ''), 'ServiceVendorKycApprovalScreen'
    FROM dbo.service_vendor_kyc WHERE status = 'P' AND current_approver_id IS NOT NULL;

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
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_MarkApprovalNoticeSent
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.approval_notice_log
    SET status = CASE WHEN JSON_VALUE(@jsonInput, '$.status') = 'SENT' THEN 'SENT' ELSE 'FAILED' END,
        error_message = LEFT(JSON_VALUE(@jsonInput, '$.error_message'), 500),
        modified_at = GETDATE()
    WHERE notice_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.notice_sno') AS INT);
END;
GO
