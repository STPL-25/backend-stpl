-- Loan Payment screen: the loan detail view only showed the principal ledger and had
-- no beneficiary bank/KYC info at all (that data was only ever pulled per-voucher, in
-- sp_nt_GetBankPaymentVoucher). This adds the vendor's active/primary bank details
-- (dbo.kyc_bank_info, same lookup pattern as sp_nt_GetBankPaymentVoucher's beneficiary_json)
-- to sp_nt_GetLoanDetail so the Loan Payment screen can show a "Bank details (KYC)" panel
-- without a second round trip. sp_nt_GetLoanDetail previously never joined
-- dbo.service_agreement at all (only checked service_agreement_statutory existed), so a
-- join to sa is added purely to reach vendor_sno.

IF OBJECT_ID('dbo.sp_nt_GetLoanDetail', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetLoanDetail;
GO
-- One loan's history as JSON columns (parsed by the Node service):
--   rates_json       sanctioned rate + every entered rate, each with its end date
--   txns_json        opening disbursement + every principal movement, with a running balance
--   vouchers_json    the loan's bank payment vouchers, newest first
--   beneficiary_json the vendor's active/primary bank account (KYC), for display only
-- @jsonInput: { agreement_sno }
CREATE PROCEDURE dbo.sp_nt_GetLoanDetail
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @agreement_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
    IF @agreement_sno IS NULL THROW 58400, 'agreement_sno is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.service_agreement_statutory WHERE agreement_sno = @agreement_sno)
        THROW 58400, 'Loan facility not found for this agreement.', 1;

    DECLARE @locked DATE = dbo.fn_LoanLockedThrough(@agreement_sno);
    DECLARE @vendor_sno INT = (SELECT sa.vendor_sno FROM dbo.service_agreement sa WHERE sa.agreement_sno = @agreement_sno);

    SELECT @agreement_sno AS agreement_sno,
           dbo.fn_LoanBilledThrough(@agreement_sno) AS billed_through,
           @locked AS locked_through,
           (
               SELECT r.rate_period_sno, r.effective_from,
                      DATEADD(DAY, -1, LEAD(r.effective_from) OVER (ORDER BY r.effective_from)) AS effective_to,
                      r.benchmark_rate_pct, r.spread_pct, r.interest_rate_pct, r.source, r.remarks, r.created_by, r.created_at,
                      CASE WHEN r.source = 'ENTERED' AND r.effective_from >= @locked THEN 1 ELSE 0 END AS can_delete
               FROM (
                   SELECT CAST(NULL AS INT) AS rate_period_sno, s.disbursement_date AS effective_from, s.benchmark_rate_pct, s.spread_pct,
                          s.interest_rate_pct, 'SANCTIONED' AS source, CAST(N'Rate at sanction' AS NVARCHAR(300)) AS remarks,
                          CAST(NULL AS VARCHAR(30)) AS created_by, CAST(NULL AS DATETIME) AS created_at
                   FROM dbo.service_agreement_statutory s WHERE s.agreement_sno = @agreement_sno
                   UNION ALL
                   SELECT p.rate_period_sno, p.effective_from, p.benchmark_rate_pct, p.spread_pct, p.interest_rate_pct, 'ENTERED',
                          p.remarks, p.created_by, p.created_at
                   FROM dbo.loan_rate_period p WHERE p.agreement_sno = @agreement_sno
               ) r
               ORDER BY r.effective_from
               FOR JSON PATH
           ) AS rates_json,
           (
               SELECT m.txn_sno, m.txn_date, m.txn_type, m.amount, m.voucher_sno, m.remarks, m.created_by, m.source,
                      SUM(CASE m.txn_type WHEN 'DRAWDOWN' THEN m.amount ELSE -m.amount END)
                          OVER (ORDER BY m.txn_date, m.ord, m.txn_sno ROWS UNBOUNDED PRECEDING) AS principal_after,
                      CASE WHEN m.source = 'MANUAL' AND m.txn_date >= @locked THEN 1 ELSE 0 END AS can_delete
               FROM (
                   SELECT CAST(NULL AS INT) AS txn_sno, s.disbursement_date AS txn_date, 'DRAWDOWN' AS txn_type, s.disbursed_amount AS amount,
                          CAST(NULL AS INT) AS voucher_sno, CAST(N'Disbursement' AS NVARCHAR(300)) AS remarks, CAST(NULL AS VARCHAR(30)) AS created_by,
                          'OPENING' AS source, 0 AS ord
                   FROM dbo.service_agreement_statutory s WHERE s.agreement_sno = @agreement_sno AND ISNULL(s.disbursed_amount, 0) > 0
                   UNION ALL
                   SELECT t.txn_sno, t.txn_date, t.txn_type, t.amount, t.voucher_sno, t.remarks, t.created_by,
                          CASE WHEN t.voucher_sno IS NULL THEN 'MANUAL' ELSE 'VOUCHER' END, 1
                   FROM dbo.loan_principal_txn t WHERE t.agreement_sno = @agreement_sno AND t.is_active = 'Y'
               ) m
               ORDER BY m.txn_date, m.ord, m.txn_sno
               FOR JSON PATH
           ) AS txns_json,
           (
               SELECT v.voucher_sno, v.voucher_no, v.period_from, v.period_to, v.days, v.interest_amount, v.principal_repayment,
                      v.total_payable, v.principal_after, v.rate_pct, v.status, v.created_at, v.paid_on
               FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = @agreement_sno
               ORDER BY v.voucher_sno DESC
               FOR JSON PATH
           ) AS vouchers_json,
           (
               SELECT TOP 1 b.ac_holder_name, b.ac_number, b.ifsc, b.bank_name, b.bank_branch_name
               FROM dbo.kyc_bank_info b
               WHERE b.kyc_basic_info_sno = @vendor_sno AND b.is_active = 'Y'
               ORDER BY CASE WHEN b.is_primary = 'Y' THEN 0 ELSE 1 END, b.kyc_address_sno
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
           ) AS beneficiary_json;
END;
GO
