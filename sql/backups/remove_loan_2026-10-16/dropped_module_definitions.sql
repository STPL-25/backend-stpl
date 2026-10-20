-- Principal outstanding ON a date (movements dated on or before it have taken effect).
CREATE FUNCTION dbo.fn_LoanPrincipalAt (@agreement_sno INT, @on DATE)
RETURNS DECIMAL(18,2)
AS
BEGIN
    RETURN
        ISNULL((SELECT CASE WHEN s.disbursement_date <= @on THEN ISNULL(s.disbursed_amount, 0) ELSE 0 END
                FROM dbo.service_agreement_statutory s WHERE s.agreement_sno = @agreement_sno), 0)
      + ISNULL((SELECT SUM(CASE t.txn_type WHEN 'DRAWDOWN' THEN t.amount ELSE -t.amount END)
                FROM dbo.loan_principal_txn t
                WHERE t.agreement_sno = @agreement_sno AND t.is_active = 'Y' AND t.txn_date <= @on), 0);
END;
GO

-- The next scheduled interest date strictly after @after. A payment day the
-- month doesn't have (31st in February) falls on the month's last day.
CREATE FUNCTION dbo.fn_LoanNextDueDate (@pay_day TINYINT, @after DATE)
RETURNS DATE
AS
BEGIN
    DECLARE @cand DATE = DATEFROMPARTS(YEAR(@after), MONTH(@after),
        CASE WHEN @pay_day > DAY(EOMONTH(@after)) THEN DAY(EOMONTH(@after)) ELSE @pay_day END);
    IF @cand <= @after
    BEGIN
        DECLARE @nm DATE = DATEADD(MONTH, 1, DATEFROMPARTS(YEAR(@after), MONTH(@after), 1));
        SET @cand = DATEFROMPARTS(YEAR(@nm), MONTH(@nm),
            CASE WHEN @pay_day > DAY(EOMONTH(@nm)) THEN DAY(EOMONTH(@nm)) ELSE @pay_day END);
    END
    RETURN @cand;
END;
GO

-- The rate in force ON a date: the latest entered rate period on or before it,
-- else the rate the loan was sanctioned at (effective from the disbursement date).
CREATE FUNCTION dbo.fn_LoanRateAt (@agreement_sno INT, @on DATE)
RETURNS TABLE
AS
RETURN
(
    SELECT TOP 1 r.effective_from, r.benchmark_rate_pct, r.spread_pct, r.interest_rate_pct
    FROM (
        SELECT p.effective_from, p.benchmark_rate_pct, p.spread_pct, p.interest_rate_pct, 1 AS src
        FROM dbo.loan_rate_period p
        WHERE p.agreement_sno = @agreement_sno AND p.effective_from <= @on
        UNION ALL
        SELECT s.disbursement_date, s.benchmark_rate_pct, s.spread_pct, s.interest_rate_pct, 0
        FROM dbo.service_agreement_statutory s
        WHERE s.agreement_sno = @agreement_sno AND s.disbursement_date <= @on
    ) r
    ORDER BY r.effective_from DESC, r.src DESC
);
GO

-- Interest for [@from, @to): one row per slice with a constant principal and a
-- constant rate. @extra_repay is a principal repayment not yet written to
-- loan_principal_txn (used to project the NEXT period after a voucher that
-- repays principal); it reduces every slice from @from onward.
CREATE FUNCTION dbo.fn_LoanInterestSegments (@agreement_sno INT, @from DATE, @to DATE, @extra_repay DECIMAL(18,2))
RETURNS @seg TABLE (
    seg_no INT, seg_from DATE, seg_to DATE, days INT, principal DECIMAL(18,2),
    benchmark_rate_pct DECIMAL(7,3), spread_pct DECIMAL(7,3), rate_pct DECIMAL(7,3), interest DECIMAL(18,2)
)
AS
BEGIN
    DECLARE @basis SMALLINT = ISNULL((SELECT day_count_basis FROM dbo.service_agreement_statutory WHERE agreement_sno = @agreement_sno), 365);
    DECLARE @bp TABLE (d DATE NOT NULL);

    INSERT INTO @bp (d)
    SELECT x.d
    FROM (
        SELECT @from AS d
        UNION SELECT effective_from FROM dbo.loan_rate_period WHERE agreement_sno = @agreement_sno
        UNION SELECT txn_date FROM dbo.loan_principal_txn WHERE agreement_sno = @agreement_sno AND is_active = 'Y'
        UNION SELECT disbursement_date FROM dbo.service_agreement_statutory WHERE agreement_sno = @agreement_sno AND disbursement_date IS NOT NULL
    ) x
    WHERE x.d >= @from AND x.d < @to;

    INSERT INTO @seg (seg_no, seg_from, seg_to, days, principal, benchmark_rate_pct, spread_pct, rate_pct, interest)
    SELECT ROW_NUMBER() OVER (ORDER BY b.d), b.d, b.nxt, DATEDIFF(DAY, b.d, b.nxt), b.pr,
           r.benchmark_rate_pct, r.spread_pct, r.interest_rate_pct,
           ROUND(b.pr * r.interest_rate_pct / 100.0 * DATEDIFF(DAY, b.d, b.nxt) / @basis, 2)
    FROM (
        SELECT d, ISNULL(LEAD(d) OVER (ORDER BY d), @to) AS nxt,
               dbo.fn_LoanPrincipalAt(@agreement_sno, d) - ISNULL(@extra_repay, 0) AS pr
        FROM @bp
    ) b
    CROSS APPLY dbo.fn_LoanRateAt(@agreement_sno, b.d) r;

    RETURN;
END;
GO

CREATE FUNCTION dbo.fn_LoanBilledThrough (@agreement_sno INT)
RETURNS DATE
AS
BEGIN
    RETURN ISNULL(
        (SELECT MAX(v.period_to) FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = @agreement_sno AND v.status IN ('APPROVED', 'PAID')),
        (SELECT s.disbursement_date FROM dbo.service_agreement_statutory s WHERE s.agreement_sno = @agreement_sno));
END;
GO

CREATE FUNCTION dbo.fn_LoanLockedThrough (@agreement_sno INT)
RETURNS DATE
AS
BEGIN
    RETURN ISNULL(
        (SELECT MAX(v.period_to) FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = @agreement_sno AND v.status IN ('PENDING_APPROVAL', 'APPROVED', 'PAID')),
        (SELECT s.disbursement_date FROM dbo.service_agreement_statutory s WHERE s.agreement_sno = @agreement_sno));
END;
GO

CREATE PROCEDURE dbo.sp_nt_ResolveBankVoucherWorkflow
    @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT,
    @workflow_types_id INT OUTPUT,
    @first_approver VARCHAR(30) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1 @workflow_types_id = wt.workflow_types_id
    FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
      AND awm.entity_type = 'BankPaymentVoucher' AND wt.is_active = 'Y'
    ORDER BY wt.workflow_types_id;

    IF @workflow_types_id IS NULL
        THROW 58430, 'No BankPaymentVoucher approval workflow is configured for this company/division/branch/department. Configure one in the Approval Workflow Manager first.', 1;

    SELECT TOP 1 @first_approver = JSON_VALUE(j.value, '$.approver_ecno')
    FROM dbo.workflow_stage ws
    CROSS APPLY OPENJSON(ws.stage_order_json) j
    WHERE ws.workflow_types_id = @workflow_types_id AND ws.is_active = 'Y' AND j.[key] = '0';

    IF @first_approver IS NULL
        THROW 58431, 'No approver found for the first stage of the BankPaymentVoucher workflow.', 1;
END;
GO

CREATE PROCEDURE dbo.sp_nt_CalcLoanVoucher
    @agreement_sno INT,
    @payment_date DATE = NULL,
    @principal_repayment DECIMAL(18,2) = 0,
    @out_agreement_no VARCHAR(30) = NULL OUTPUT,
    @out_period_from DATE = NULL OUTPUT,
    @out_period_to DATE = NULL OUTPUT,
    @out_default_payment_date DATE = NULL OUTPUT,
    @out_days INT = NULL OUTPUT,
    @out_basis SMALLINT = NULL OUTPUT,
    @out_opening_principal DECIMAL(18,2) = NULL OUTPUT,
    @out_principal_on_payment DECIMAL(18,2) = NULL OUTPUT,
    @out_interest DECIMAL(18,2) = NULL OUTPUT,
    @out_principal_after DECIMAL(18,2) = NULL OUTPUT,
    @out_rate_pct DECIMAL(7,3) = NULL OUTPUT,
    @out_segments_json NVARCHAR(MAX) = NULL OUTPUT,
    @out_next_due DATE = NULL OUTPUT,
    @out_next_days INT = NULL OUTPUT,
    @out_next_interest DECIMAL(18,2) = NULL OUTPUT,
    @out_next_segments_json NVARCHAR(MAX) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status CHAR(1), @period_end DATE, @pay_day TINYINT, @disb DATE, @basis SMALLINT;
    SELECT @status = sa.status, @period_end = sa.period_end_date, @out_agreement_no = sa.agreement_no,
           @pay_day = s.interest_payment_day, @disb = s.disbursement_date, @basis = s.day_count_basis
    FROM dbo.service_agreement sa
    JOIN dbo.service_agreement_statutory s ON s.agreement_sno = sa.agreement_sno
    WHERE sa.agreement_sno = @agreement_sno;

    IF @status IS NULL
        THROW 58400, 'Loan facility not found for this agreement.', 1;
    IF @status <> 'A'
        THROW 58402, 'Interest vouchers can only be raised on an approved loan agreement.', 1;
    IF @pay_day IS NULL OR @disb IS NULL OR @basis IS NULL
        THROW 58403, 'This loan is missing its disbursement date, interest payment day or day-count basis - edit the agreement to add them.', 1;
    IF ISNULL(@principal_repayment, 0) < 0
        THROW 58406, 'The principal repayment cannot be negative.', 1;

    DECLARE @from DATE = dbo.fn_LoanBilledThrough(@agreement_sno);
    IF @from >= @period_end
        THROW 58408, 'Interest has been billed up to the end of the loan term - there is nothing further to bill. Renew the agreement to continue.', 1;

    DECLARE @default_to DATE = dbo.fn_LoanNextDueDate(@pay_day, @from);
    IF @default_to > @period_end SET @default_to = @period_end;
    DECLARE @to DATE = ISNULL(@payment_date, @default_to);

    DECLARE @msg NVARCHAR(400);
    IF @to <= @from
    BEGIN
        SET @msg = N'The payment date must be after ' + CONVERT(NVARCHAR(11), @from, 106) + N' - interest is already billed up to that date.';
        THROW 58404, @msg, 1;
    END
    IF @to > @period_end
    BEGIN
        SET @msg = N'The payment date is beyond the end of the loan term (' + CONVERT(NVARCHAR(11), @period_end, 106) + N').';
        THROW 58405, @msg, 1;
    END

    SET @out_period_from = @from;
    SET @out_period_to = @to;
    SET @out_default_payment_date = @default_to;
    SET @out_days = DATEDIFF(DAY, @from, @to);
    SET @out_basis = @basis;

    SELECT @out_interest = ISNULL(SUM(interest), 0)
    FROM dbo.fn_LoanInterestSegments(@agreement_sno, @from, @to, 0);

    SET @out_segments_json = ISNULL((
        SELECT seg_no, seg_from AS from_date, DATEADD(DAY, -1, seg_to) AS to_date, days, principal,
               benchmark_rate_pct, spread_pct, rate_pct, interest
        FROM dbo.fn_LoanInterestSegments(@agreement_sno, @from, @to, 0)
        ORDER BY seg_no
        FOR JSON PATH), N'[]');

    SET @out_opening_principal = dbo.fn_LoanPrincipalAt(@agreement_sno, @from);
    SET @out_principal_on_payment = dbo.fn_LoanPrincipalAt(@agreement_sno, @to);

    IF ISNULL(@principal_repayment, 0) > @out_principal_on_payment
    BEGIN
        SET @msg = N'The principal repayment (' + CONVERT(NVARCHAR(30), @principal_repayment) + N') is more than the principal outstanding on that date ('
                 + CONVERT(NVARCHAR(30), @out_principal_on_payment) + N').';
        THROW 58407, @msg, 1;
    END
    SET @out_principal_after = @out_principal_on_payment - ISNULL(@principal_repayment, 0);

    SELECT @out_rate_pct = interest_rate_pct FROM dbo.fn_LoanRateAt(@agreement_sno, @to);

    -- The NEXT interest date, priced at the rates already known (the last one
    -- carries forward) on the principal left after this payment.
    IF @to < @period_end
    BEGIN
        SET @out_next_due = dbo.fn_LoanNextDueDate(@pay_day, @to);
        IF @out_next_due > @period_end SET @out_next_due = @period_end;
        SET @out_next_days = DATEDIFF(DAY, @to, @out_next_due);

        SELECT @out_next_interest = ISNULL(SUM(interest), 0)
        FROM dbo.fn_LoanInterestSegments(@agreement_sno, @to, @out_next_due, ISNULL(@principal_repayment, 0));

        SET @out_next_segments_json = ISNULL((
            SELECT seg_no, seg_from AS from_date, DATEADD(DAY, -1, seg_to) AS to_date, days, principal,
                   benchmark_rate_pct, spread_pct, rate_pct, interest
            FROM dbo.fn_LoanInterestSegments(@agreement_sno, @to, @out_next_due, ISNULL(@principal_repayment, 0))
            ORDER BY seg_no
            FOR JSON PATH), N'[]');
    END
END;
GO

CREATE PROCEDURE dbo.sp_nt_PreviewLoanInterest
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @agreement_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT),
            @payment_date  DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_date') AS DATE),
            @repay         DECIMAL(18,2) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.principal_repayment') AS DECIMAL(18,2)), 0);
    IF @agreement_sno IS NULL
        THROW 58400, 'agreement_sno is required.', 1;

    DECLARE @agreement_no VARCHAR(30), @from DATE, @to DATE, @default_to DATE, @days INT, @basis SMALLINT,
            @opening DECIMAL(18,2), @on_payment DECIMAL(18,2), @interest DECIMAL(18,2), @after DECIMAL(18,2),
            @rate DECIMAL(7,3), @segments NVARCHAR(MAX), @next_due DATE, @next_days INT, @next_interest DECIMAL(18,2),
            @next_segments NVARCHAR(MAX);

    EXEC dbo.sp_nt_CalcLoanVoucher
        @agreement_sno = @agreement_sno, @payment_date = @payment_date, @principal_repayment = @repay,
        @out_agreement_no = @agreement_no OUTPUT, @out_period_from = @from OUTPUT, @out_period_to = @to OUTPUT,
        @out_default_payment_date = @default_to OUTPUT, @out_days = @days OUTPUT, @out_basis = @basis OUTPUT,
        @out_opening_principal = @opening OUTPUT, @out_principal_on_payment = @on_payment OUTPUT,
        @out_interest = @interest OUTPUT, @out_principal_after = @after OUTPUT, @out_rate_pct = @rate OUTPUT,
        @out_segments_json = @segments OUTPUT, @out_next_due = @next_due OUTPUT, @out_next_days = @next_days OUTPUT,
        @out_next_interest = @next_interest OUTPUT, @out_next_segments_json = @next_segments OUTPUT;

    DECLARE @today DATE = CAST(GETDATE() AS DATE);

    SELECT @agreement_sno AS agreement_sno, @agreement_no AS agreement_no,
           @from AS period_from, @to AS period_to, @default_to AS default_payment_date,
           @days AS days, @basis AS day_count_basis,
           @opening AS opening_principal, @on_payment AS principal_on_payment,
           @repay AS principal_repayment, @interest AS interest_amount,
           @interest + @repay AS total_payable, @after AS principal_after, @rate AS rate_pct,
           @segments AS segments_json,
           @next_due AS next_due_date, @next_days AS next_days, @next_interest AS next_est_interest,
           @next_segments AS next_segments_json,
           s.rate_type, s.benchmark_name, s.interest_payment_day,
           CASE WHEN s.rate_type = 'FLOATING' AND @to > @today THEN 1 ELSE 0 END AS is_projected,
           CASE WHEN s.rate_type = 'FLOATING' AND @to > @today THEN DATEDIFF(DAY, @today, @to) ELSE 0 END AS projected_days,
           (SELECT effective_from FROM dbo.fn_LoanRateAt(@agreement_sno, @to)) AS rate_effective_from,
           (SELECT TOP 1 v.voucher_sno FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = @agreement_sno AND v.status = 'PENDING_APPROVAL') AS open_voucher_sno,
           (SELECT TOP 1 v.voucher_no FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = @agreement_sno AND v.status = 'PENDING_APPROVAL') AS open_voucher_no
    FROM dbo.service_agreement_statutory s
    WHERE s.agreement_sno = @agreement_sno;
END;
GO

CREATE PROCEDURE dbo.sp_nt_CreateBankPaymentVoucher
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @agreement_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT),
                @payment_date  DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_date') AS DATE),
                @repay         DECIMAL(18,2) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.principal_repayment') AS DECIMAL(18,2)), 0),
                @remarks       NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.remarks'))), ''),
                @created_by    VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.created_by');

        IF @agreement_sno IS NULL OR @created_by IS NULL
            THROW 58400, 'agreement_sno and created_by are required.', 1;

        BEGIN TRANSACTION;

        -- Serialise voucher creation per loan.
        DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @vendor_sno INT;
        SELECT @com_sno = com_sno, @div_sno = div_sno, @brn_sno = brn_sno, @dept_sno = dept_sno, @vendor_sno = vendor_sno
        FROM dbo.service_agreement WITH (UPDLOCK, HOLDLOCK)
        WHERE agreement_sno = @agreement_sno;

        IF @com_sno IS NULL
            THROW 58400, 'Loan facility not found for this agreement.', 1;

        DECLARE @open_no VARCHAR(30) = (SELECT TOP 1 voucher_no FROM dbo.bank_payment_voucher WHERE agreement_sno = @agreement_sno AND status = 'PENDING_APPROVAL');
        IF @open_no IS NOT NULL
        BEGIN
            DECLARE @open_msg NVARCHAR(300) = N'Voucher ' + @open_no + N' for this loan is still awaiting approval - approve or reject it before raising the next one.';
            THROW 58410, @open_msg, 1;
        END

        DECLARE @agreement_no VARCHAR(30), @from DATE, @to DATE, @default_to DATE, @days INT, @basis SMALLINT,
                @opening DECIMAL(18,2), @on_payment DECIMAL(18,2), @interest DECIMAL(18,2), @after DECIMAL(18,2),
                @rate DECIMAL(7,3), @segments NVARCHAR(MAX), @next_due DATE, @next_days INT, @next_interest DECIMAL(18,2),
                @next_segments NVARCHAR(MAX);

        EXEC dbo.sp_nt_CalcLoanVoucher
            @agreement_sno = @agreement_sno, @payment_date = @payment_date, @principal_repayment = @repay,
            @out_agreement_no = @agreement_no OUTPUT, @out_period_from = @from OUTPUT, @out_period_to = @to OUTPUT,
            @out_default_payment_date = @default_to OUTPUT, @out_days = @days OUTPUT, @out_basis = @basis OUTPUT,
            @out_opening_principal = @opening OUTPUT, @out_principal_on_payment = @on_payment OUTPUT,
            @out_interest = @interest OUTPUT, @out_principal_after = @after OUTPUT, @out_rate_pct = @rate OUTPUT,
            @out_segments_json = @segments OUTPUT, @out_next_due = @next_due OUTPUT, @out_next_days = @next_days OUTPUT,
            @out_next_interest = @next_interest OUTPUT, @out_next_segments_json = @next_segments OUTPUT;

        IF @interest + @repay <= 0
            THROW 58411, 'There is nothing to pay for this period (no interest accrued and no principal repayment entered).', 1;

        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        EXEC dbo.sp_nt_ResolveBankVoucherWorkflow
            @com_sno = @com_sno, @div_sno = @div_sno, @brn_sno = @brn_sno, @dept_sno = @dept_sno,
            @workflow_types_id = @workflow_types_id OUTPUT, @first_approver = @first_approver OUTPUT;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(voucher_no, 4) AS INT)), 0) + 1
        FROM dbo.bank_payment_voucher WITH (UPDLOCK, HOLDLOCK)
        WHERE voucher_no LIKE 'BPV-' + @year + '-%';
        DECLARE @voucher_no VARCHAR(30) = 'BPV-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.bank_payment_voucher (
            voucher_no, agreement_sno, com_sno, div_sno, brn_sno, dept_sno, vendor_sno,
            period_from, period_to, days, day_count_basis,
            opening_principal, principal_on_payment, interest_amount, principal_repayment, total_payable, principal_after, rate_pct,
            segments_json, next_due_date, next_days, next_est_interest, next_segments_json,
            remarks, status, workflow_types_id, current_approver_id, current_stage_seq, created_by
        )
        VALUES (
            @voucher_no, @agreement_sno, @com_sno, @div_sno, @brn_sno, @dept_sno, @vendor_sno,
            @from, @to, @days, @basis,
            @opening, @on_payment, @interest, @repay, @interest + @repay, @after, @rate,
            @segments, @next_due, @next_days, @next_interest, @next_segments,
            @remarks, 'PENDING_APPROVAL', @workflow_types_id, @first_approver, 0, @created_by
        );
        DECLARE @voucher_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.bank_payment_voucher_history (voucher_sno, action_type, status_by, comment)
        VALUES (@voucher_sno, 'CREATED', @created_by, @remarks);

        COMMIT TRANSACTION;

        SELECT 'SUCCESS' AS result, @voucher_sno AS voucher_sno, @voucher_no AS voucher_no, @agreement_no AS agreement_no,
               @interest AS interest_amount, @repay AS principal_repayment, @interest + @repay AS total_payable,
               @first_approver AS current_approver_id;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE PROCEDURE dbo.sp_nt_ApproveBankPaymentVoucher
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @voucher_sno INT          = TRY_CAST(JSON_VALUE(@jsonInput, '$.voucher_sno') AS INT),
                @approved_by VARCHAR(30)  = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action      VARCHAR(10)  = LOWER(LTRIM(RTRIM(ISNULL(JSON_VALUE(@jsonInput, '$.action'), '')))),
                @comments    NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.comments'))), '');

        IF @voucher_sno IS NULL OR @approved_by IS NULL OR @action NOT IN ('approve', 'reject')
            THROW 58420, 'voucher_sno, approved_by and a valid action (approve / reject) are required.', 1;

        BEGIN TRANSACTION;

        DECLARE @status VARCHAR(20), @current_approver VARCHAR(30), @stage_seq INT, @workflow_types_id INT,
                @agreement_sno INT, @voucher_no VARCHAR(30), @period_to DATE, @repay DECIMAL(18,2);
        SELECT @status = status, @current_approver = current_approver_id, @stage_seq = current_stage_seq,
               @workflow_types_id = workflow_types_id, @agreement_sno = agreement_sno, @voucher_no = voucher_no,
               @period_to = period_to, @repay = principal_repayment
        FROM dbo.bank_payment_voucher WITH (UPDLOCK, HOLDLOCK)
        WHERE voucher_sno = @voucher_sno;

        IF @status IS NULL
            THROW 58421, 'Bank payment voucher not found.', 1;
        IF @status <> 'PENDING_APPROVAL'
            THROW 58422, 'This voucher is not awaiting approval.', 1;
        IF @current_approver IS NULL OR @current_approver <> @approved_by
            THROW 58423, 'This voucher is not awaiting your approval.', 1;

        IF @action = 'reject'
        BEGIN
            UPDATE dbo.bank_payment_voucher SET status = 'REJECTED', current_approver_id = NULL WHERE voucher_sno = @voucher_sno;
            INSERT INTO dbo.bank_payment_voucher_history (voucher_sno, action_type, status_by, comment)
            VALUES (@voucher_sno, 'REJECTED', @approved_by, @comments);
            COMMIT TRANSACTION;
            SELECT 'REJECTED' AS result, @voucher_sno AS voucher_sno, @voucher_no AS voucher_no;
            RETURN;
        END

        INSERT INTO dbo.bank_payment_voucher_history (voucher_sno, action_type, status_by, comment)
        VALUES (@voucher_sno, 'APPROVED', @approved_by, @comments);

        -- Next stage of the workflow, if any
        DECLARE @next_approver VARCHAR(30) = NULL;
        SELECT TOP 1 @next_approver = JSON_VALUE(j.value, '$.approver_ecno')
        FROM dbo.workflow_stage ws
        CROSS APPLY OPENJSON(ws.stage_order_json) j
        WHERE ws.workflow_types_id = @workflow_types_id AND ws.is_active = 'Y' AND TRY_CAST(j.[key] AS INT) = @stage_seq + 1;

        IF @next_approver IS NOT NULL
        BEGIN
            UPDATE dbo.bank_payment_voucher SET current_approver_id = @next_approver, current_stage_seq = @stage_seq + 1 WHERE voucher_sno = @voucher_sno;
            COMMIT TRANSACTION;
            SELECT 'SUCCESS' AS result, @voucher_sno AS voucher_sno, @voucher_no AS voucher_no, @next_approver AS next_approver, 'PENDING_APPROVAL' AS status;
            RETURN;
        END

        -- Final stage
        UPDATE dbo.bank_payment_voucher
        SET status = 'APPROVED', current_approver_id = NULL, approved_at = GETDATE()
        WHERE voucher_sno = @voucher_sno;

        IF @repay > 0
        BEGIN
            INSERT INTO dbo.loan_principal_txn (agreement_sno, txn_date, txn_type, amount, voucher_sno, remarks, created_by)
            VALUES (@agreement_sno, @period_to, 'REPAYMENT', @repay, @voucher_sno, N'Principal repaid with ' + @voucher_no, @approved_by);

            IF dbo.fn_LoanPrincipalAt(@agreement_sno, @period_to) < 0
                THROW 58424, 'Approving this voucher would take the principal below zero - another principal movement was entered after the voucher was raised. Reject it and raise a new one.', 1;
        END

        COMMIT TRANSACTION;
        SELECT 'SUCCESS' AS result, @voucher_sno AS voucher_sno, @voucher_no AS voucher_no, 'FINAL_STAGE' AS next_approver, 'APPROVED' AS status;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE PROCEDURE dbo.sp_nt_MarkBankPaymentVoucherPaid
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @voucher_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.voucher_sno') AS INT),
                @paid_on        DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.paid_on') AS DATE),
                @mode           VARCHAR(10)   = LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.payment_mode'))),
                @ref_no         NVARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.payment_ref_no'))), ''),
                @from_bank      NVARCHAR(150) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.paid_from_bank'))), ''),
                @paid_by        VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.paid_by'),
                @remarks        NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.remarks'))), '');

        IF @voucher_sno IS NULL OR @paid_by IS NULL OR @paid_on IS NULL
            THROW 58440, 'voucher_sno, paid_on and paid_by are required.', 1;
        IF @mode IS NULL OR @mode NOT IN ('NEFT', 'RTGS', 'Cheque', 'DD', 'UPI', 'ECS', 'Cash')
            THROW 58441, 'payment_mode must be one of NEFT, RTGS, Cheque, DD, UPI, ECS, Cash.', 1;
        IF @mode <> 'Cash' AND @ref_no IS NULL
            THROW 58442, 'The bank reference / UTR / cheque number is required for a non-cash payment.', 1;
        IF @paid_on > CAST(GETDATE() AS DATE)
            THROW 58443, 'The payment date cannot be in the future - record the payment once it has been made.', 1;

        BEGIN TRANSACTION;

        DECLARE @status VARCHAR(20), @voucher_no VARCHAR(30);
        SELECT @status = status, @voucher_no = voucher_no
        FROM dbo.bank_payment_voucher WITH (UPDLOCK, HOLDLOCK) WHERE voucher_sno = @voucher_sno;

        IF @status IS NULL THROW 58421, 'Bank payment voucher not found.', 1;
        IF @status <> 'APPROVED' THROW 58444, 'Only an approved voucher that has not been paid yet can be marked paid.', 1;

        UPDATE dbo.bank_payment_voucher
        SET status = 'PAID', paid_on = @paid_on, payment_mode = @mode, payment_ref_no = @ref_no,
            paid_from_bank = @from_bank, paid_by = @paid_by, paid_recorded_at = GETDATE()
        WHERE voucher_sno = @voucher_sno;

        INSERT INTO dbo.bank_payment_voucher_history (voucher_sno, action_type, status_by, comment)
        VALUES (@voucher_sno, 'PAID', @paid_by,
                @mode + ISNULL(N' ' + @ref_no, N'') + ISNULL(N' - ' + @remarks, N''));

        COMMIT TRANSACTION;
        SELECT 'SUCCESS' AS result, @voucher_sno AS voucher_sno, @voucher_no AS voucher_no, 'PAID' AS status;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- @jsonInput: { agreement_sno, effective_from, benchmark_rate_pct (floating) | interest_rate_pct (fixed), remarks?, entered_by }
CREATE PROCEDURE dbo.sp_nt_AddLoanRatePeriod
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @agreement_sno INT          = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT),
                @effective_from DATE        = TRY_CAST(JSON_VALUE(@jsonInput, '$.effective_from') AS DATE),
                @benchmark DECIMAL(7,3)     = TRY_CAST(JSON_VALUE(@jsonInput, '$.benchmark_rate_pct') AS DECIMAL(7,3)),
                @fixed_rate DECIMAL(7,3)    = TRY_CAST(JSON_VALUE(@jsonInput, '$.interest_rate_pct') AS DECIMAL(7,3)),
                @remarks NVARCHAR(300)      = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.remarks'))), ''),
                @entered_by VARCHAR(30)     = JSON_VALUE(@jsonInput, '$.entered_by');

        IF @agreement_sno IS NULL OR @effective_from IS NULL OR @entered_by IS NULL
            THROW 58450, 'agreement_sno, effective_from and entered_by are required.', 1;

        BEGIN TRANSACTION;

        DECLARE @status CHAR(1), @period_end DATE, @disb DATE, @rate_type VARCHAR(10), @spread DECIMAL(7,3);
        SELECT @status = sa.status, @period_end = sa.period_end_date, @disb = s.disbursement_date,
               @rate_type = s.rate_type, @spread = s.spread_pct
        FROM dbo.service_agreement sa WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.service_agreement_statutory s ON s.agreement_sno = sa.agreement_sno
        WHERE sa.agreement_sno = @agreement_sno;

        IF @status IS NULL THROW 58400, 'Loan facility not found for this agreement.', 1;
        IF @status <> 'A' THROW 58451, 'Rates can only be entered on an approved loan agreement.', 1;

        DECLARE @msg NVARCHAR(400), @locked DATE = dbo.fn_LoanLockedThrough(@agreement_sno);
        IF @effective_from <= @disb
        BEGIN
            SET @msg = N'The rate must take effect after the disbursement date (' + CONVERT(NVARCHAR(11), @disb, 106) + N') - the sanctioned rate already covers the start.';
            THROW 58452, @msg, 1;
        END
        IF @effective_from < @locked
        BEGIN
            SET @msg = N'Interest is already billed (or a voucher is awaiting approval) up to ' + CONVERT(NVARCHAR(11), @locked, 106) + N', so a rate cannot take effect before that date.';
            THROW 58453, @msg, 1;
        END
        IF @effective_from > @period_end
            THROW 58454, 'The rate cannot take effect after the end of the loan term.', 1;
        IF EXISTS (SELECT 1 FROM dbo.loan_rate_period WHERE agreement_sno = @agreement_sno AND effective_from = @effective_from)
            THROW 58455, 'A rate is already entered from that date - delete it first if it needs to change.', 1;

        DECLARE @effective DECIMAL(7,3);
        IF @rate_type = 'FLOATING'
        BEGIN
            IF @benchmark IS NULL OR @benchmark < 0 THROW 58456, 'Enter the benchmark (repo) rate in force from that date.', 1;
            SET @effective = @benchmark + ISNULL(@spread, 0);
        END
        ELSE
        BEGIN
            IF @fixed_rate IS NULL THROW 58457, 'Enter the new interest rate.', 1;
            SET @effective = @fixed_rate;
            SET @benchmark = NULL;
            SET @spread = NULL;
        END
        IF @effective < 0 OR @effective > 100
            THROW 58458, 'The effective interest rate must be between 0 and 100 percent.', 1;

        INSERT INTO dbo.loan_rate_period (agreement_sno, effective_from, benchmark_rate_pct, spread_pct, interest_rate_pct, remarks, created_by)
        VALUES (@agreement_sno, @effective_from, @benchmark, CASE WHEN @rate_type = 'FLOATING' THEN @spread END, @effective, @remarks, @entered_by);

        COMMIT TRANSACTION;
        SELECT 'SUCCESS' AS result, SCOPE_IDENTITY() AS rate_period_sno, @effective AS interest_rate_pct;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- @jsonInput: { rate_period_sno }
CREATE PROCEDURE dbo.sp_nt_DeleteLoanRatePeriod
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @rate_period_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_period_sno') AS INT);
        IF @rate_period_sno IS NULL THROW 58450, 'rate_period_sno is required.', 1;

        BEGIN TRANSACTION;
        DECLARE @agreement_sno INT, @effective_from DATE;
        SELECT @agreement_sno = agreement_sno, @effective_from = effective_from FROM dbo.loan_rate_period WITH (UPDLOCK) WHERE rate_period_sno = @rate_period_sno;
        IF @agreement_sno IS NULL THROW 58459, 'Rate entry not found.', 1;

        DECLARE @locked DATE = dbo.fn_LoanLockedThrough(@agreement_sno), @msg NVARCHAR(400);
        IF @effective_from < @locked
        BEGIN
            SET @msg = N'This rate falls in a period that is already billed (up to ' + CONVERT(NVARCHAR(11), @locked, 106) + N') and cannot be removed.';
            THROW 58453, @msg, 1;
        END

        DELETE FROM dbo.loan_rate_period WHERE rate_period_sno = @rate_period_sno;
        COMMIT TRANSACTION;
        SELECT 'SUCCESS' AS result, @rate_period_sno AS rate_period_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- @jsonInput: { agreement_sno, txn_type: DRAWDOWN|REPAYMENT, txn_date, amount, remarks?, entered_by }
-- A movement takes effect FROM its date. The outstanding principal must stay
-- between zero and the sanctioned amount (or the cash-credit drawing power) on
-- every date from then on — checked after the insert, rolled back if broken.
CREATE PROCEDURE dbo.sp_nt_AddLoanPrincipalTxn
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @agreement_sno INT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT),
                @txn_type VARCHAR(10)   = UPPER(LTRIM(RTRIM(ISNULL(JSON_VALUE(@jsonInput, '$.txn_type'), '')))),
                @txn_date DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.txn_date') AS DATE),
                @amount DECIMAL(18,2)   = TRY_CAST(JSON_VALUE(@jsonInput, '$.amount') AS DECIMAL(18,2)),
                @remarks NVARCHAR(300)  = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.remarks'))), ''),
                @entered_by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.entered_by');

        IF @agreement_sno IS NULL OR @txn_date IS NULL OR @entered_by IS NULL
            THROW 58460, 'agreement_sno, txn_date and entered_by are required.', 1;
        IF @txn_type NOT IN ('DRAWDOWN', 'REPAYMENT')
            THROW 58461, 'txn_type must be DRAWDOWN or REPAYMENT.', 1;
        IF @amount IS NULL OR @amount <= 0
            THROW 58462, 'The amount must be greater than zero.', 1;

        BEGIN TRANSACTION;

        DECLARE @status CHAR(1), @period_end DATE, @disb DATE, @cap DECIMAL(18,2);
        SELECT @status = sa.status, @period_end = sa.period_end_date, @disb = s.disbursement_date,
               @cap = CASE WHEN s.facility_type = 'CASH_CREDIT' THEN ISNULL(s.drawing_power, s.sanctioned_amount) ELSE s.sanctioned_amount END
        FROM dbo.service_agreement sa WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.service_agreement_statutory s ON s.agreement_sno = sa.agreement_sno
        WHERE sa.agreement_sno = @agreement_sno;

        IF @status IS NULL THROW 58400, 'Loan facility not found for this agreement.', 1;
        IF @status <> 'A' THROW 58463, 'Principal movements can only be entered on an approved loan agreement.', 1;

        DECLARE @msg NVARCHAR(400), @locked DATE = dbo.fn_LoanLockedThrough(@agreement_sno);
        IF @txn_date < @disb
            THROW 58464, 'The date cannot be before the disbursement date.', 1;
        IF @txn_date < @locked
        BEGIN
            SET @msg = N'Interest is already billed (or a voucher is awaiting approval) up to ' + CONVERT(NVARCHAR(11), @locked, 106) + N', so a principal movement cannot be dated before that.';
            THROW 58465, @msg, 1;
        END
        IF @txn_date > @period_end
            THROW 58466, 'The date cannot be after the end of the loan term.', 1;

        INSERT INTO dbo.loan_principal_txn (agreement_sno, txn_date, txn_type, amount, remarks, created_by)
        VALUES (@agreement_sno, @txn_date, @txn_type, @amount, @remarks, @entered_by);
        DECLARE @txn_sno INT = SCOPE_IDENTITY();

        IF EXISTS (
            SELECT 1 FROM (
                SELECT @txn_date AS d
                UNION SELECT txn_date FROM dbo.loan_principal_txn WHERE agreement_sno = @agreement_sno AND is_active = 'Y' AND txn_date >= @txn_date
            ) x
            WHERE dbo.fn_LoanPrincipalAt(@agreement_sno, x.d) < 0 OR dbo.fn_LoanPrincipalAt(@agreement_sno, x.d) > @cap
        )
        BEGIN
            SET @msg = CASE WHEN @txn_type = 'REPAYMENT'
                            THEN N'That repayment is more than the principal outstanding on that date.'
                            ELSE N'That drawdown would take the outstanding principal above the ' + CONVERT(NVARCHAR(30), @cap) + N' limit.' END;
            THROW 58467, @msg, 1;
        END

        COMMIT TRANSACTION;
        SELECT 'SUCCESS' AS result, @txn_sno AS txn_sno, dbo.fn_LoanPrincipalAt(@agreement_sno, @txn_date) AS principal_on_date;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- @jsonInput: { txn_sno } — only a manually entered movement, and only for a period not yet billed.
CREATE PROCEDURE dbo.sp_nt_DeleteLoanPrincipalTxn
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @txn_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.txn_sno') AS INT);
        IF @txn_sno IS NULL THROW 58460, 'txn_sno is required.', 1;

        BEGIN TRANSACTION;
        DECLARE @agreement_sno INT, @txn_date DATE, @voucher_sno INT, @active CHAR(1), @cap DECIMAL(18,2);
        SELECT @agreement_sno = t.agreement_sno, @txn_date = t.txn_date, @voucher_sno = t.voucher_sno, @active = t.is_active,
               @cap = CASE WHEN s.facility_type = 'CASH_CREDIT' THEN ISNULL(s.drawing_power, s.sanctioned_amount) ELSE s.sanctioned_amount END
        FROM dbo.loan_principal_txn t WITH (UPDLOCK)
        JOIN dbo.service_agreement_statutory s ON s.agreement_sno = t.agreement_sno
        WHERE t.txn_sno = @txn_sno;

        IF @agreement_sno IS NULL OR @active <> 'Y' THROW 58468, 'Principal movement not found.', 1;
        IF @voucher_sno IS NOT NULL THROW 58469, 'This repayment came from a bank payment voucher and cannot be removed here.', 1;

        DECLARE @locked DATE = dbo.fn_LoanLockedThrough(@agreement_sno), @msg NVARCHAR(400);
        IF @txn_date < @locked
        BEGIN
            SET @msg = N'This movement falls in a period that is already billed (up to ' + CONVERT(NVARCHAR(11), @locked, 106) + N') and cannot be removed.';
            THROW 58465, @msg, 1;
        END

        UPDATE dbo.loan_principal_txn SET is_active = 'N' WHERE txn_sno = @txn_sno;

        IF EXISTS (
            SELECT 1 FROM (SELECT DISTINCT txn_date AS d FROM dbo.loan_principal_txn WHERE agreement_sno = @agreement_sno AND is_active = 'Y' AND txn_date >= @txn_date) x
            WHERE dbo.fn_LoanPrincipalAt(@agreement_sno, x.d) < 0 OR dbo.fn_LoanPrincipalAt(@agreement_sno, x.d) > @cap
        )
            THROW 58467, 'Removing this movement would leave a later repayment or drawdown out of range. Remove those first.', 1;

        COMMIT TRANSACTION;
        SELECT 'SUCCESS' AS result, @txn_sno AS txn_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- The loans in process: every Approved (or Expired) Statutory agreement, with the
-- figures as of today. @jsonInput (optional): { com_sno, div_sno, brn_sno, dept_sno }
CREATE PROCEDURE dbo.sp_nt_GetLoanAccounts
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @com_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
    END
    DECLARE @today DATE = CAST(GETDATE() AS DATE);

    SELECT b.*, rt.current_rate_pct, ISNULL(acc.accrued_interest, 0) AS accrued_interest,
           dbo.fn_LoanPrincipalAt(b.agreement_sno, @today) AS principal_outstanding,
           CASE WHEN b.billed_through >= b.period_end_date THEN NULL
                WHEN dbo.fn_LoanNextDueDate(b.interest_payment_day, b.billed_through) > b.period_end_date THEN b.period_end_date
                ELSE dbo.fn_LoanNextDueDate(b.interest_payment_day, b.billed_through) END AS next_due_date,
           pv.pending_voucher_sno, pv.pending_voucher_no,
           uv.unpaid_voucher_sno, uv.unpaid_voucher_no,
           ISNULL(tot.voucher_count, 0) AS voucher_count, ISNULL(tot.interest_billed, 0) AS interest_billed
    FROM (
        SELECT sa.agreement_sno, sa.agreement_no, sa.status AS agreement_status,
               sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno, sa.vendor_sno, k.company_name AS vendor_name,
               sm.service_name, sa.period_start_date, sa.period_end_date,
               s.facility_type, s.facility_ref_no, s.sanctioned_amount, s.drawing_power, s.rate_type, s.benchmark_name,
               s.benchmark_rate_pct, s.spread_pct, s.interest_rate_pct AS sanctioned_rate_pct,
               s.disbursed_amount, s.disbursement_date, s.interest_payment_day, s.day_count_basis,
               dbo.fn_LoanBilledThrough(sa.agreement_sno) AS billed_through
        FROM dbo.service_agreement sa
        JOIN dbo.service_agreement_statutory s ON s.agreement_sno = sa.agreement_sno
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
        WHERE sa.status IN ('A', 'X') AND sa.is_active = 'Y'
          AND s.disbursement_date IS NOT NULL AND s.interest_payment_day IS NOT NULL
          AND (@com_sno IS NULL OR sa.com_sno = @com_sno) AND (@div_sno IS NULL OR sa.div_sno = @div_sno)
          AND (@brn_sno IS NULL OR sa.brn_sno = @brn_sno) AND (@dept_sno IS NULL OR sa.dept_sno = @dept_sno)
    ) b
    OUTER APPLY (SELECT TOP 1 r.interest_rate_pct AS current_rate_pct FROM dbo.fn_LoanRateAt(b.agreement_sno, @today) r) rt
    OUTER APPLY (
        SELECT SUM(g.interest) AS accrued_interest
        FROM dbo.fn_LoanInterestSegments(b.agreement_sno, b.billed_through,
                 CASE WHEN @today > b.period_end_date THEN b.period_end_date ELSE @today END, 0) g
    ) acc
    OUTER APPLY (SELECT TOP 1 v.voucher_sno AS pending_voucher_sno, v.voucher_no AS pending_voucher_no
                 FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = b.agreement_sno AND v.status = 'PENDING_APPROVAL') pv
    OUTER APPLY (SELECT TOP 1 v.voucher_sno AS unpaid_voucher_sno, v.voucher_no AS unpaid_voucher_no
                 FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = b.agreement_sno AND v.status = 'APPROVED' ORDER BY v.voucher_sno) uv
    OUTER APPLY (SELECT COUNT(*) AS voucher_count, SUM(v.interest_amount) AS interest_billed
                 FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = b.agreement_sno AND v.status IN ('APPROVED', 'PAID')) tot
    ORDER BY b.agreement_sno DESC;
END;
GO

-- @jsonInput (optional): { agreement_sno, status, com_sno, div_sno, brn_sno, dept_sno }
CREATE PROCEDURE dbo.sp_nt_GetBankPaymentVouchers
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @agreement_sno INT = NULL, @status VARCHAR(20) = NULL, @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @agreement_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
        SET @status       = NULLIF(JSON_VALUE(@jsonInput, '$.status'), '');
        SET @com_sno      = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno      = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno      = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno     = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
    END

    SELECT v.voucher_sno, v.voucher_no, v.agreement_sno, sa.agreement_no, sm.service_name,
           k.company_name AS vendor_name, s.facility_type, s.facility_ref_no,
           v.period_from, v.period_to, v.days, v.opening_principal, v.principal_on_payment, v.interest_amount,
           v.principal_repayment, v.total_payable, v.principal_after, v.rate_pct, v.next_due_date, v.next_est_interest,
           v.status, v.current_approver_id, v.created_by, v.created_at, v.approved_at,
           v.paid_on, v.payment_mode, v.payment_ref_no, v.paid_from_bank
    FROM dbo.bank_payment_voucher v
    JOIN dbo.service_agreement sa ON sa.agreement_sno = v.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    LEFT JOIN dbo.service_agreement_statutory s ON s.agreement_sno = v.agreement_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = v.vendor_sno
    WHERE (@agreement_sno IS NULL OR v.agreement_sno = @agreement_sno)
      AND (@status IS NULL OR v.status = @status)
      AND (@com_sno IS NULL OR v.com_sno = @com_sno) AND (@div_sno IS NULL OR v.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR v.brn_sno = @brn_sno) AND (@dept_sno IS NULL OR v.dept_sno = @dept_sno)
    ORDER BY v.voucher_sno DESC;
END;
GO

-- One voucher in full (for the view / print dialog). @jsonInput: { voucher_sno }
CREATE PROCEDURE dbo.sp_nt_GetBankPaymentVoucher
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @voucher_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.voucher_sno') AS INT);
    IF @voucher_sno IS NULL THROW 58421, 'voucher_sno is required.', 1;

    SELECT v.*, sa.agreement_no, sm.service_name, k.company_name AS vendor_name, k.supp_code AS vendor_code,
           s.facility_type, s.facility_ref_no, s.rate_type, s.benchmark_name, s.sanctioned_amount, s.disbursed_amount,
           s.disbursement_date, s.interest_payment_day, s.day_count_basis AS facility_day_count_basis,
           c.com_name, dv.div_name, br.brn_name, dp.dept_name,
           (
               SELECT TOP 1 b.ac_holder_name, b.ac_number, b.ifsc, b.bank_name, b.bank_branch_name
               FROM dbo.kyc_bank_info b
               WHERE b.kyc_basic_info_sno = v.vendor_sno AND b.is_active = 'Y'
               ORDER BY CASE WHEN b.is_primary = 'Y' THEN 0 ELSE 1 END, b.kyc_address_sno
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
           ) AS beneficiary_json,
           (
               SELECT h.action_type, h.status_by, h.comment, h.created_at
               FROM dbo.bank_payment_voucher_history h WHERE h.voucher_sno = v.voucher_sno
               ORDER BY h.history_sno
               FOR JSON PATH
           ) AS history_json,
           (
               SELECT ws.stage_order_json FROM dbo.workflow_stage ws
               WHERE ws.workflow_types_id = v.workflow_types_id AND ws.is_active = 'Y'
           ) AS stage_order_json
    FROM dbo.bank_payment_voucher v
    JOIN dbo.service_agreement sa ON sa.agreement_sno = v.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    LEFT JOIN dbo.service_agreement_statutory s ON s.agreement_sno = v.agreement_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = v.vendor_sno
    LEFT JOIN dbo.company_master c ON c.com_sno = v.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = v.div_sno
    LEFT JOIN dbo.branch_master br ON br.brn_sno = v.brn_sno
    LEFT JOIN dbo.dept_master dp ON dp.dept_sno = v.dept_sno
    WHERE v.voucher_sno = @voucher_sno;
END;
GO

CREATE PROCEDURE dbo.sp_nt_GetBankPaymentVouchersForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT v.voucher_sno, v.voucher_no, v.agreement_sno, sa.agreement_no, sm.service_name,
           k.company_name AS vendor_name, s.facility_type, s.facility_ref_no, s.rate_type, s.benchmark_name,
           s.sanctioned_amount, s.interest_payment_day,
           v.period_from, v.period_to, v.days, v.day_count_basis, v.opening_principal, v.principal_on_payment,
           v.interest_amount, v.principal_repayment, v.total_payable, v.principal_after, v.rate_pct,
           v.segments_json, v.next_due_date, v.next_days, v.next_est_interest, v.next_segments_json,
           v.remarks, v.status, v.current_approver_id, v.created_by, v.created_at,
           (
               SELECT ws.stage_order_json FROM dbo.workflow_stage ws
               WHERE ws.workflow_types_id = v.workflow_types_id AND ws.is_active = 'Y'
           ) AS stage_order_json
    FROM dbo.bank_payment_voucher v
    JOIN dbo.service_agreement sa ON sa.agreement_sno = v.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    LEFT JOIN dbo.service_agreement_statutory s ON s.agreement_sno = v.agreement_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = v.vendor_sno
    WHERE v.status = 'PENDING_APPROVAL' AND v.current_approver_id = @Ecno
    ORDER BY v.voucher_sno DESC;
END;
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
