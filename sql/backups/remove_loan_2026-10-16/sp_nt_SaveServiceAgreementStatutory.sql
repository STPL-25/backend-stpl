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