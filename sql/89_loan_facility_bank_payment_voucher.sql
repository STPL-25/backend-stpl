-- ============================================================
-- Loan facilities: full loan details, rate history, interest engine and
-- Bank Payment Vouchers (replaces "Statutory -> PO" for loans)
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Context
-- -------
-- sql/88 made Statutory (loan / repo / cash credit) agreements behave like
-- Unfixed: every cycle became a service PO emailed to the bank. A loan is not
-- a purchase, so that was the wrong document. From this file on:
--
--   * A Statutory agreement no longer raises PRs / POs / cycles at all
--     (sp_nt_IssueRecurringServicePOCycle skips it, the hourly sweep never
--     picks it up). Fixed and Unfixed are untouched.
--   * The agreement captures the whole loan: lender, sanctioned + disbursed
--     amount, disbursement date, fixed vs floating (repo + spread), the
--     interest payment day of the month (e.g. 7th) and the day-count basis.
--     Once the agreement is approved the loan is "in process".
--   * Floating loans keep a dated RATE HISTORY (loan_rate_period): "repo is 15%
--     from 1 Jan, 14% from 16 Jan". Principal movements (drawdown / repayment)
--     are dated rows in loan_principal_txn; the opening disbursement is virtual
--     (read from the facility row).
--   * fn_LoanInterestSegments splits [period_from, payment_date) at every rate
--     change and every principal movement and prices each slice:
--         interest = principal x rate% x days / basis      (basis 365 or 360)
--     Interest runs from the last billed date up to, NOT including, the
--     payment date; the payment date itself starts the next period.
--   * A BANK PAYMENT VOUCHER is raised against the loan for each interest
--     date: it freezes the calculation (segments), the principal outstanding,
--     the interest, any principal repaid with it, and the projected NEXT
--     interest. It goes through its own approval workflow (entity_type
--     'BankPaymentVoucher'), then is marked Paid with the bank reference.
--     Approval of a voucher that repays principal writes the repayment into
--     loan_principal_txn, so the next voucher starts from the reduced balance.
--
-- Integrity rules (enforced in the procs, not just the UI)
--   * one voucher awaiting approval per loan (filtered unique index);
--   * a voucher always starts where the last approved/paid one ended;
--   * rates / principal movements dated before the last voucher's end can't
--     be added or removed (those days are already billed);
--   * disbursement date / disbursed amount / day-count basis / rates on the
--     agreement can't be edited once vouchers exist (add a rate period instead).
--
-- Idempotent throughout (IF NOT EXISTS / DROP+CREATE). Safe to re-run.
-- Applied by hand against 10.0.21.8 (no migration runner in this repo).
-- ============================================================

-- ============================================================
-- 1) service_agreement_statutory — the extra loan details
-- ============================================================
IF COL_LENGTH('dbo.service_agreement_statutory', 'benchmark_name') IS NULL
    ALTER TABLE dbo.service_agreement_statutory ADD benchmark_name VARCHAR(30) NULL;      -- 'Repo', 'T-Bill', 'MCLR' ... (label only)
IF COL_LENGTH('dbo.service_agreement_statutory', 'disbursed_amount') IS NULL
    ALTER TABLE dbo.service_agreement_statutory ADD disbursed_amount DECIMAL(18,2) NULL;  -- opening principal drawn on disbursement_date
IF COL_LENGTH('dbo.service_agreement_statutory', 'disbursement_date') IS NULL
    ALTER TABLE dbo.service_agreement_statutory ADD disbursement_date DATE NULL;          -- interest starts here
IF COL_LENGTH('dbo.service_agreement_statutory', 'interest_payment_day') IS NULL
    ALTER TABLE dbo.service_agreement_statutory ADD interest_payment_day TINYINT NULL;    -- 1-31; short months clamp to the last day
IF COL_LENGTH('dbo.service_agreement_statutory', 'day_count_basis') IS NULL
    ALTER TABLE dbo.service_agreement_statutory ADD day_count_basis SMALLINT NULL;        -- 365 or 360 (actual days / basis)
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_service_agreement_statutory_paymentday')
    ALTER TABLE dbo.service_agreement_statutory ADD CONSTRAINT CK_service_agreement_statutory_paymentday
        CHECK (interest_payment_day IS NULL OR interest_payment_day BETWEEN 1 AND 31);
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_service_agreement_statutory_basis')
    ALTER TABLE dbo.service_agreement_statutory ADD CONSTRAINT CK_service_agreement_statutory_basis
        CHECK (day_count_basis IS NULL OR day_count_basis IN (360, 365));
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_service_agreement_statutory_disbursed')
    ALTER TABLE dbo.service_agreement_statutory ADD CONSTRAINT CK_service_agreement_statutory_disbursed
        CHECK (disbursed_amount IS NULL OR (disbursed_amount >= 0 AND disbursed_amount <= sanctioned_amount));
GO

-- ============================================================
-- 2) Tables
-- ============================================================
IF OBJECT_ID('dbo.loan_rate_period', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.loan_rate_period (
        rate_period_sno    INT IDENTITY(1,1) PRIMARY KEY,
        agreement_sno      INT           NOT NULL,
        effective_from     DATE          NOT NULL,       -- the rate applies from this date until the next row
        benchmark_rate_pct DECIMAL(7,3)  NULL,           -- floating: e.g. the repo rate on that date
        spread_pct         DECIMAL(7,3)  NULL,
        interest_rate_pct  DECIMAL(7,3)  NOT NULL,       -- effective rate (= benchmark + spread when floating)
        remarks            NVARCHAR(300) NULL,
        created_by         VARCHAR(30)   NULL,
        created_at         DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_loan_rate_period_agreement FOREIGN KEY (agreement_sno) REFERENCES dbo.service_agreement (agreement_sno),
        CONSTRAINT UQ_loan_rate_period UNIQUE (agreement_sno, effective_from),
        CONSTRAINT CK_loan_rate_period_rate CHECK (interest_rate_pct >= 0 AND interest_rate_pct <= 100)
    );
END;
GO

IF OBJECT_ID('dbo.loan_principal_txn', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.loan_principal_txn (
        txn_sno       INT IDENTITY(1,1) PRIMARY KEY,
        agreement_sno INT           NOT NULL,
        txn_date      DATE          NOT NULL,            -- takes effect FROM this date (interest for this day already uses it)
        txn_type      VARCHAR(10)   NOT NULL,            -- DRAWDOWN | REPAYMENT
        amount        DECIMAL(18,2) NOT NULL,
        voucher_sno   INT           NULL,                -- set when the repayment came from an approved voucher
        remarks       NVARCHAR(300) NULL,
        created_by    VARCHAR(30)   NULL,
        created_at    DATETIME      NOT NULL DEFAULT GETDATE(),
        is_active     CHAR(1)       NOT NULL DEFAULT 'Y',
        CONSTRAINT FK_loan_principal_txn_agreement FOREIGN KEY (agreement_sno) REFERENCES dbo.service_agreement (agreement_sno),
        CONSTRAINT CK_loan_principal_txn_type CHECK (txn_type IN ('DRAWDOWN', 'REPAYMENT')),
        CONSTRAINT CK_loan_principal_txn_amount CHECK (amount > 0)
    );
    CREATE INDEX IX_loan_principal_txn_agreement ON dbo.loan_principal_txn (agreement_sno, txn_date);
END;
GO

IF OBJECT_ID('dbo.bank_payment_voucher', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.bank_payment_voucher (
        voucher_sno         INT IDENTITY(1,1) PRIMARY KEY,
        voucher_no          VARCHAR(30)   NOT NULL,            -- BPV-2026-0001
        agreement_sno       INT           NOT NULL,
        com_sno             INT           NOT NULL,
        div_sno             INT           NOT NULL,
        brn_sno             INT           NOT NULL,
        dept_sno            INT           NOT NULL,
        vendor_sno          INT           NOT NULL,            -- the lender
        period_from         DATE          NOT NULL,            -- interest runs from here ...
        period_to           DATE          NOT NULL,            -- ... up to (not incl.) here; also the payment date
        days                INT           NOT NULL,
        day_count_basis     SMALLINT      NOT NULL,
        opening_principal   DECIMAL(18,2) NOT NULL,            -- outstanding on period_from
        principal_on_payment DECIMAL(18,2) NOT NULL,           -- outstanding on the payment date, before the repayment
        interest_amount     DECIMAL(18,2) NOT NULL,
        principal_repayment DECIMAL(18,2) NOT NULL DEFAULT 0,
        total_payable       DECIMAL(18,2) NOT NULL,            -- interest + principal repayment
        principal_after     DECIMAL(18,2) NOT NULL,            -- outstanding once this voucher is paid
        rate_pct            DECIMAL(7,3)  NOT NULL,            -- rate in force on the payment date
        segments_json       NVARCHAR(MAX) NOT NULL,            -- the frozen calculation
        next_due_date       DATE          NULL,
        next_days           INT           NULL,
        next_est_interest   DECIMAL(18,2) NULL,                -- projection at today's known rate
        next_segments_json  NVARCHAR(MAX) NULL,
        remarks             NVARCHAR(500) NULL,
        status              VARCHAR(20)   NOT NULL DEFAULT 'PENDING_APPROVAL',
        workflow_types_id   INT           NULL,
        current_approver_id VARCHAR(30)   NULL,
        current_stage_seq   INT           NOT NULL DEFAULT 0,
        created_by          VARCHAR(30)   NOT NULL,
        created_at          DATETIME      NOT NULL DEFAULT GETDATE(),
        approved_at         DATETIME      NULL,
        paid_on             DATE          NULL,
        payment_mode        VARCHAR(10)   NULL,
        payment_ref_no      NVARCHAR(100) NULL,
        paid_from_bank      NVARCHAR(150) NULL,
        paid_by             VARCHAR(30)   NULL,
        paid_recorded_at    DATETIME      NULL,
        CONSTRAINT UQ_bank_payment_voucher_no UNIQUE (voucher_no),
        CONSTRAINT FK_bank_payment_voucher_agreement FOREIGN KEY (agreement_sno) REFERENCES dbo.service_agreement (agreement_sno),
        CONSTRAINT CK_bank_payment_voucher_status CHECK (status IN ('PENDING_APPROVAL', 'APPROVED', 'PAID', 'REJECTED')),
        CONSTRAINT CK_bank_payment_voucher_period CHECK (period_to > period_from),
        CONSTRAINT CK_bank_payment_voucher_json CHECK (ISJSON(segments_json) = 1)
    );
    CREATE INDEX IX_bank_payment_voucher_agreement ON dbo.bank_payment_voucher (agreement_sno, status);
    CREATE INDEX IX_bank_payment_voucher_approver ON dbo.bank_payment_voucher (current_approver_id, status);
    -- One voucher awaiting approval per loan (races between two clerks).
    CREATE UNIQUE INDEX UX_bank_payment_voucher_one_open ON dbo.bank_payment_voucher (agreement_sno) WHERE status = 'PENDING_APPROVAL';
END;
GO

IF OBJECT_ID('dbo.bank_payment_voucher_history', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.bank_payment_voucher_history (
        history_sno  INT IDENTITY(1,1) PRIMARY KEY,
        voucher_sno  INT           NOT NULL,
        action_type  VARCHAR(30)   NOT NULL,      -- CREATED | APPROVED | REJECTED | PAID
        status_by    VARCHAR(30)   NOT NULL,
        comment      NVARCHAR(500) NULL,
        created_at   DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_bank_payment_voucher_history_voucher FOREIGN KEY (voucher_sno) REFERENCES dbo.bank_payment_voucher (voucher_sno)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_loan_principal_txn_voucher')
    ALTER TABLE dbo.loan_principal_txn ADD CONSTRAINT FK_loan_principal_txn_voucher FOREIGN KEY (voucher_sno) REFERENCES dbo.bank_payment_voucher (voucher_sno);
GO

-- ============================================================
-- 3) Interest engine functions
-- ============================================================
IF OBJECT_ID('dbo.fn_LoanInterestSegments', 'TF') IS NOT NULL DROP FUNCTION dbo.fn_LoanInterestSegments;
IF OBJECT_ID('dbo.fn_LoanRateAt', 'IF') IS NOT NULL DROP FUNCTION dbo.fn_LoanRateAt;
IF OBJECT_ID('dbo.fn_LoanPrincipalAt', 'FN') IS NOT NULL DROP FUNCTION dbo.fn_LoanPrincipalAt;
IF OBJECT_ID('dbo.fn_LoanNextDueDate', 'FN') IS NOT NULL DROP FUNCTION dbo.fn_LoanNextDueDate;
GO

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

-- ============================================================
-- 4) Seeds: entity_master, starter approval workflow, sidebar screens
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.entity_master WHERE entity_code = 'BankPaymentVoucher')
    INSERT INTO dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by)
    VALUES (N'Bank Payment Voucher', N'BankPaymentVoucher', N'Interest / principal payment voucher raised against an approved loan facility (Statutory agreement)', 'Y', N'system');
GO

-- Same starter approver as the ServicePO / ServiceAgreement workflows (workflow
-- 31: com=1/div=1/brn=1/dept=1, single "Manager Approval" stage). Review and
-- reassign through the Approval Workflow Manager; other org scopes need their
-- own BankPaymentVoucher workflow configured there.
IF NOT EXISTS (
    SELECT 1 FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE wt.com_sno = 1 AND wt.div_sno = 1 AND wt.brn_sno = 1 AND wt.dept_sno = 1
      AND awm.entity_type = 'BankPaymentVoucher'
)
BEGIN
    INSERT INTO dbo.approval_workflow_master (workflow_name, workflow_code, entity_type, description, is_active, created_by, created_at)
    VALUES (N'Bank Payment Voucher Approval Workflow', N'WF_BANKVOUCHER_SEED', N'BankPaymentVoucher', N'Starter workflow, same scope/approver as the ServicePO workflow — review via Approval Workflow Manager.', 'Y', N'system', GETDATE());

    DECLARE @new_workflow_id INT = SCOPE_IDENTITY();

    INSERT INTO dbo.workflow_types (workflow_types_name, workflow_id, workflow_name, is_active, brn_sno, dept_sno, com_sno, div_sno, workflow_types_description, created_by, created_at)
    VALUES (N'CBE3-IT-BankVoucher', @new_workflow_id, N'Bank Payment Voucher Approval Workflow', 'Y', 1, 1, 1, 1, N'SKTM-Coimbatore / Information Technology loan bank payment vouchers', N'system', GETDATE());

    DECLARE @new_workflow_types_id INT = SCOPE_IDENTITY();

    INSERT INTO dbo.workflow_stage (workflow_types_id, stage_order_json, is_active, created_by, created_at)
    VALUES (
        @new_workflow_types_id,
        N'[{"approver_ecno":"KTM1148","stage":"Manager Approval","required_approvals":"1","is_mandatory":"Y","escalation_hours":"24","approver_condition":"","next_approver_ecno":"","can_forward":"Y","can_backward":"N","can_edit_data":"N"}]',
        'Y', N'system', GETDATE()
    );
END;
GO

DECLARE @bpv_group_id INT = 2;
DECLARE @bpv_code VARCHAR(10) = N'S20';
DECLARE @bpv_img NVARCHAR(100) = N'Landmark';

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'LoanVoucherPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Loan Payments', @bpv_code, 'LoanVoucherPage', @bpv_img, @bpv_group_id, 29, 'Y');

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'LoanVoucherApprovalScreen')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Loan Voucher Approvals', @bpv_code, 'LoanVoucherApprovalScreen', @bpv_img, @bpv_group_id, 30, 'Y');
GO

-- ============================================================
-- 5) sp_nt_SaveServiceAgreementStatutory — replaced (sql/88's version plus the
--    loan details). Runs inside the caller's create/update transaction.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_SaveServiceAgreementStatutory', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_SaveServiceAgreementStatutory;
GO
CREATE PROCEDURE dbo.sp_nt_SaveServiceAgreementStatutory
    @agreement_sno INT,
    @service_type_code VARCHAR(30),
    @statutory_json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF @service_type_code <> 'STATUTORY'
    BEGIN
        DELETE FROM dbo.service_agreement_statutory WHERE agreement_sno = @agreement_sno;
        RETURN;
    END

    IF @statutory_json IS NULL OR ISJSON(@statutory_json) = 0
        THROW 58160, 'Loan details (type, sanctioned amount, interest rate, disbursement date, interest payment day) are required for a Statutory agreement.', 1;

    DECLARE @facility_type   VARCHAR(15)   = UPPER(LTRIM(RTRIM(JSON_VALUE(@statutory_json, '$.facility_type')))),
            @facility_ref_no NVARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@statutory_json, '$.facility_ref_no'))), ''),
            @sanctioned      DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@statutory_json, '$.sanctioned_amount') AS DECIMAL(18,2)),
            @drawing_power   DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@statutory_json, '$.drawing_power') AS DECIMAL(18,2)),
            @rate_type       VARCHAR(10)   = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(JSON_VALUE(@statutory_json, '$.rate_type'))), ''), 'FIXED')),
            @benchmark       DECIMAL(7,3)  = TRY_CAST(JSON_VALUE(@statutory_json, '$.benchmark_rate_pct') AS DECIMAL(7,3)),
            @spread          DECIMAL(7,3)  = TRY_CAST(JSON_VALUE(@statutory_json, '$.spread_pct') AS DECIMAL(7,3)),
            @interest        DECIMAL(7,3)  = TRY_CAST(JSON_VALUE(@statutory_json, '$.interest_rate_pct') AS DECIMAL(7,3)),
            @benchmark_name  VARCHAR(30)   = NULLIF(LTRIM(RTRIM(JSON_VALUE(@statutory_json, '$.benchmark_name'))), ''),
            @disbursed       DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@statutory_json, '$.disbursed_amount') AS DECIMAL(18,2)),
            @disb_date       DATE          = TRY_CAST(JSON_VALUE(@statutory_json, '$.disbursement_date') AS DATE),
            @pay_day         INT           = TRY_CAST(JSON_VALUE(@statutory_json, '$.interest_payment_day') AS INT),
            @basis           INT           = ISNULL(TRY_CAST(JSON_VALUE(@statutory_json, '$.day_count_basis') AS INT), 365);

    IF @facility_type IS NULL OR @facility_type NOT IN ('LOAN', 'REPO', 'CASH_CREDIT')
        THROW 58161, 'facility_type must be LOAN, REPO or CASH_CREDIT.', 1;
    IF @sanctioned IS NULL OR @sanctioned <= 0
        THROW 58162, 'sanctioned_amount (loan amount / limit) must be a positive amount.', 1;
    IF @rate_type NOT IN ('FIXED', 'FLOATING')
        THROW 58163, 'rate_type must be FIXED or FLOATING.', 1;

    IF @rate_type = 'FLOATING'
    BEGIN
        IF @benchmark IS NULL OR @spread IS NULL
            THROW 58164, 'A floating-rate facility needs both the benchmark (e.g. repo) rate and the spread.', 1;
        SET @interest = @benchmark + @spread;
        SET @benchmark_name = ISNULL(@benchmark_name, 'Repo');
    END
    ELSE
    BEGIN
        IF @interest IS NULL
            THROW 58165, 'interest_rate_pct is required for a fixed-rate facility.', 1;
        SET @benchmark = NULL;
        SET @spread = NULL;
        SET @benchmark_name = NULL;
    END

    IF @interest < 0 OR @interest > 100
        THROW 58166, 'The effective interest rate must be between 0 and 100 percent.', 1;

    IF @facility_type <> 'CASH_CREDIT'
        SET @drawing_power = NULL;
    ELSE IF @drawing_power IS NOT NULL AND (@drawing_power <= 0 OR @drawing_power > @sanctioned)
        THROW 58167, 'drawing_power must be positive and not more than the sanctioned limit.', 1;

    -- Loan details (sql/89)
    DECLARE @period_start DATE, @period_end DATE;
    SELECT @period_start = period_start_date, @period_end = period_end_date
    FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno;

    IF @disb_date IS NULL
        THROW 58168, 'The disbursement date (when interest starts) is required.', 1;
    IF @disb_date < @period_start OR @disb_date >= @period_end
        THROW 58169, 'The disbursement date must fall within the loan term (Duration From - Duration To).', 1;
    IF @pay_day IS NULL OR @pay_day NOT BETWEEN 1 AND 31
        THROW 58171, 'The interest payment day of the month (1-31) is required.', 1;
    IF @basis NOT IN (360, 365)
        THROW 58172, 'day_count_basis must be 365 or 360.', 1;

    IF @disbursed IS NULL
        SET @disbursed = CASE WHEN @facility_type = 'CASH_CREDIT' THEN 0 ELSE @sanctioned END;
    IF @disbursed < 0 OR @disbursed > @sanctioned
        THROW 58173, 'The disbursed amount must be between 0 and the sanctioned amount.', 1;
    IF @facility_type <> 'CASH_CREDIT' AND @disbursed = 0
        THROW 58174, 'The disbursed amount must be greater than zero (only a cash-credit limit can start at nil).', 1;

    -- Once interest has been billed, the basis of that billing can't move.
    IF EXISTS (SELECT 1 FROM dbo.bank_payment_voucher WHERE agreement_sno = @agreement_sno AND status <> 'REJECTED')
       AND EXISTS (
            SELECT 1 FROM dbo.service_agreement_statutory s
            WHERE s.agreement_sno = @agreement_sno
              AND (   s.disbursement_date <> @disb_date OR ISNULL(s.disbursed_amount, -1) <> @disbursed
                   OR ISNULL(s.day_count_basis, 0) <> @basis OR s.rate_type <> @rate_type
                   OR ISNULL(s.benchmark_rate_pct, -1) <> ISNULL(@benchmark, -1)
                   OR ISNULL(s.spread_pct, -1) <> ISNULL(@spread, -1)
                   OR s.interest_rate_pct <> @interest)
       )
        THROW 58175, 'Interest vouchers already exist for this loan, so the disbursement date, disbursed amount, day-count basis and interest rate cannot be edited here. Enter a rate change under Loan Payments > Rates instead.', 1;

    UPDATE dbo.service_agreement_statutory
    SET facility_type = @facility_type, facility_ref_no = @facility_ref_no, sanctioned_amount = @sanctioned,
        drawing_power = @drawing_power, rate_type = @rate_type, benchmark_rate_pct = @benchmark,
        spread_pct = @spread, interest_rate_pct = @interest,
        benchmark_name = @benchmark_name, disbursed_amount = @disbursed, disbursement_date = @disb_date,
        interest_payment_day = @pay_day, day_count_basis = @basis, modified_at = GETDATE()
    WHERE agreement_sno = @agreement_sno;

    IF @@ROWCOUNT = 0
        INSERT INTO dbo.service_agreement_statutory (
            agreement_sno, facility_type, facility_ref_no, sanctioned_amount, drawing_power,
            rate_type, benchmark_rate_pct, spread_pct, interest_rate_pct,
            benchmark_name, disbursed_amount, disbursement_date, interest_payment_day, day_count_basis
        )
        VALUES (
            @agreement_sno, @facility_type, @facility_ref_no, @sanctioned, @drawing_power,
            @rate_type, @benchmark, @spread, @interest,
            @benchmark_name, @disbursed, @disb_date, @pay_day, @basis
        );
END;
GO

-- ============================================================
-- 6) Existing procs, regenerated from their LIVE definitions with one
--    exactly-once patch each (assert-checked by the generator):
--      sp_nt_SnapshotServiceAgreementVersion: freeze the new loan fields in every version snapshot; also embed the facility block as a real JSON object (it was stored as an escaped string, so the History view could never read it)
--      sp_nt_GetServiceAgreements: return the new loan fields on the agreement list
--      sp_nt_GetServiceAgreementsForApproval: return the new loan fields to the approver
--      sp_nt_IssueRecurringServicePOCycle: a Statutory agreement (loan) raises no PR / PO / cycle
--      sp_nt_ProcessDueRecurringServiceAgreements: the hourly sweep never picks up a loan
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_SnapshotServiceAgreementVersion', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_SnapshotServiceAgreementVersion;
GO
CREATE PROCEDURE dbo.sp_nt_SnapshotServiceAgreementVersion
    @agreement_sno INT,
    @action_type VARCHAR(20),
    @submitted_by VARCHAR(30),
    @submitted_at DATETIME = NULL,
    @outcome VARCHAR(10) = 'PENDING',
    @note NVARCHAR(300) = NULL,
    @out_version_no INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @terms NVARCHAR(MAX) = (
        SELECT sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
               sa.service_sno, sm.service_name, st.service_type_code, st.service_type_name,
               sa.qty, sa.rate_amount, sa.rate_uom_sno, um.uom_name AS rate_uom_name,
               sa.recurrence_cadence_sno, rc.cadence_name, sa.po_generation_day, sa.notify_days_before,
               sa.period_start_date, sa.period_end_date, sa.agreement_doc_url,
               sa.remarks, sa.terms_conditions, sa.ceiling_amount,
               (
                   SELECT v.vendor_sno, kv.company_name AS vendor_name, v.share_amount, v.share_pct
                   FROM dbo.service_agreement_vendor v
                   LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = v.vendor_sno
                   WHERE v.agreement_sno = sa.agreement_sno
                   ORDER BY v.sort_order, v.agreement_vendor_sno
                   FOR JSON PATH
               ) AS suppliers,
               JSON_QUERY((SELECT s.facility_type, s.facility_ref_no, s.sanctioned_amount, s.drawing_power,
                          s.rate_type, s.benchmark_rate_pct, s.spread_pct, s.interest_rate_pct,
                          s.benchmark_name, s.disbursed_amount, s.disbursement_date, s.interest_payment_day, s.day_count_basis
                   FROM dbo.service_agreement_statutory s
                   WHERE s.agreement_sno = sa.agreement_sno
                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS statutory
        FROM dbo.service_agreement sa
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        LEFT JOIN dbo.uom_master um ON um.uom_sno = sa.rate_uom_sno
        LEFT JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
        WHERE sa.agreement_sno = @agreement_sno
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    IF @terms IS NULL
        THROW 58180, 'Cannot snapshot: agreement not found.', 1;

    DECLARE @version_no INT =
        ISNULL((SELECT MAX(version_no) FROM dbo.service_agreement_version WITH (UPDLOCK, HOLDLOCK) WHERE agreement_sno = @agreement_sno), 0) + 1;

    UPDATE dbo.service_agreement_version
    SET superseded_at = GETDATE()
    WHERE agreement_sno = @agreement_sno AND superseded_at IS NULL;

    INSERT INTO dbo.service_agreement_version (
        agreement_sno, version_no, action_type, outcome, period_start_date, period_end_date,
        terms_json, note, submitted_by, submitted_at
    )
    SELECT @agreement_sno, @version_no, @action_type, @outcome, sa.period_start_date, sa.period_end_date,
           @terms, @note, @submitted_by, ISNULL(@submitted_at, GETDATE())
    FROM dbo.service_agreement sa
    WHERE sa.agreement_sno = @agreement_sno;

    SET @out_version_no = @version_no;
END;
GO

IF OBJECT_ID('dbo.sp_nt_GetServiceAgreements', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceAgreements;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceAgreements
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL, @status CHAR(1) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @com_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        SET @status   = JSON_VALUE(@jsonInput, '$.status');
    END

    SELECT sa.agreement_sno, sa.agreement_no, sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
           sa.service_sno, sm.service_name, st.service_type_code, st.service_type_name,
           sa.vendor_sno, k.company_name AS vendor_name,
           (
               SELECT v.vendor_sno, kv.company_name AS vendor_name, v.share_amount, v.share_pct
               FROM dbo.service_agreement_vendor v
               LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = v.vendor_sno
               WHERE v.agreement_sno = sa.agreement_sno
               ORDER BY v.sort_order, v.agreement_vendor_sno
               FOR JSON PATH
           ) AS vendors_json,
           (SELECT COUNT(*) FROM dbo.service_agreement_vendor v WHERE v.agreement_sno = sa.agreement_sno) AS supplier_count,
           sa.qty, sa.rate_amount, sa.rate_uom_sno, um.uom_name AS rate_uom_name,
           sa.recurrence_cadence_sno, rc.cadence_name, rc.interval_unit, rc.interval_value,
           sa.po_generation_day, sa.notify_days_before,
           sa.period_start_date, sa.period_end_date, sa.agreement_doc_url, sa.remarks, sa.terms_conditions,
           sa.ceiling_amount,
           stt.facility_type, stt.facility_ref_no, stt.sanctioned_amount, stt.drawing_power,
           stt.rate_type, stt.benchmark_rate_pct, stt.spread_pct, stt.interest_rate_pct,
           stt.benchmark_name, stt.disbursed_amount, stt.disbursement_date, stt.interest_payment_day, stt.day_count_basis,
           (SELECT MAX(ver.version_no) FROM dbo.service_agreement_version ver WHERE ver.agreement_sno = sa.agreement_sno) AS version_no,
           (SELECT COUNT(*) FROM dbo.service_agreement_version ver WHERE ver.agreement_sno = sa.agreement_sno AND ver.action_type = 'RENEWED') AS renewal_count,
           sa.current_approver_id, sa.status, sa.created_by, sa.created_at
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = sa.rate_uom_sno
    LEFT JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    LEFT JOIN dbo.service_agreement_statutory stt ON stt.agreement_sno = sa.agreement_sno
    WHERE sa.is_active = 'Y'
      AND (@com_sno IS NULL OR sa.com_sno = @com_sno)
      AND (@div_sno IS NULL OR sa.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR sa.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR sa.dept_sno = @dept_sno)
      AND (@status IS NULL OR sa.status = @status)
    ORDER BY sa.agreement_sno DESC;
END;
GO

IF OBJECT_ID('dbo.sp_nt_GetServiceAgreementsForApproval', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceAgreementsForApproval;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceAgreementsForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT sa.agreement_sno, sa.agreement_no, sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
           sa.service_sno, sm.service_name, st.service_type_code, st.service_type_name,
           sa.vendor_sno, k.company_name AS vendor_name,
           (
               SELECT v.vendor_sno, kv.company_name AS vendor_name, v.share_amount, v.share_pct
               FROM dbo.service_agreement_vendor v
               LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = v.vendor_sno
               WHERE v.agreement_sno = sa.agreement_sno
               ORDER BY v.sort_order, v.agreement_vendor_sno
               FOR JSON PATH
           ) AS vendors_json,
           sa.qty, sa.rate_amount, sa.rate_uom_sno, um.uom_name AS rate_uom_name,
           sa.recurrence_cadence_sno, rc.cadence_name,
           sa.po_generation_day, sa.notify_days_before,
           sa.period_start_date, sa.period_end_date, sa.agreement_doc_url, sa.remarks, sa.terms_conditions,
           sa.ceiling_amount,
           stt.facility_type, stt.facility_ref_no, stt.sanctioned_amount, stt.drawing_power,
           stt.rate_type, stt.benchmark_rate_pct, stt.spread_pct, stt.interest_rate_pct,
           stt.benchmark_name, stt.disbursed_amount, stt.disbursement_date, stt.interest_payment_day, stt.day_count_basis,
           cv.cur_version AS version_no,
           (SELECT ver.action_type FROM dbo.service_agreement_version ver WHERE ver.agreement_sno = sa.agreement_sno AND ver.version_no = cv.cur_version) AS submit_action,
           (SELECT ver.terms_json FROM dbo.service_agreement_version ver WHERE ver.agreement_sno = sa.agreement_sno AND ver.version_no = cv.cur_version - 1) AS prev_terms_json,
           sa.current_approver_id, sa.status, sa.created_by, sa.created_at,
           (
               SELECT ws.stage_order_json
               FROM dbo.workflow_stage ws
               WHERE ws.workflow_types_id = sa.workflow_types_id AND ws.is_active = 'Y'
           ) AS stage_order_json
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = sa.rate_uom_sno
    LEFT JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    LEFT JOIN dbo.service_agreement_statutory stt ON stt.agreement_sno = sa.agreement_sno
    OUTER APPLY (SELECT MAX(ver.version_no) AS cur_version FROM dbo.service_agreement_version ver WHERE ver.agreement_sno = sa.agreement_sno) cv
    WHERE sa.is_active = 'Y' AND sa.status = 'P' AND sa.current_approver_id = @Ecno
    ORDER BY sa.agreement_sno DESC;
END;
GO

IF OBJECT_ID('dbo.sp_nt_IssueRecurringServicePOCycle', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_IssueRecurringServicePOCycle;
GO
CREATE PROCEDURE dbo.sp_nt_IssueRecurringServicePOCycle
    @jsonInput NVARCHAR(MAX),
    @silent BIT = 0,
    @out_result VARCHAR(30) = NULL OUTPUT,
    @out_po_basic_sno INT = NULL OUTPUT,
    @out_po_no VARCHAR(50) = NULL OUTPUT,
    @out_pr_basic_sno INT = NULL OUTPUT,
    @out_pr_no VARCHAR(20) = NULL OUTPUT,
    @out_cycle_sno INT = NULL OUTPUT,
    @out_cycle_status VARCHAR(20) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @agreement_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
    DECLARE @billing_period_start DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.billing_period_start') AS DATE);
    DECLARE @issued_by VARCHAR(20) = ISNULL(JSON_VALUE(@jsonInput, '$.issued_by'), 'SYSTEM');

    -- Captured before any statement that could fail, so the CATCH block can
    -- always tell (a) whether a caller transaction was already open, and
    -- (b) whether THIS proc actually opened a transaction/savepoint of its
    -- own that it is responsible for undoing.
    DECLARE @outer_trancount INT = @@TRANCOUNT;
    DECLARE @own_scope_opened BIT = 0;

    BEGIN TRY
        IF @agreement_sno IS NULL OR @billing_period_start IS NULL
            THROW 58210, 'agreement_sno and billing_period_start are required.', 1;

        IF EXISTS (SELECT 1 FROM dbo.service_agreement_recurring_pr_log WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start)
        BEGIN
            SET @out_result = 'SKIPPED_ALREADY_CLAIMED';
            IF @silent = 0 SELECT @out_result AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start;
            RETURN;
        END

        DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @service_sno INT, @vendor_sno INT,
                @qty DECIMAL(18,4), @rate_amount DECIMAL(18,2), @rate_uom_sno INT, @agreement_no VARCHAR(30),
                @service_name NVARCHAR(150), @agr_status CHAR(1), @period_end DATE, @service_type_code VARCHAR(30);

        SELECT @com_sno = sa.com_sno, @div_sno = sa.div_sno, @brn_sno = sa.brn_sno, @dept_sno = sa.dept_sno,
               @service_sno = sa.service_sno, @vendor_sno = sa.vendor_sno, @qty = sa.qty, @rate_amount = sa.rate_amount,
               @rate_uom_sno = sa.rate_uom_sno, @agreement_no = sa.agreement_no, @agr_status = sa.status,
               @period_end = sa.period_end_date, @service_name = sm.service_name, @service_type_code = st.service_type_code
        FROM dbo.service_agreement sa
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sa.agreement_sno = @agreement_sno;

        IF @agr_status IS NULL THROW 58211, 'Agreement not found.', 1;
        IF @agr_status <> 'A' THROW 58212, 'Agreement is not Approved.', 1;

        -- sql/89: a Statutory agreement is a LOAN. It raises no PR / PO / cycle -- interest
        -- is billed through Bank Payment Vouchers (Loan Payments) instead.
        IF @service_type_code = 'STATUTORY'
        BEGIN
            SET @out_result = 'SKIPPED_STATUTORY';
            IF @silent = 0 SELECT @out_result AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start;
            RETURN;
        END
        IF @billing_period_start > @period_end THROW 58213, 'billing_period_start is past the agreement period_end_date.', 1;

        -- Claim the slot before doing any real work, outside the main
        -- transaction, so it survives a rollback and guarantees idempotency
        -- even under a concurrent sweep.
        INSERT INTO dbo.service_agreement_recurring_pr_log (agreement_sno, billing_period_start, status)
        VALUES (@agreement_sno, @billing_period_start, 'PENDING');

        -- Nestable-safe: reuse the caller's transaction via a savepoint
        -- instead of opening our own when one is already open (see file
        -- header) — a failure below then only undoes this proc's own
        -- work, never the caller's.
        IF @outer_trancount = 0
            BEGIN TRANSACTION;
        ELSE
            SAVE TRANSACTION svp_IssueCycle;
        SET @own_scope_opened = 1;

        DECLARE @default_priority_sno INT;
        SELECT TOP 1 @default_priority_sno = priority_sno
        FROM dbo.priority_master
        WHERE is_active = 'Y'
        ORDER BY CASE WHEN priority_name = 'Medium' THEN 0 ELSE 1 END, priority_sno;
        IF @default_priority_sno IS NULL
            THROW 58214, 'No active priority_master row found to assign to the auto-generated PR.', 1;

        DECLARE @current_year VARCHAR(10) = dbo.fn_GetFinancialYear(GETDATE());
        DECLARE @pr_prefix VARCHAR(20) = 'PR' + @current_year;
        DECLARE @pr_seq INT;
        SELECT @pr_seq = ISNULL(MAX(CASE WHEN pr_no LIKE @pr_prefix + '%' THEN TRY_CAST(SUBSTRING(pr_no, LEN(@pr_prefix) + 1, LEN(pr_no)) AS INT) ELSE 0 END), 0) + 1
        FROM dbo.pr_basic_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE @pr_prefix + '%';
        DECLARE @pr_no VARCHAR(20) = @pr_prefix + RIGHT('0000' + CAST(@pr_seq AS VARCHAR(4)), 4);

        -- Auto-approved: status='A', no workflow — same audit-trail-only PR
        -- as before this file, untouched.
        INSERT INTO dbo.pr_basic_info (
            pr_no, com_sno, div_sno, brn_sno, dept_sno, reg_date, required_date, priority_sno, purpose,
            is_active, created_by, created_date, workflow_types_id, current_approver_id, status
        )
        VALUES (
            @pr_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @billing_period_start, @billing_period_start, @default_priority_sno,
            N'Auto-generated recurring PR — Service Agreement ' + @agreement_no,
            'Y', @issued_by, GETDATE(), NULL, NULL, 'A'
        );
        DECLARE @pr_basic_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.pr_item_details (
            pr_no, pr_basic_sno, prod_sno, qty, unit, est_cost, total_cost, remarks, specification,
            item_type, service_sno, agreement_sno, is_active, created_by, created_date
        )
        VALUES (
            @pr_no, @pr_basic_sno, NULL, @qty, @rate_uom_sno, @rate_amount, @rate_amount * @qty, '', '',
            'service', @service_sno, @agreement_sno, 'Y', @issued_by, GETDATE()
        );

        -- ── Queue a service_po_cycle instead of issuing the PO directly.
        --    Fixed: nothing to enter, straight to Pending Approval with the
        --    agreement's already-agreed rate/qty. Unfixed: Pending Entry,
        --    rate resolved later by sp_nt_SubmitServicePoEntry. ───────────
        DECLARE @cycle_status VARCHAR(20), @cycle_workflow_types_id INT = NULL, @cycle_approver VARCHAR(30) = NULL,
                @cycle_rate DECIMAL(18,2) = NULL, @cycle_net_cost DECIMAL(18,2) = NULL;

        IF @service_type_code = 'FIXED_RECURRING'
        BEGIN
            SET @cycle_status = 'PENDING_APPROVAL';
            SET @cycle_rate = @rate_amount;
            SET @cycle_net_cost = @rate_amount * @qty;
            EXEC dbo.sp_nt_ResolveServicePoWorkflow
                @com_sno = @com_sno, @div_sno = @div_sno, @brn_sno = @brn_sno, @dept_sno = @dept_sno,
                @workflow_types_id = @cycle_workflow_types_id OUTPUT, @first_approver = @cycle_approver OUTPUT;
        END
        ELSE
            SET @cycle_status = 'PENDING_ENTRY';

        INSERT INTO dbo.service_po_cycle (
            agreement_sno, com_sno, div_sno, brn_sno, dept_sno, billing_period_start,
            pr_basic_sno, pr_no, qty, rate_amount, net_cost, status,
            workflow_types_id, current_approver_id
        )
        VALUES (
            @agreement_sno, @com_sno, @div_sno, @brn_sno, @dept_sno, @billing_period_start,
            @pr_basic_sno, @pr_no, @qty, @cycle_rate, @cycle_net_cost, @cycle_status,
            @cycle_workflow_types_id, @cycle_approver
        );
        DECLARE @cycle_sno INT = SCOPE_IDENTITY();

        -- sql/88: a Fixed cycle already knows its rate, so split it across the
        -- agreement's suppliers now (Unfixed/Statutory do this when the rate is entered).
        IF @cycle_status = 'PENDING_APPROVAL'
        BEGIN
            DECLARE @split_net DECIMAL(18,2);
            EXEC dbo.sp_nt_BuildServicePoCycleSplit
                @cycle_sno = @cycle_sno, @agreement_sno = @agreement_sno, @rate_amount = @rate_amount, @qty = @qty,
                @discount_pct = 0, @gst_pct = 0, @out_net_cost = @split_net OUTPUT;
            UPDATE dbo.service_po_cycle SET net_cost = @split_net WHERE cycle_sno = @cycle_sno;
        END

        INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
        VALUES (@cycle_sno, 'CYCLE_CREATED', @issued_by,
                CASE WHEN @cycle_status = 'PENDING_APPROVAL' THEN N'Fixed agreement — queued directly for approval.' ELSE N'Unfixed agreement — awaiting rate/GST entry.' END);

        UPDATE dbo.service_agreement_recurring_pr_log
        SET status = 'CREATED', pr_basic_sno = @pr_basic_sno, pr_no = @pr_no, modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start;

        IF @outer_trancount = 0
            COMMIT TRANSACTION;

        SET @out_result = 'SUCCESS';
        SET @out_pr_basic_sno = @pr_basic_sno;
        SET @out_pr_no = @pr_no;
        SET @out_cycle_sno = @cycle_sno;
        SET @out_cycle_status = @cycle_status;

        IF @silent = 0
            SELECT 'SUCCESS' AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start,
                   @pr_basic_sno AS pr_basic_sno, @pr_no AS pr_no, @cycle_sno AS cycle_sno, @cycle_status AS cycle_status;
    END TRY
    BEGIN CATCH
        IF @own_scope_opened = 1 AND XACT_STATE() <> 0
        BEGIN
            IF @outer_trancount = 0 OR XACT_STATE() = -1
                ROLLBACK TRANSACTION;
            ELSE
                ROLLBACK TRANSACTION svp_IssueCycle;
        END

        UPDATE dbo.service_agreement_recurring_pr_log
        SET status = 'FAILED', error_message = ERROR_MESSAGE(), modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start AND status = 'PENDING';

        SET @out_result = 'ERROR';
        IF @silent = 0 THROW;
    END CATCH
END;
GO

IF OBJECT_ID('dbo.sp_nt_ProcessDueRecurringServiceAgreements', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ProcessDueRecurringServiceAgreements;
GO
CREATE PROCEDURE dbo.sp_nt_ProcessDueRecurringServiceAgreements
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @due TABLE (agreement_sno INT, billing_period_start DATE);

    INSERT INTO @due (agreement_sno, billing_period_start)
    SELECT sa.agreement_sno, @today
    FROM dbo.service_agreement sa
    JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    WHERE sa.status = 'A' AND sa.is_active = 'Y'
      -- sql/89: loans (Statutory) are billed through Bank Payment Vouchers, never PO cycles
      AND NOT EXISTS (SELECT 1 FROM dbo.service_master smx JOIN dbo.service_type_master stx ON stx.service_type_sno = smx.service_type_sno
                      WHERE smx.service_sno = sa.service_sno AND stx.service_type_code = 'STATUTORY')
      AND @today BETWEEN sa.period_start_date AND sa.period_end_date
      AND (
            (rc.interval_unit = 'DAY' AND DATEDIFF(DAY, sa.period_start_date, @today) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NOT NULL
             AND DAY(@today) = CASE WHEN sa.po_generation_day > DAY(EOMONTH(@today)) THEN DAY(EOMONTH(@today)) ELSE sa.po_generation_day END
             AND DATEDIFF(MONTH, sa.period_start_date, @today) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NULL
             AND DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, @today) / rc.interval_value) * rc.interval_value, sa.period_start_date) = @today)
          )
      AND NOT EXISTS (SELECT 1 FROM dbo.service_agreement_recurring_pr_log l WHERE l.agreement_sno = sa.agreement_sno AND l.billing_period_start = @today);

    DECLARE @agreement_sno INT, @billing_period_start DATE;
    DECLARE @success_count INT = 0, @skipped_count INT = 0, @failed_count INT = 0;
    DECLARE @row_result VARCHAR(30), @row_po INT, @row_po_no VARCHAR(50), @row_pr INT, @row_pr_no VARCHAR(20), @rowJson NVARCHAR(MAX);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT agreement_sno, billing_period_start FROM @due;
    OPEN cur;
    FETCH NEXT FROM cur INTO @agreement_sno, @billing_period_start;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @rowJson = (SELECT @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start, 'SYSTEM' AS issued_by FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.sp_nt_IssueRecurringServicePOCycle
            @jsonInput = @rowJson, @silent = 1,
            @out_result = @row_result OUTPUT, @out_po_basic_sno = @row_po OUTPUT, @out_po_no = @row_po_no OUTPUT,
            @out_pr_basic_sno = @row_pr OUTPUT, @out_pr_no = @row_pr_no OUTPUT;

        IF @row_result = 'SUCCESS' SET @success_count = @success_count + 1;
        ELSE IF @row_result LIKE 'SKIPPED%' SET @skipped_count = @skipped_count + 1;
        ELSE SET @failed_count = @failed_count + 1;

        FETCH NEXT FROM cur INTO @agreement_sno, @billing_period_start;
    END
    CLOSE cur;
    DEALLOCATE cur;

    SELECT (SELECT COUNT(*) FROM @due) AS due_count, @success_count AS success_count, @skipped_count AS skipped_count, @failed_count AS failed_count;
END;
GO

-- ============================================================
-- 7) Loan helpers: billed-through / locked-through dates
--    billed_through = where the next voucher starts (end of the last
--                     APPROVED / PAID voucher, else the disbursement date)
--    locked_through = also counts a voucher still awaiting approval; rates
--                     and principal movements dated before it can't change.
-- ============================================================
IF OBJECT_ID('dbo.fn_LoanBilledThrough', 'FN') IS NOT NULL DROP FUNCTION dbo.fn_LoanBilledThrough;
IF OBJECT_ID('dbo.fn_LoanLockedThrough', 'FN') IS NOT NULL DROP FUNCTION dbo.fn_LoanLockedThrough;
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

-- ============================================================
-- 8) sp_nt_ResolveBankVoucherWorkflow — workflow lookup for 'BankPaymentVoucher'
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ResolveBankVoucherWorkflow', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ResolveBankVoucherWorkflow;
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

-- ============================================================
-- 9) sp_nt_CalcLoanVoucher — the interest engine, shared by the preview and
--    by voucher creation so both always agree. Read-only. THROWs a clear
--    message for anything that makes a voucher invalid.
--    Interest for [period_from, period_to) — the payment date starts the
--    NEXT period. period_from = where the last approved/paid voucher ended
--    (else the disbursement date). No @payment_date = the next scheduled
--    interest date after period_from (payment day of the month).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CalcLoanVoucher', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CalcLoanVoucher;
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

-- ============================================================
-- 10) sp_nt_PreviewLoanInterest — what a voucher would look like. Read-only.
--     @jsonInput: { agreement_sno, payment_date?, principal_repayment? }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_PreviewLoanInterest', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_PreviewLoanInterest;
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

-- ============================================================
-- 11) sp_nt_CreateBankPaymentVoucher
--     @jsonInput: { agreement_sno, payment_date?, principal_repayment?, remarks?, created_by }
--     Recomputes everything server-side (the client only proposes the date and
--     the repayment) and sends the voucher into the BankPaymentVoucher workflow.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateBankPaymentVoucher', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateBankPaymentVoucher;
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

-- ============================================================
-- 12) sp_nt_ApproveBankPaymentVoucher
--     @jsonInput: { voucher_sno, approved_by, action: approve|reject, comments? }
--     Only the voucher's CURRENT approver can act. The stage list is read from
--     the workflow itself (never trusted from the client). Final approval with
--     a principal repayment writes the repayment into loan_principal_txn, dated
--     on the payment date, so the next voucher starts from the reduced balance.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ApproveBankPaymentVoucher', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ApproveBankPaymentVoucher;
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

-- ============================================================
-- 13) sp_nt_MarkBankPaymentVoucherPaid — record the bank payment once an
--     approved voucher has actually been paid.
--     @jsonInput: { voucher_sno, paid_on, payment_mode, payment_ref_no?, paid_from_bank?, paid_by, remarks? }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_MarkBankPaymentVoucherPaid', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_MarkBankPaymentVoucherPaid;
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

-- ============================================================
-- 14) Rate history + principal movements
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_AddLoanRatePeriod', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_AddLoanRatePeriod;
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

IF OBJECT_ID('dbo.sp_nt_DeleteLoanRatePeriod', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_DeleteLoanRatePeriod;
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

IF OBJECT_ID('dbo.sp_nt_AddLoanPrincipalTxn', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_AddLoanPrincipalTxn;
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

IF OBJECT_ID('dbo.sp_nt_DeleteLoanPrincipalTxn', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_DeleteLoanPrincipalTxn;
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

-- ============================================================
-- 15) Read procs
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetLoanAccounts', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetLoanAccounts;
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

IF OBJECT_ID('dbo.sp_nt_GetLoanDetail', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetLoanDetail;
GO
-- One loan's history as JSON columns (parsed by the Node service):
--   rates_json     sanctioned rate + every entered rate, each with its end date
--   txns_json      opening disbursement + every principal movement, with a running balance
--   vouchers_json  the loan's bank payment vouchers, newest first
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
           ) AS vouchers_json;
END;
GO

IF OBJECT_ID('dbo.sp_nt_GetBankPaymentVouchers', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetBankPaymentVouchers;
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

IF OBJECT_ID('dbo.sp_nt_GetBankPaymentVoucher', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetBankPaymentVoucher;
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

IF OBJECT_ID('dbo.sp_nt_GetBankPaymentVouchersForApproval', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetBankPaymentVouchersForApproval;
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
