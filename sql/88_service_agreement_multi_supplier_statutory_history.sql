-- ============================================================
-- Service Agreement: multi-supplier split, Statutory type, version history
-- and renewal of expired agreements
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Context
-- -------
-- Three asks, one migration, because they all touch the same procs:
--
-- 1) MULTIPLE SUPPLIERS PER AGREEMENT. One agreement (e.g. rent, 50,000 per
--    month) can now be split across several suppliers by amount
--    (10,000 / 20,000 / 20,000). service_agreement_vendor holds the split;
--    service_agreement.vendor_sno stays as the PRIMARY (first) supplier so
--    every existing join/report keeps working unchanged. Each supplier's
--    share is stored both as an amount (what the user typed, must add up to
--    rate x qty) and as a percentage (used to apportion an Unfixed /
--    Statutory cycle's entered amount, which differs every cycle).
--    At cycle time the cycle is split into service_po_cycle_vendor rows and,
--    on final approval, ONE PO IS RAISED PER SUPPLIER for that supplier's
--    share (sp_nt_ApproveServicePoCycle). The last supplier absorbs
--    rounding so unit prices always add up exactly to the entered rate.
--
-- 2) STATUTORY agreement type (loans / repo / cash credit). A third
--    service_type_master row ('STATUTORY') next to Fixed and Unfixed, so it
--    shares the agreement screens, ServiceAgreement approval workflow and
--    recurring engine. Its per-cycle amount changes every time (interest /
--    EMI resets), so it behaves like Unfixed at cycle time (Pending Entry ->
--    Pending Approval -> PO) -- that branch in sp_nt_IssueRecurringServicePOCycle
--    is "anything that isn't FIXED_RECURRING", so no change was needed there.
--    The facility itself (type, sanctioned amount / CC limit, rate type
--    fixed-vs-floating, repo benchmark + spread, effective interest rate,
--    drawing power) lives in service_agreement_statutory (1:1).
--
-- 3) VERSION HISTORY + RENEWAL. Editing an agreement used to overwrite the
--    row in place, so the previous terms were gone; an Expired agreement
--    could not be resubmitted at all. Now every submit / resubmit / renewal
--    snapshots the full terms (incl. suppliers + statutory block) into
--    service_agreement_version, and sp_nt_UpdateServiceAgreement accepts an
--    Expired agreement (status 'X') as a RENEWAL: same agreement_no, new
--    version, goes back through the ServiceAgreement approval workflow.
--    sp_nt_GetServiceAgreementHistory returns every version with its
--    approval trail and every cycle/PO raised, for the "History" view.
--
-- Existing data is backfilled: every agreement gets a 100% supplier row, a
-- version 1 snapshot (flagged as taken at migration time -- earlier in-place
-- edits can't be reconstructed) and every already-costed cycle gets a 100%
-- supplier split row.
--
-- Idempotent throughout (IF NOT EXISTS / DROP+CREATE). Safe to re-run.
-- Applied by hand against 10.0.21.8 (no migration runner in this repo):
--   cd backend-stpl && node sql/run_sql.mjs sql/88_service_agreement_multi_supplier_statutory_history.sql
-- ============================================================

-- ============================================================
-- 1) Statutory service type + starter services
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.service_type_master WHERE service_type_code = 'STATUTORY')
    INSERT INTO dbo.service_type_master (service_type_code, service_type_name, is_active, created_by)
    VALUES (N'STATUTORY', N'Statutory', 'Y', N'system');
GO

DECLARE @stat_type_sno INT = (SELECT service_type_sno FROM dbo.service_type_master WHERE service_type_code = 'STATUTORY');

IF NOT EXISTS (SELECT 1 FROM dbo.service_master WHERE service_code = 'STAT-LOAN')
    INSERT INTO dbo.service_master (service_name, service_code, service_type_sno, description, is_active, created_by)
    VALUES (N'Term Loan Repayment', 'STAT-LOAN', @stat_type_sno, N'Loan EMI / principal and interest instalments', 'Y', N'system');
IF NOT EXISTS (SELECT 1 FROM dbo.service_master WHERE service_code = 'STAT-REPO')
    INSERT INTO dbo.service_master (service_name, service_code, service_type_sno, description, is_active, created_by)
    VALUES (N'Repo Facility Payment', 'STAT-REPO', @stat_type_sno, N'Repo-linked facility interest / settlement', 'Y', N'system');
IF NOT EXISTS (SELECT 1 FROM dbo.service_master WHERE service_code = 'STAT-CC')
    INSERT INTO dbo.service_master (service_name, service_code, service_type_sno, description, is_active, created_by)
    VALUES (N'Cash Credit Interest', 'STAT-CC', @stat_type_sno, N'Interest on cash credit / overdraft utilisation', 'Y', N'system');
GO

-- ============================================================
-- 2) Tables
-- ============================================================
IF OBJECT_ID('dbo.service_agreement_vendor', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_agreement_vendor (
        agreement_vendor_sno INT IDENTITY(1,1) PRIMARY KEY,
        agreement_sno        INT           NOT NULL,
        vendor_sno           INT           NOT NULL,
        share_amount         DECIMAL(18,2) NOT NULL,  -- as entered; all rows sum to rate x qty
        share_pct            DECIMAL(9,6)  NOT NULL,  -- derived, used to apportion variable cycles
        sort_order           SMALLINT      NOT NULL DEFAULT 1, -- 1 = primary supplier
        created_at           DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_service_agreement_vendor_agreement FOREIGN KEY (agreement_sno) REFERENCES dbo.service_agreement (agreement_sno),
        CONSTRAINT UQ_service_agreement_vendor UNIQUE (agreement_sno, vendor_sno),
        CONSTRAINT CK_service_agreement_vendor_share CHECK (share_amount > 0 AND share_pct > 0 AND share_pct <= 100)
    );
END;
GO

IF OBJECT_ID('dbo.service_agreement_statutory', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_agreement_statutory (
        agreement_sno      INT           NOT NULL PRIMARY KEY,
        facility_type      VARCHAR(15)   NOT NULL,  -- LOAN | REPO | CASH_CREDIT
        facility_ref_no    NVARCHAR(100) NULL,      -- loan a/c no, sanction ref, CC a/c no
        sanctioned_amount  DECIMAL(18,2) NOT NULL,  -- loan principal / CC limit / repo amount
        drawing_power      DECIMAL(18,2) NULL,      -- cash credit only
        rate_type          VARCHAR(10)   NOT NULL,  -- FIXED | FLOATING (benchmark-linked, e.g. repo rate + spread)
        benchmark_rate_pct DECIMAL(7,3)  NULL,      -- FLOATING only
        spread_pct         DECIMAL(7,3)  NULL,      -- FLOATING only
        interest_rate_pct  DECIMAL(7,3)  NOT NULL,  -- effective rate (= benchmark + spread when FLOATING)
        modified_at        DATETIME      NULL,
        CONSTRAINT FK_service_agreement_statutory_agreement FOREIGN KEY (agreement_sno) REFERENCES dbo.service_agreement (agreement_sno),
        CONSTRAINT CK_service_agreement_statutory_facility CHECK (facility_type IN ('LOAN', 'REPO', 'CASH_CREDIT')),
        CONSTRAINT CK_service_agreement_statutory_rate_type CHECK (rate_type IN ('FIXED', 'FLOATING')),
        CONSTRAINT CK_service_agreement_statutory_amount CHECK (sanctioned_amount > 0),
        CONSTRAINT CK_service_agreement_statutory_interest CHECK (interest_rate_pct >= 0 AND interest_rate_pct <= 100)
    );
END;
GO

IF OBJECT_ID('dbo.service_agreement_version', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_agreement_version (
        version_sno       INT IDENTITY(1,1) PRIMARY KEY,
        agreement_sno     INT           NOT NULL,
        version_no        INT           NOT NULL,
        action_type       VARCHAR(20)   NOT NULL,                 -- SUBMITTED | RESUBMITTED | RENEWED
        outcome           VARCHAR(10)   NOT NULL DEFAULT 'PENDING', -- PENDING | APPROVED | REJECTED | EXPIRED
        period_start_date DATE          NOT NULL,
        period_end_date   DATE          NOT NULL,
        terms_json        NVARCHAR(MAX) NOT NULL,                 -- full terms incl. suppliers[] and statutory{}
        note              NVARCHAR(300) NULL,
        submitted_by      VARCHAR(30)   NULL,
        submitted_at      DATETIME      NOT NULL DEFAULT GETDATE(),
        decided_at        DATETIME      NULL,
        superseded_at     DATETIME      NULL,                     -- set when a later version is created
        CONSTRAINT FK_service_agreement_version_agreement FOREIGN KEY (agreement_sno) REFERENCES dbo.service_agreement (agreement_sno),
        CONSTRAINT UQ_service_agreement_version UNIQUE (agreement_sno, version_no),
        CONSTRAINT CK_service_agreement_version_outcome CHECK (outcome IN ('PENDING', 'APPROVED', 'REJECTED', 'EXPIRED')),
        CONSTRAINT CK_service_agreement_version_json CHECK (ISJSON(terms_json) = 1)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_agreement_history') AND name = 'version_no')
    ALTER TABLE dbo.service_agreement_history ADD version_no INT NULL;
GO

IF OBJECT_ID('dbo.service_po_cycle_vendor', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_po_cycle_vendor (
        cycle_vendor_sno INT IDENTITY(1,1) PRIMARY KEY,
        cycle_sno        INT           NOT NULL,
        vendor_sno       INT           NOT NULL,
        share_pct        DECIMAL(9,6)  NOT NULL,
        rate_amount      DECIMAL(18,2) NOT NULL,  -- this supplier's unit rate for the cycle
        net_cost         DECIMAL(18,2) NOT NULL,  -- after discount + GST
        po_basic_sno     INT           NULL,      -- the PO raised for this supplier on final approval
        created_at       DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_service_po_cycle_vendor_cycle FOREIGN KEY (cycle_sno) REFERENCES dbo.service_po_cycle (cycle_sno),
        CONSTRAINT FK_service_po_cycle_vendor_po FOREIGN KEY (po_basic_sno) REFERENCES dbo.po_request_info (po_basic_sno),
        CONSTRAINT UQ_service_po_cycle_vendor UNIQUE (cycle_sno, vendor_sno)
    );
END;
GO

-- ============================================================
-- 3) Helper: sp_nt_SaveServiceAgreementSuppliers
--    Validates + replaces the supplier split for an agreement. Called from
--    inside the caller's transaction (no transaction of its own, so a THROW
--    here rolls back the whole create/update).
--    @vendors_json: [{ "vendor_sno": 96, "share_amount": 10000 }, ...]
--    Falls back to a single 100% supplier when no array is given and
--    @fallback_vendor_sno is (legacy single-supplier clients).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_SaveServiceAgreementSuppliers', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_SaveServiceAgreementSuppliers;
GO
CREATE PROCEDURE dbo.sp_nt_SaveServiceAgreementSuppliers
    @agreement_sno INT,
    @vendors_json NVARCHAR(MAX),
    @fallback_vendor_sno INT,
    @total_amount DECIMAL(18,2),
    @out_primary_vendor_sno INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @parsed TABLE (ord INT NOT NULL, vendor_sno INT NULL, share_amount DECIMAL(18,2) NULL);

    IF @vendors_json IS NOT NULL AND ISJSON(@vendors_json) = 1 AND LEFT(LTRIM(@vendors_json), 1) = '['
        INSERT INTO @parsed (ord, vendor_sno, share_amount)
        SELECT CAST(j.[key] AS INT) + 1,
               TRY_CAST(JSON_VALUE(j.[value], '$.vendor_sno') AS INT),
               TRY_CAST(JSON_VALUE(j.[value], '$.share_amount') AS DECIMAL(18,2))
        FROM OPENJSON(@vendors_json) AS j;

    IF NOT EXISTS (SELECT 1 FROM @parsed) AND @fallback_vendor_sno IS NOT NULL
        INSERT INTO @parsed (ord, vendor_sno, share_amount) VALUES (1, @fallback_vendor_sno, @total_amount);

    IF NOT EXISTS (SELECT 1 FROM @parsed)
        THROW 58150, 'At least one supplier is required.', 1;
    IF EXISTS (SELECT 1 FROM @parsed WHERE vendor_sno IS NULL OR share_amount IS NULL OR share_amount <= 0)
        THROW 58151, 'Every supplier needs a vendor and a share amount greater than zero.', 1;
    IF EXISTS (SELECT vendor_sno FROM @parsed GROUP BY vendor_sno HAVING COUNT(*) > 1)
        THROW 58152, 'The same supplier is listed more than once in the split.', 1;
    IF EXISTS (
        SELECT 1 FROM @parsed p
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.kyc_basic_info k
            WHERE k.kyc_basic_info_sno = p.vendor_sno AND k.status = 'A' AND k.is_active = 'Y'
        )
    )
        THROW 58153, 'One or more suppliers are not approved, active vendors.', 1;

    DECLARE @sum DECIMAL(18,2) = (SELECT SUM(share_amount) FROM @parsed);
    IF ABS(@sum - @total_amount) > 0.01
    BEGIN
        DECLARE @msg NVARCHAR(400) =
            N'Supplier shares total ' + CONVERT(NVARCHAR(30), @sum) +
            N' but the amount per cycle (rate x quantity) is ' + CONVERT(NVARCHAR(30), @total_amount) +
            N'. The shares must add up exactly.';
        THROW 58154, @msg, 1;
    END

    DELETE FROM dbo.service_agreement_vendor WHERE agreement_sno = @agreement_sno;

    INSERT INTO dbo.service_agreement_vendor (agreement_sno, vendor_sno, share_amount, share_pct, sort_order)
    SELECT @agreement_sno, vendor_sno, share_amount, ROUND(share_amount * 100.0 / @total_amount, 6), ord
    FROM @parsed
    ORDER BY ord;

    SELECT TOP 1 @out_primary_vendor_sno = vendor_sno FROM @parsed ORDER BY ord;
END;
GO

-- ============================================================
-- 4) Helper: sp_nt_SaveServiceAgreementStatutory
--    Upserts the facility block for a Statutory agreement, deletes it for
--    any other type (a service change from Statutory to something else must
--    not leave a stale facility row behind).
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
        THROW 58160, 'Facility details (type, sanctioned amount, interest rate) are required for a Statutory agreement.', 1;

    DECLARE @facility_type   VARCHAR(15)   = UPPER(LTRIM(RTRIM(JSON_VALUE(@statutory_json, '$.facility_type')))),
            @facility_ref_no NVARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@statutory_json, '$.facility_ref_no'))), ''),
            @sanctioned      DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@statutory_json, '$.sanctioned_amount') AS DECIMAL(18,2)),
            @drawing_power   DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@statutory_json, '$.drawing_power') AS DECIMAL(18,2)),
            @rate_type       VARCHAR(10)   = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(JSON_VALUE(@statutory_json, '$.rate_type'))), ''), 'FIXED')),
            @benchmark       DECIMAL(7,3)  = TRY_CAST(JSON_VALUE(@statutory_json, '$.benchmark_rate_pct') AS DECIMAL(7,3)),
            @spread          DECIMAL(7,3)  = TRY_CAST(JSON_VALUE(@statutory_json, '$.spread_pct') AS DECIMAL(7,3)),
            @interest        DECIMAL(7,3)  = TRY_CAST(JSON_VALUE(@statutory_json, '$.interest_rate_pct') AS DECIMAL(7,3));

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
    END
    ELSE
    BEGIN
        IF @interest IS NULL
            THROW 58165, 'interest_rate_pct is required for a fixed-rate facility.', 1;
        SET @benchmark = NULL;
        SET @spread = NULL;
    END

    IF @interest < 0 OR @interest > 100
        THROW 58166, 'The effective interest rate must be between 0 and 100 percent.', 1;

    IF @facility_type <> 'CASH_CREDIT'
        SET @drawing_power = NULL;
    ELSE IF @drawing_power IS NOT NULL AND (@drawing_power <= 0 OR @drawing_power > @sanctioned)
        THROW 58167, 'drawing_power must be positive and not more than the sanctioned limit.', 1;

    UPDATE dbo.service_agreement_statutory
    SET facility_type = @facility_type, facility_ref_no = @facility_ref_no, sanctioned_amount = @sanctioned,
        drawing_power = @drawing_power, rate_type = @rate_type, benchmark_rate_pct = @benchmark,
        spread_pct = @spread, interest_rate_pct = @interest, modified_at = GETDATE()
    WHERE agreement_sno = @agreement_sno;

    IF @@ROWCOUNT = 0
        INSERT INTO dbo.service_agreement_statutory (
            agreement_sno, facility_type, facility_ref_no, sanctioned_amount, drawing_power,
            rate_type, benchmark_rate_pct, spread_pct, interest_rate_pct
        )
        VALUES (
            @agreement_sno, @facility_type, @facility_ref_no, @sanctioned, @drawing_power,
            @rate_type, @benchmark, @spread, @interest
        );
END;
GO

-- ============================================================
-- 5) Helper: sp_nt_SnapshotServiceAgreementVersion
--    Freezes the agreement's CURRENT row + suppliers + facility block as the
--    next version. Called after the row has been written, inside the same
--    transaction. Marks the previous version superseded.
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
               (
                   SELECT s.facility_type, s.facility_ref_no, s.sanctioned_amount, s.drawing_power,
                          s.rate_type, s.benchmark_rate_pct, s.spread_pct, s.interest_rate_pct
                   FROM dbo.service_agreement_statutory s
                   WHERE s.agreement_sno = sa.agreement_sno
                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
               ) AS statutory
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

-- ============================================================
-- 6) Helper: sp_nt_BuildServicePoCycleSplit
--    Materialises how one cycle's entered rate is split across the
--    agreement's suppliers (service_po_cycle_vendor), and returns the summed
--    net cost so the cycle's own net_cost always equals the sum of what each
--    supplier's PO will be for. Unit price per supplier = rate x share%;
--    the LAST supplier takes the remainder so unit prices add up exactly.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_BuildServicePoCycleSplit', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_BuildServicePoCycleSplit;
GO
CREATE PROCEDURE dbo.sp_nt_BuildServicePoCycleSplit
    @cycle_sno INT,
    @agreement_sno INT,
    @rate_amount DECIMAL(18,2),
    @qty DECIMAL(18,4),
    @discount_pct DECIMAL(5,2),
    @gst_pct DECIMAL(5,2),
    @out_net_cost DECIMAL(18,2) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.service_po_cycle_vendor WHERE cycle_sno = @cycle_sno;

    INSERT INTO dbo.service_po_cycle_vendor (cycle_sno, vendor_sno, share_pct, rate_amount, net_cost)
    SELECT @cycle_sno, v.vendor_sno, v.share_pct, ROUND(@rate_amount * v.share_pct / 100.0, 2), 0
    FROM dbo.service_agreement_vendor v
    WHERE v.agreement_sno = @agreement_sno
    ORDER BY v.sort_order, v.agreement_vendor_sno;

    IF NOT EXISTS (SELECT 1 FROM dbo.service_po_cycle_vendor WHERE cycle_sno = @cycle_sno)
        THROW 58170, 'This agreement has no suppliers configured, so the cycle cannot be split.', 1;

    DECLARE @last_sno INT = (SELECT MAX(cycle_vendor_sno) FROM dbo.service_po_cycle_vendor WHERE cycle_sno = @cycle_sno);

    UPDATE dbo.service_po_cycle_vendor
    SET rate_amount = @rate_amount - ISNULL((
            SELECT SUM(x.rate_amount) FROM dbo.service_po_cycle_vendor x
            WHERE x.cycle_sno = @cycle_sno AND x.cycle_vendor_sno <> @last_sno
        ), 0)
    WHERE cycle_vendor_sno = @last_sno;

    UPDATE dbo.service_po_cycle_vendor
    SET net_cost = ROUND(rate_amount * @qty * (1 - @discount_pct / 100.0) * (1 + @gst_pct / 100.0), 2)
    WHERE cycle_sno = @cycle_sno;

    SELECT @out_net_cost = SUM(net_cost) FROM dbo.service_po_cycle_vendor WHERE cycle_sno = @cycle_sno;
END;
GO

-- ============================================================
-- 7) Backfill existing data (each step is a no-op once done)
-- ============================================================
INSERT INTO dbo.service_agreement_vendor (agreement_sno, vendor_sno, share_amount, share_pct, sort_order)
SELECT sa.agreement_sno, sa.vendor_sno, ROUND(sa.rate_amount * sa.qty, 2), 100, 1
FROM dbo.service_agreement sa
WHERE NOT EXISTS (SELECT 1 FROM dbo.service_agreement_vendor v WHERE v.agreement_sno = sa.agreement_sno);
GO

DECLARE @bf_agreement INT, @bf_status CHAR(1), @bf_created_by VARCHAR(20), @bf_created_at DATETIME, @bf_outcome VARCHAR(10), @bf_version INT;
DECLARE bf_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT sa.agreement_sno, sa.status, sa.created_by, sa.created_at
    FROM dbo.service_agreement sa
    WHERE NOT EXISTS (SELECT 1 FROM dbo.service_agreement_version ver WHERE ver.agreement_sno = sa.agreement_sno)
    ORDER BY sa.agreement_sno;
OPEN bf_cur;
FETCH NEXT FROM bf_cur INTO @bf_agreement, @bf_status, @bf_created_by, @bf_created_at;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @bf_outcome = CASE @bf_status WHEN 'A' THEN 'APPROVED' WHEN 'R' THEN 'REJECTED' WHEN 'X' THEN 'EXPIRED' ELSE 'PENDING' END;
    EXEC dbo.sp_nt_SnapshotServiceAgreementVersion
        @agreement_sno = @bf_agreement, @action_type = 'SUBMITTED', @submitted_by = @bf_created_by,
        @submitted_at = @bf_created_at, @outcome = @bf_outcome,
        @note = N'Snapshot taken when version history was introduced - earlier in-place edits are not itemised.',
        @out_version_no = @bf_version OUTPUT;

    UPDATE dbo.service_agreement_version
    SET decided_at = (
            SELECT MAX(h.created_at) FROM dbo.service_agreement_history h
            WHERE h.agreement_sno = @bf_agreement AND h.action_type IN ('APPROVED', 'REJECTED', 'EXPIRED')
        )
    WHERE agreement_sno = @bf_agreement AND version_no = @bf_version AND outcome <> 'PENDING';

    FETCH NEXT FROM bf_cur INTO @bf_agreement, @bf_status, @bf_created_by, @bf_created_at;
END
CLOSE bf_cur;
DEALLOCATE bf_cur;
GO

UPDATE dbo.service_agreement_history SET version_no = 1 WHERE version_no IS NULL;
GO

INSERT INTO dbo.service_po_cycle_vendor (cycle_sno, vendor_sno, share_pct, rate_amount, net_cost, po_basic_sno)
SELECT c.cycle_sno, sa.vendor_sno, 100, c.rate_amount, ISNULL(c.net_cost, c.rate_amount * c.qty), c.po_basic_sno
FROM dbo.service_po_cycle c
JOIN dbo.service_agreement sa ON sa.agreement_sno = c.agreement_sno
WHERE c.rate_amount IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.service_po_cycle_vendor cv WHERE cv.cycle_sno = c.cycle_sno);
GO

-- ============================================================
-- 8) sp_nt_CreateServiceAgreement
--    Changes vs sql/83: accepts vendors[] (supplier split) and statutory{}
--    (facility block), accepts the STATUTORY service type, writes the
--    version-1 snapshot. vendor_sno is now the PRIMARY (first) supplier.
-- @jsonInput: { com_sno, div_sno, brn_sno, dept_sno, service_sno,
--   vendors: [{vendor_sno, share_amount}], (legacy: vendor_sno),
--   qty, rate_amount, rate_uom_sno?, recurrence_cadence_sno, po_generation_day?,
--   notify_days_before?, period_start_date, period_end_date, agreement_doc_url,
--   remarks?, terms_conditions?, ceiling_amount?, statutory?: {...}, created_by }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateServiceAgreement', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateServiceAgreement;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @com_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @service_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @vendor_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @qty                DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4));
        DECLARE @rate_amount        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @rate_uom_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_uom_sno') AS INT);
        DECLARE @recurrence_cadence_sno INT       = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_cadence_sno') AS INT);
        DECLARE @po_generation_day  SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_generation_day') AS SMALLINT);
        DECLARE @notify_days_before SMALLINT      = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.notify_days_before') AS SMALLINT), 0);
        DECLARE @period_start_date  DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url  NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @terms_conditions   NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.terms_conditions');
        DECLARE @ceiling_amount     DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @created_by         VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
        DECLARE @vendors_json       NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.vendors');
        DECLARE @statutory_json     NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.statutory');

        -- The first supplier in the split is the primary (service_agreement.vendor_sno).
        IF @vendors_json IS NOT NULL AND ISJSON(@vendors_json) = 1
            SET @vendor_sno = ISNULL(TRY_CAST(JSON_VALUE(@vendors_json, '$[0].vendor_sno') AS INT), @vendor_sno);

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @service_sno IS NULL OR @vendor_sno IS NULL OR @created_by IS NULL
            THROW 58101, 'com_sno, div_sno, brn_sno, dept_sno, service_sno, at least one supplier and created_by are required.', 1;

        IF @qty IS NULL OR @qty <= 0
            THROW 58102, 'qty must be a positive quantity.', 1;

        IF @rate_amount IS NULL OR @rate_amount <= 0
            THROW 58103, 'rate_amount must be a positive amount (an approximate value is fine for an Unfixed or Statutory agreement).', 1;

        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 58104, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;

        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 58105, 'agreement_doc_url is required — upload the agreement document before submitting.', 1;

        IF @recurrence_cadence_sno IS NULL
            THROW 58106, 'recurrence_cadence_sno is required — see sp_nt_GetRecurrenceCadenceRecords for valid options.', 1;

        DECLARE @interval_unit VARCHAR(10);
        SELECT @interval_unit = interval_unit FROM dbo.recurrence_cadence_master WHERE recurrence_cadence_sno = @recurrence_cadence_sno AND is_active = 'Y';
        IF @interval_unit IS NULL
            THROW 58107, 'recurrence_cadence_sno does not reference an active recurrence cadence.', 1;

        IF @interval_unit = 'MONTH'
        BEGIN
            IF @po_generation_day IS NULL OR @po_generation_day NOT BETWEEN 1 AND 31
                THROW 58108, 'po_generation_day (1-31) is required for a month-based recurrence cadence.', 1;
        END
        ELSE
            SET @po_generation_day = NULL;

        DECLARE @service_type_code VARCHAR(30);
        SELECT @service_type_code = st.service_type_code
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';

        IF @service_type_code IS NULL OR @service_type_code NOT IN ('FIXED_RECURRING', 'VARIABLE_RECURRING', 'STATUTORY')
            THROW 58109, 'service_sno must reference an active Fixed, Unfixed or Statutory service.', 1;

        IF @service_type_code = 'FIXED_RECURRING'
            SET @ceiling_amount = NULL;
        ELSE IF @ceiling_amount IS NOT NULL AND @ceiling_amount <= 0
            THROW 58112, 'ceiling_amount must be a positive amount when provided.', 1;

        -- ── Resolve the ServiceAgreement workflow for this org scope ───────
        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceAgreement';

        IF @workflow_types_id IS NULL
            THROW 58110, 'No ServiceAgreement workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key] = '0' AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 58111, 'No approver found for the first stage of the ServiceAgreement workflow.', 1;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(agreement_no, 4) AS INT)), 0) + 1
        FROM dbo.service_agreement WITH (UPDLOCK, HOLDLOCK)
        WHERE agreement_no LIKE 'AGR-' + @year + '-%';
        DECLARE @agreement_no VARCHAR(30) = 'AGR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.service_agreement (
            agreement_no, com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
            qty, rate_amount, rate_uom_sno, recurrence_cadence_sno, po_generation_day, notify_days_before,
            period_start_date, period_end_date, agreement_doc_url, remarks, terms_conditions, ceiling_amount,
            workflow_types_id, current_approver_id, status, is_active, created_by
        )
        VALUES (
            @agreement_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @service_sno, @vendor_sno,
            @qty, @rate_amount, @rate_uom_sno, @recurrence_cadence_sno, @po_generation_day, @notify_days_before,
            @period_start_date, @period_end_date, @agreement_doc_url, @remarks, @terms_conditions, @ceiling_amount,
            @workflow_types_id, @first_approver, 'P', 'Y', @created_by
        );

        DECLARE @agreement_sno INT = SCOPE_IDENTITY();

        DECLARE @total_per_cycle DECIMAL(18,2) = ROUND(@rate_amount * @qty, 2), @primary_vendor INT;
        EXEC dbo.sp_nt_SaveServiceAgreementSuppliers
            @agreement_sno = @agreement_sno, @vendors_json = @vendors_json, @fallback_vendor_sno = @vendor_sno,
            @total_amount = @total_per_cycle, @out_primary_vendor_sno = @primary_vendor OUTPUT;
        IF @primary_vendor IS NOT NULL AND @primary_vendor <> @vendor_sno
            UPDATE dbo.service_agreement SET vendor_sno = @primary_vendor WHERE agreement_sno = @agreement_sno;

        EXEC dbo.sp_nt_SaveServiceAgreementStatutory
            @agreement_sno = @agreement_sno, @service_type_code = @service_type_code, @statutory_json = @statutory_json;

        DECLARE @version_no INT;
        EXEC dbo.sp_nt_SnapshotServiceAgreementVersion
            @agreement_sno = @agreement_sno, @action_type = 'SUBMITTED', @submitted_by = @created_by,
            @out_version_no = @version_no OUTPUT;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
        VALUES (@agreement_sno, 'SUBMITTED', @created_by, NULL, @version_no);

        COMMIT TRANSACTION;

        SELECT @agreement_sno AS agreement_sno, @agreement_no AS agreement_no, 'SUCCESS' AS result,
               N'Service agreement submitted for approval.' AS message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- 9) sp_nt_UpdateServiceAgreement — edit / resubmit / RENEW.
--    Changes vs sql/86: an Expired agreement (status 'X') is accepted and
--    treated as a RENEWAL (new term must start after the old one ended and
--    must not already be over); accepts vendors[] / statutory{}; writes a
--    new version snapshot (RESUBMITTED or RENEWED).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_UpdateServiceAgreement', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_UpdateServiceAgreement;
GO
CREATE PROCEDURE dbo.sp_nt_UpdateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @agreement_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
        DECLARE @com_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @service_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @vendor_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @qty                DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4));
        DECLARE @rate_amount        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @rate_uom_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_uom_sno') AS INT);
        DECLARE @recurrence_cadence_sno INT       = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_cadence_sno') AS INT);
        DECLARE @po_generation_day  SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_generation_day') AS SMALLINT);
        DECLARE @notify_days_before SMALLINT      = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.notify_days_before') AS SMALLINT), 0);
        DECLARE @period_start_date  DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url  NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @terms_conditions   NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.terms_conditions');
        DECLARE @ceiling_amount     DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @edited_by          VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.edited_by');
        DECLARE @vendors_json       NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.vendors');
        DECLARE @statutory_json     NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.statutory');

        IF @vendors_json IS NOT NULL AND ISJSON(@vendors_json) = 1
            SET @vendor_sno = ISNULL(TRY_CAST(JSON_VALUE(@vendors_json, '$[0].vendor_sno') AS INT), @vendor_sno);

        IF @agreement_sno IS NULL OR @edited_by IS NULL
            THROW 58120, 'agreement_sno and edited_by are required.', 1;

        DECLARE @current_status CHAR(1), @old_period_end DATE;
        SELECT @current_status = status, @old_period_end = period_end_date
        FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno AND is_active = 'Y';
        IF @current_status IS NULL
            THROW 58121, 'Service agreement not found or inactive.', 1;
        IF @current_status NOT IN ('A', 'R', 'X')
            THROW 58122, 'Only an Approved, Rejected or Expired agreement can be edited or renewed (it is currently Pending approval).', 1;

        DECLARE @is_renewal BIT = CASE WHEN @current_status = 'X' THEN 1 ELSE 0 END;

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @service_sno IS NULL OR @vendor_sno IS NULL
            THROW 58123, 'com_sno, div_sno, brn_sno, dept_sno, service_sno and at least one supplier are required.', 1;
        IF @qty IS NULL OR @qty <= 0
            THROW 58124, 'qty must be a positive quantity.', 1;
        IF @rate_amount IS NULL OR @rate_amount <= 0
            THROW 58125, 'rate_amount must be a positive amount.', 1;
        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 58126, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;
        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 58127, 'agreement_doc_url is required.', 1;

        IF @is_renewal = 1
        BEGIN
            IF @period_start_date <= @old_period_end
            BEGIN
                DECLARE @renew_msg NVARCHAR(300) = N'A renewal must start after the expired term ended (' + CONVERT(NVARCHAR(10), @old_period_end, 23) + N').';
                THROW 58133, @renew_msg, 1;
            END
            IF @period_end_date < CAST(GETDATE() AS DATE)
                THROW 58134, 'The renewed period has already ended — choose a term that runs beyond today.', 1;
        END

        DECLARE @interval_unit VARCHAR(10);
        SELECT @interval_unit = interval_unit FROM dbo.recurrence_cadence_master WHERE recurrence_cadence_sno = @recurrence_cadence_sno AND is_active = 'Y';
        IF @interval_unit IS NULL
            THROW 58128, 'recurrence_cadence_sno does not reference an active recurrence cadence.', 1;
        IF @interval_unit = 'MONTH'
        BEGIN
            IF @po_generation_day IS NULL OR @po_generation_day NOT BETWEEN 1 AND 31
                THROW 58129, 'po_generation_day (1-31) is required for a month-based recurrence cadence.', 1;
        END
        ELSE
            SET @po_generation_day = NULL;

        DECLARE @service_type_code VARCHAR(30);
        SELECT @service_type_code = st.service_type_code
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';
        IF @service_type_code IS NULL OR @service_type_code NOT IN ('FIXED_RECURRING', 'VARIABLE_RECURRING', 'STATUTORY')
            THROW 58135, 'service_sno must reference an active Fixed, Unfixed or Statutory service.', 1;
        IF @service_type_code = 'FIXED_RECURRING'
            SET @ceiling_amount = NULL;
        ELSE IF @ceiling_amount IS NOT NULL AND @ceiling_amount <= 0
            THROW 58132, 'ceiling_amount must be a positive amount when provided.', 1;

        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceAgreement';
        IF @workflow_types_id IS NULL
            THROW 58130, 'No ServiceAgreement workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id AND s.[key] = '0' AND s2.[key] = '0';
        IF @first_approver IS NULL
            THROW 58131, 'No approver found for the first stage of the ServiceAgreement workflow.', 1;

        UPDATE dbo.service_agreement
        SET com_sno = @com_sno, div_sno = @div_sno, brn_sno = @brn_sno, dept_sno = @dept_sno,
            service_sno = @service_sno, vendor_sno = @vendor_sno, qty = @qty, rate_amount = @rate_amount,
            rate_uom_sno = @rate_uom_sno, recurrence_cadence_sno = @recurrence_cadence_sno,
            po_generation_day = @po_generation_day, notify_days_before = @notify_days_before,
            period_start_date = @period_start_date, period_end_date = @period_end_date,
            agreement_doc_url = @agreement_doc_url, remarks = @remarks, terms_conditions = @terms_conditions,
            ceiling_amount = @ceiling_amount,
            workflow_types_id = @workflow_types_id, current_approver_id = @first_approver,
            status = 'P', modified_by = @edited_by, modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno;

        DECLARE @total_per_cycle DECIMAL(18,2) = ROUND(@rate_amount * @qty, 2), @primary_vendor INT;
        EXEC dbo.sp_nt_SaveServiceAgreementSuppliers
            @agreement_sno = @agreement_sno, @vendors_json = @vendors_json, @fallback_vendor_sno = @vendor_sno,
            @total_amount = @total_per_cycle, @out_primary_vendor_sno = @primary_vendor OUTPUT;
        IF @primary_vendor IS NOT NULL AND @primary_vendor <> @vendor_sno
            UPDATE dbo.service_agreement SET vendor_sno = @primary_vendor WHERE agreement_sno = @agreement_sno;

        EXEC dbo.sp_nt_SaveServiceAgreementStatutory
            @agreement_sno = @agreement_sno, @service_type_code = @service_type_code, @statutory_json = @statutory_json;

        DECLARE @edit_action VARCHAR(20) = CASE WHEN @is_renewal = 1 THEN 'RENEWED' ELSE 'RESUBMITTED' END;
        DECLARE @version_no INT;
        EXEC dbo.sp_nt_SnapshotServiceAgreementVersion
            @agreement_sno = @agreement_sno, @action_type = @edit_action, @submitted_by = @edited_by,
            @out_version_no = @version_no OUTPUT;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
        VALUES (@agreement_sno, @edit_action, @edited_by, NULL, @version_no);

        COMMIT TRANSACTION;

        SELECT @agreement_sno AS agreement_sno, @version_no AS version_no, 'SUCCESS' AS result,
               CASE WHEN @is_renewal = 1 THEN N'Service agreement renewed and submitted for approval.'
                    ELSE N'Service agreement updated and resubmitted for approval.' END AS message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- 10) sp_nt_GetServiceAgreements — list. Adds the supplier split
--     (vendors_json), facility block, ceiling and version counters.
--     vendor_name stays the PRIMARY supplier's name.
-- ============================================================
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

-- ============================================================
-- 11) sp_nt_GetServiceAgreementsForApproval — approver inbox. Same additions
--     plus submit_action (SUBMITTED / RESUBMITTED / RENEWED) and the
--     previous version's terms so the approver can see what changed.
-- ============================================================
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

-- ============================================================
-- 12) sp_nt_GetServiceAgreementHistory — everything about one agreement
--     over its whole life, for the History view: every version (terms +
--     approval trail) and every cycle with the PO(s) raised for it.
--     Returned as ONE row of three JSON columns, parsed in the Node layer.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServiceAgreementHistory', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceAgreementHistory;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceAgreementHistory
    @agreement_sno INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT sa.agreement_sno, sa.agreement_no, sa.status, sm.service_name, st.service_type_code,
           (
               SELECT ver.version_no, ver.action_type, ver.outcome, ver.period_start_date, ver.period_end_date,
                      ver.submitted_by, ver.submitted_at, ver.decided_at, ver.superseded_at, ver.note,
                      JSON_QUERY(ver.terms_json) AS terms,
                      (
                          SELECT h.action_type, h.status_by, h.comment, h.created_at
                          FROM dbo.service_agreement_history h
                          WHERE h.agreement_sno = ver.agreement_sno AND ISNULL(h.version_no, 1) = ver.version_no
                          ORDER BY h.history_sno
                          FOR JSON PATH
                      ) AS events
               FROM dbo.service_agreement_version ver
               WHERE ver.agreement_sno = sa.agreement_sno
               ORDER BY ver.version_no DESC
               FOR JSON PATH
           ) AS versions_json,
           (
               SELECT c.cycle_sno, c.billing_period_start, c.qty, c.rate_amount, c.discount_pct, c.gst_pct,
                      c.net_cost, c.status, c.entered_by, c.entered_at,
                      (
                          SELECT cv.vendor_sno, kv.company_name AS vendor_name, cv.share_pct, cv.rate_amount,
                                 cv.net_cost, cv.po_basic_sno, po2.po_df_no AS po_no
                          FROM dbo.service_po_cycle_vendor cv
                          LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = cv.vendor_sno
                          LEFT JOIN dbo.po_request_info po2 ON po2.po_basic_sno = cv.po_basic_sno
                          WHERE cv.cycle_sno = c.cycle_sno
                          ORDER BY cv.cycle_vendor_sno
                          FOR JSON PATH
                      ) AS suppliers
               FROM dbo.service_po_cycle c
               WHERE c.agreement_sno = sa.agreement_sno
               ORDER BY c.billing_period_start DESC, c.cycle_sno DESC
               FOR JSON PATH
           ) AS cycles_json
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    WHERE sa.agreement_sno = @agreement_sno;
END;
GO

-- ============================================================
-- 13) sp_nt_ExpireServiceAgreements — also stamps the version outcome and
--     points the user at renewal (the old text said "create a new agreement").
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ExpireServiceAgreements', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ExpireServiceAgreements;
GO
CREATE PROCEDURE dbo.sp_nt_ExpireServiceAgreements
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @expired TABLE (agreement_sno INT);

    UPDATE dbo.service_agreement
    SET status = 'X'
    OUTPUT inserted.agreement_sno INTO @expired
    WHERE status = 'A' AND is_active = 'Y' AND period_end_date < CAST(GETDATE() AS DATE);

    UPDATE ver
    SET outcome = 'EXPIRED'
    FROM dbo.service_agreement_version ver
    JOIN @expired e ON e.agreement_sno = ver.agreement_sno
    WHERE ver.version_no = (SELECT MAX(v2.version_no) FROM dbo.service_agreement_version v2 WHERE v2.agreement_sno = ver.agreement_sno);

    INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
    SELECT e.agreement_sno, 'EXPIRED', 'SYSTEM', N'Period end date passed — renew this agreement to continue the service.',
           (SELECT MAX(v.version_no) FROM dbo.service_agreement_version v WHERE v.agreement_sno = e.agreement_sno)
    FROM @expired e;

    SELECT COUNT(*) AS expired_count FROM @expired;
END;
GO

-- ============================================================
-- 14) sp_approve_service_agreement — generated from the live definition:
--     history rows now carry the version, the version's outcome is stamped
--     on approve/reject, and the "issue the first cycle" check looks at THIS
--     term's billing dates (a renewed agreement already has old-term log
--     rows, so the old "no rows at all" check would never issue its first
--     cycle).
-- ============================================================
IF OBJECT_ID('dbo.sp_approve_service_agreement', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_approve_service_agreement;
GO
CREATE PROCEDURE dbo.sp_approve_service_agreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF ISJSON(@jsonInput) = 0
        BEGIN
            RAISERROR('Invalid JSON format for @jsonInput', 16, 1);
            RETURN;
        END

        DECLARE @agreement_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT),
                @comments         VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages  NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by      VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action           VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');

        IF @agreement_sno IS NULL
        BEGIN
            RAISERROR('agreement_sno is required.', 16, 1);
            RETURN;
        END

        IF @action IS NULL OR LTRIM(RTRIM(LOWER(@action))) NOT IN ('approve', 'reject')
        BEGIN
            RAISERROR('Invalid action. Must be ''approve'' or ''reject''.', 16, 1);
            RETURN;
        END
        SET @action = LOWER(LTRIM(RTRIM(@action)));

        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
        BEGIN
            RAISERROR('Invalid or missing approval_stages in JSON', 16, 1);
            RETURN;
        END

        IF @approved_by IS NULL OR LTRIM(RTRIM(@approved_by)) = ''
        BEGIN
            RAISERROR('Approver EC number is required.', 16, 1);
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno AND is_active = 'Y')
        BEGIN
            RAISERROR('Service agreement not found or inactive.', 16, 1);
            RETURN;
        END

        -- The version this decision applies to (sql/88): the highest version_no
        -- is the one currently in approval.
        DECLARE @cur_version INT = (SELECT MAX(version_no) FROM dbo.service_agreement_version WHERE agreement_sno = @agreement_sno);

        BEGIN TRANSACTION;

        CREATE TABLE #approval_stages (
            seq_no INT, approver_ecno VARCHAR(30), stage VARCHAR(100),
            required_approvals VARCHAR(10), is_mandatory CHAR(1), escalation_hours VARCHAR(10),
            approver_condition VARCHAR(200), next_approver_ecno VARCHAR(30),
            can_forward CHAR(1), can_backward CHAR(1), can_edit_data CHAR(1)
        );

        INSERT INTO #approval_stages (
            seq_no, approver_ecno, stage, required_approvals, is_mandatory,
            escalation_hours, approver_condition, next_approver_ecno,
            can_forward, can_backward, can_edit_data
        )
        SELECT
            CAST(ojBase.[key] AS INT),
            JSON_VALUE(ojBase.[value], '$.approver_ecno'),
            JSON_VALUE(ojBase.[value], '$.stage'),
            JSON_VALUE(ojBase.[value], '$.required_approvals'),
            JSON_VALUE(ojBase.[value], '$.is_mandatory'),
            JSON_VALUE(ojBase.[value], '$.escalation_hours'),
            JSON_VALUE(ojBase.[value], '$.approver_condition'),
            JSON_VALUE(ojBase.[value], '$.next_approver_ecno'),
            JSON_VALUE(ojBase.[value], '$.can_forward'),
            JSON_VALUE(ojBase.[value], '$.can_backward'),
            JSON_VALUE(ojBase.[value], '$.can_edit_data')
        FROM OPENJSON(@approval_stages) AS ojBase;

        IF @action = 'reject'
        BEGIN
            INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
            VALUES (@agreement_sno, 'REJECTED', @approved_by, @comments, @cur_version);

            UPDATE dbo.service_agreement SET status = 'R', current_approver_id = NULL WHERE agreement_sno = @agreement_sno;

            UPDATE dbo.service_agreement_version SET outcome = 'REJECTED', decided_at = GETDATE()
            WHERE agreement_sno = @agreement_sno AND version_no = @cur_version;

            DROP TABLE #approval_stages;
            COMMIT TRANSACTION;
            SELECT 'REJECTED' AS result, @agreement_sno AS agreement_sno, @approved_by AS rejected_by, GETDATE() AS rejected_on;
            RETURN;
        END

        DECLARE @next_current_approver VARCHAR(30);
        SELECT @next_current_approver = next_stage.approver_ecno
        FROM (
            SELECT approver_ecno, LEAD(approver_ecno, 1, NULL) OVER (ORDER BY seq_no) AS next_approver_ecno
            FROM #approval_stages
        ) current_stage
        LEFT JOIN #approval_stages next_stage ON next_stage.approver_ecno = current_stage.next_approver_ecno
        WHERE current_stage.approver_ecno = @approved_by;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
        VALUES (@agreement_sno, 'APPROVED', @approved_by, @comments, @cur_version);

        UPDATE dbo.service_agreement SET current_approver_id = @next_current_approver WHERE agreement_sno = @agreement_sno;

        DECLARE @auto_po_result VARCHAR(200) = NULL, @auto_po_basic_sno INT = NULL, @auto_po_no VARCHAR(50) = NULL,
                @auto_pr_basic_sno INT = NULL, @auto_pr_no VARCHAR(20) = NULL;

        IF @next_current_approver IS NULL
        BEGIN
            -- ── Final stage: Fixed and Unfixed both go straight to Approved
            --    now — rate/qty stay whatever was entered at creation, no
            --    re-entry/finalization step here any more. ──────────────
            DECLARE @period_start DATE;
            SELECT @period_start = sa.period_start_date FROM dbo.service_agreement sa WHERE sa.agreement_sno = @agreement_sno;

            UPDATE dbo.service_agreement SET status = 'A' WHERE agreement_sno = @agreement_sno;

            UPDATE dbo.service_agreement_version SET outcome = 'APPROVED', decided_at = GETDATE()
            WHERE agreement_sno = @agreement_sno AND version_no = @cur_version;

            -- sql/88: only THIS term's billing dates count. A renewed agreement already
            -- has log rows from its previous term, which must not suppress the first
            -- cycle of the new one.
            IF NOT EXISTS (SELECT 1 FROM dbo.service_agreement_recurring_pr_log WHERE agreement_sno = @agreement_sno AND billing_period_start >= @period_start)
            BEGIN
                DECLARE @first_billing_period_start DATE = CASE WHEN CAST(GETDATE() AS DATE) < @period_start THEN @period_start ELSE CAST(GETDATE() AS DATE) END;
                DECLARE @firstCycleJson NVARCHAR(MAX) = (
                    SELECT @agreement_sno AS agreement_sno, @first_billing_period_start AS billing_period_start, @approved_by AS issued_by
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
                );

                BEGIN TRY
                    EXEC dbo.sp_nt_IssueRecurringServicePOCycle
                        @jsonInput = @firstCycleJson, @silent = 1,
                        @out_result = @auto_po_result OUTPUT, @out_po_basic_sno = @auto_po_basic_sno OUTPUT, @out_po_no = @auto_po_no OUTPUT,
                        @out_pr_basic_sno = @auto_pr_basic_sno OUTPUT, @out_pr_no = @auto_pr_no OUTPUT;
                END TRY
                BEGIN CATCH
                    -- Do not fail the approval itself — service_agreement_recurring_pr_log
                    -- already has a FAILED row for ops to find and retry via a fresh sweep call.
                    SET @auto_po_result = 'ERROR: ' + ERROR_MESSAGE();
                END CATCH
            END
        END

        DROP TABLE #approval_stages;
        COMMIT TRANSACTION;

        SELECT
            'SUCCESS' AS result, @agreement_sno AS agreement_sno, @approved_by AS approved_by, GETDATE() AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE') AS next_approver,
            @auto_po_result AS auto_po_result, @auto_po_basic_sno AS auto_po_basic_sno, @auto_po_no AS auto_po_no,
            @auto_pr_basic_sno AS auto_pr_basic_sno, @auto_pr_no AS auto_pr_no;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL DROP TABLE #approval_stages;
        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO

-- ============================================================
-- 15) sp_nt_IssueRecurringServicePOCycle — generated from the live
--     definition (sql/87). Only change: a Fixed cycle (rate known up front)
--     gets its supplier split materialised immediately; Unfixed/Statutory
--     cycles get theirs when the rate is entered.
-- ============================================================
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

-- ============================================================
-- 16) sp_nt_SubmitServicePoEntry — rate entry for Pending Entry cycles
--     (Unfixed + Statutory). Now builds the per-supplier split and checks the
--     ceiling against the SUM of the split. Runs in its own transaction
--     (it is only ever called from the Node layer, never nested) so an
--     over-ceiling THROW leaves no half-written split rows behind.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_SubmitServicePoEntry', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_SubmitServicePoEntry;
GO
CREATE PROCEDURE dbo.sp_nt_SubmitServicePoEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @cycle_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.cycle_sno') AS INT);
        DECLARE @rate_amount  DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @discount_pct DECIMAL(5,2)  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.discount_pct') AS DECIMAL(5,2)), 0);
        DECLARE @gst_pct      DECIMAL(5,2)  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.gst_pct') AS DECIMAL(5,2)), 0);
        DECLARE @remarks      NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @submitted_by VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.submitted_by');

        IF @cycle_sno IS NULL OR @rate_amount IS NULL OR @rate_amount <= 0 OR @submitted_by IS NULL
            THROW 58320, 'cycle_sno, rate_amount and submitted_by are required.', 1;
        IF @discount_pct < 0 OR @discount_pct > 100 OR @gst_pct < 0 OR @gst_pct > 100
            THROW 58324, 'discount_pct and gst_pct must be between 0 and 100.', 1;

        DECLARE @agreement_sno INT, @qty DECIMAL(18,4), @status VARCHAR(20),
                @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @ceiling_amount DECIMAL(18,2);
        SELECT @agreement_sno = spc.agreement_sno, @qty = spc.qty, @status = spc.status,
               @com_sno = spc.com_sno, @div_sno = spc.div_sno, @brn_sno = spc.brn_sno, @dept_sno = spc.dept_sno,
               @ceiling_amount = sa.ceiling_amount
        FROM dbo.service_po_cycle spc
        JOIN dbo.service_agreement sa ON sa.agreement_sno = spc.agreement_sno
        WHERE spc.cycle_sno = @cycle_sno;

        IF @agreement_sno IS NULL THROW 58321, 'Service PO cycle not found.', 1;
        IF @status <> 'PENDING_ENTRY' THROW 58322, 'This cycle is not awaiting entry.', 1;

        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        EXEC dbo.sp_nt_ResolveServicePoWorkflow
            @com_sno = @com_sno, @div_sno = @div_sno, @brn_sno = @brn_sno, @dept_sno = @dept_sno,
            @workflow_types_id = @workflow_types_id OUTPUT, @first_approver = @first_approver OUTPUT;

        BEGIN TRANSACTION;

        DECLARE @net_cost DECIMAL(18,2);
        EXEC dbo.sp_nt_BuildServicePoCycleSplit
            @cycle_sno = @cycle_sno, @agreement_sno = @agreement_sno, @rate_amount = @rate_amount, @qty = @qty,
            @discount_pct = @discount_pct, @gst_pct = @gst_pct, @out_net_cost = @net_cost OUTPUT;

        IF @ceiling_amount IS NOT NULL AND @net_cost > @ceiling_amount
            THROW 58323, 'Entered amount exceeds the agreement''s ceiling amount.', 1;

        UPDATE dbo.service_po_cycle
        SET rate_amount = @rate_amount, discount_pct = @discount_pct, gst_pct = @gst_pct, net_cost = @net_cost,
            remarks = @remarks, status = 'PENDING_APPROVAL',
            workflow_types_id = @workflow_types_id, current_approver_id = @first_approver,
            entered_by = @submitted_by, entered_at = GETDATE()
        WHERE cycle_sno = @cycle_sno;

        INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
        VALUES (@cycle_sno, 'ENTRY_SUBMITTED', @submitted_by,
                N'Rate ' + CAST(@rate_amount AS VARCHAR(30)) + N', GST ' + CAST(@gst_pct AS VARCHAR(10)) + N'%, Net ' + CAST(@net_cost AS VARCHAR(30)));

        COMMIT TRANSACTION;

        SELECT 'SUCCESS' AS result, @cycle_sno AS cycle_sno, @net_cost AS net_cost;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- 17) sp_nt_ApproveServicePoCycle — generated from the live definition.
--     Final-stage block rewritten: one PO PER SUPPLIER in the cycle's split
--     (each PO's line = that supplier's unit rate x the cycle qty, same
--     discount/GST). service_po_cycle.po_basic_sno / the recurring log keep
--     the FIRST PO for backward compatibility; the full list comes back in
--     po_basic_snos so the controller can dispatch each supplier's PO.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ApproveServicePoCycle', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ApproveServicePoCycle;
GO
CREATE PROCEDURE dbo.sp_nt_ApproveServicePoCycle
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF ISJSON(@jsonInput) = 0
        BEGIN
            RAISERROR('Invalid JSON format for @jsonInput', 16, 1);
            RETURN;
        END

        DECLARE @cycle_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.cycle_sno') AS INT),
                @comments        VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by     VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action          VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');

        IF @cycle_sno IS NULL
        BEGIN
            RAISERROR('cycle_sno is required.', 16, 1);
            RETURN;
        END

        IF @action IS NULL OR LTRIM(RTRIM(LOWER(@action))) NOT IN ('approve', 'reject')
        BEGIN
            RAISERROR('Invalid action. Must be ''approve'' or ''reject''.', 16, 1);
            RETURN;
        END
        SET @action = LOWER(LTRIM(RTRIM(@action)));

        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
        BEGIN
            RAISERROR('Invalid or missing approval_stages in JSON', 16, 1);
            RETURN;
        END

        IF @approved_by IS NULL OR LTRIM(RTRIM(@approved_by)) = ''
        BEGIN
            RAISERROR('Approver EC number is required.', 16, 1);
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.service_po_cycle WHERE cycle_sno = @cycle_sno AND status = 'PENDING_APPROVAL')
        BEGIN
            RAISERROR('Service PO cycle not found or not awaiting approval.', 16, 1);
            RETURN;
        END

        BEGIN TRANSACTION;

        CREATE TABLE #po_approval_stages (
            seq_no INT, approver_ecno VARCHAR(30), stage VARCHAR(100),
            required_approvals VARCHAR(10), is_mandatory CHAR(1), escalation_hours VARCHAR(10),
            approver_condition VARCHAR(200), next_approver_ecno VARCHAR(30),
            can_forward CHAR(1), can_backward CHAR(1), can_edit_data CHAR(1)
        );

        INSERT INTO #po_approval_stages (
            seq_no, approver_ecno, stage, required_approvals, is_mandatory,
            escalation_hours, approver_condition, next_approver_ecno,
            can_forward, can_backward, can_edit_data
        )
        SELECT
            CAST(ojBase.[key] AS INT),
            JSON_VALUE(ojBase.[value], '$.approver_ecno'),
            JSON_VALUE(ojBase.[value], '$.stage'),
            JSON_VALUE(ojBase.[value], '$.required_approvals'),
            JSON_VALUE(ojBase.[value], '$.is_mandatory'),
            JSON_VALUE(ojBase.[value], '$.escalation_hours'),
            JSON_VALUE(ojBase.[value], '$.approver_condition'),
            JSON_VALUE(ojBase.[value], '$.next_approver_ecno'),
            JSON_VALUE(ojBase.[value], '$.can_forward'),
            JSON_VALUE(ojBase.[value], '$.can_backward'),
            JSON_VALUE(ojBase.[value], '$.can_edit_data')
        FROM OPENJSON(@approval_stages) AS ojBase;

        IF @action = 'reject'
        BEGIN
            INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
            VALUES (@cycle_sno, 'REJECTED', @approved_by, @comments);

            UPDATE dbo.service_po_cycle SET status = 'REJECTED', current_approver_id = NULL WHERE cycle_sno = @cycle_sno;

            DROP TABLE #po_approval_stages;
            COMMIT TRANSACTION;
            SELECT 'REJECTED' AS result, @cycle_sno AS cycle_sno, @approved_by AS rejected_by, GETDATE() AS rejected_on;
            RETURN;
        END

        DECLARE @next_current_approver VARCHAR(30);
        SELECT @next_current_approver = next_stage.approver_ecno
        FROM (
            SELECT approver_ecno, LEAD(approver_ecno, 1, NULL) OVER (ORDER BY seq_no) AS next_approver_ecno
            FROM #po_approval_stages
        ) current_stage
        LEFT JOIN #po_approval_stages next_stage ON next_stage.approver_ecno = current_stage.next_approver_ecno
        WHERE current_stage.approver_ecno = @approved_by;

        INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
        VALUES (@cycle_sno, 'APPROVED', @approved_by, @comments);

        UPDATE dbo.service_po_cycle SET current_approver_id = @next_current_approver WHERE cycle_sno = @cycle_sno;

        DECLARE @out_po_basic_sno INT = NULL, @out_po_no VARCHAR(50) = NULL;

        IF @next_current_approver IS NULL
        BEGIN
            -- ── Final stage: raise ONE PO PER SUPPLIER in the cycle's split (sql/88) ──
            DECLARE @agreement_sno INT, @pr_basic_sno INT, @qty DECIMAL(18,4),
                    @discount_pct DECIMAL(5,2), @gst_pct DECIMAL(5,2),
                    @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT,
                    @service_sno INT, @service_name NVARCHAR(150), @rate_uom_sno INT, @agreement_no VARCHAR(30),
                    @service_type_sno INT, @period_end DATE;

            SELECT @agreement_sno = spc.agreement_sno, @pr_basic_sno = spc.pr_basic_sno, @qty = spc.qty,
                   @discount_pct = ISNULL(spc.discount_pct, 0), @gst_pct = ISNULL(spc.gst_pct, 0),
                   @com_sno = spc.com_sno, @div_sno = spc.div_sno, @brn_sno = spc.brn_sno, @dept_sno = spc.dept_sno
            FROM dbo.service_po_cycle spc
            WHERE spc.cycle_sno = @cycle_sno;

            SELECT @service_sno = sa.service_sno, @rate_uom_sno = sa.rate_uom_sno,
                   @agreement_no = sa.agreement_no, @period_end = sa.period_end_date,
                   @service_name = sm.service_name, @service_type_sno = sm.service_type_sno
            FROM dbo.service_agreement sa
            JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
            WHERE sa.agreement_sno = @agreement_sno;

            -- Defensive: a cycle with no split rows (none should exist after sql/88's
            -- backfill) falls back to the agreement's primary supplier at 100%.
            IF NOT EXISTS (SELECT 1 FROM dbo.service_po_cycle_vendor WHERE cycle_sno = @cycle_sno)
                INSERT INTO dbo.service_po_cycle_vendor (cycle_sno, vendor_sno, share_pct, rate_amount, net_cost)
                SELECT spc.cycle_sno, sa.vendor_sno, 100, spc.rate_amount, spc.net_cost
                FROM dbo.service_po_cycle spc
                JOIN dbo.service_agreement sa ON sa.agreement_sno = spc.agreement_sno
                WHERE spc.cycle_sno = @cycle_sno;

            DECLARE @supplier_count INT = (SELECT COUNT(*) FROM dbo.service_po_cycle_vendor WHERE cycle_sno = @cycle_sno);
            DECLARE @po_list VARCHAR(500) = '';
            DECLARE @cv_sno INT, @cv_vendor INT, @cv_rate DECIMAL(18,2), @cv_net DECIMAL(18,2), @cv_pct DECIMAL(9,6);
            DECLARE @new_po_sno INT, @new_po_no VARCHAR(50), @po_seq INT;
            DECLARE @po_year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));

            DECLARE po_cur CURSOR LOCAL FAST_FORWARD FOR
                SELECT cycle_vendor_sno, vendor_sno, rate_amount, net_cost, share_pct
                FROM dbo.service_po_cycle_vendor
                WHERE cycle_sno = @cycle_sno
                ORDER BY cycle_vendor_sno;

            OPEN po_cur;
            FETCH NEXT FROM po_cur INTO @cv_sno, @cv_vendor, @cv_rate, @cv_net, @cv_pct;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @po_seq = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
                FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
                WHERE po_df_no LIKE 'SVO-' + @po_year + '-%';
                SET @new_po_no = 'SVO-' + @po_year + '-' + RIGHT('0000' + CAST(@po_seq AS VARCHAR(4)), 4);

                INSERT INTO dbo.po_request_info (
                    vendor_sno, brn_sno, dept_sno, com_sno, div_sno, budget_sno, budget_code, pr_basic_sno,
                    po_date, required_date, purpose, terms_conditions, delivery_address,
                    is_active, workflow_types_id, current_approver_id, status, po_df_no, service_type_sno
                )
                VALUES (
                    @cv_vendor, @brn_sno, @dept_sno, @com_sno, @div_sno, NULL, NULL, @pr_basic_sno,
                    CAST(GETDATE() AS DATE), @period_end,
                    N'Recurring service PO — Agreement ' + @agreement_no + N' (' + @service_name + N')'
                        + CASE WHEN @supplier_count > 1
                               THEN N' — ' + CONVERT(NVARCHAR(12), CAST(@cv_pct AS DECIMAL(9,2))) + N'% share'
                               ELSE N'' END,
                    NULL, NULL,
                    'Y', NULL, NULL, 'A', @new_po_no, @service_type_sno
                );
                SET @new_po_sno = SCOPE_IDENTITY();

                INSERT INTO dbo.po_item_details (
                    po_basic_sno, pr_item_sno, service_sno, prod_name, specification,
                    qty, unit, unit_name, agreed_unit_price, total_cost, discount_pct, tax_pct, net_cost,
                    remarks, po_section, created_by, created_date, is_active
                )
                SELECT
                    @new_po_sno, NULL, @service_sno, sm.service_name, '',
                    @qty, @rate_uom_sno, um.uom_name, @cv_rate, @cv_rate * @qty, @discount_pct, @gst_pct, @cv_net,
                    NULL, 'SERVICE', @approved_by, GETDATE(), '1'
                FROM dbo.service_master sm
                LEFT JOIN dbo.uom_master um ON um.uom_sno = @rate_uom_sno
                WHERE sm.service_sno = @service_sno;

                INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
                VALUES (@new_po_sno, 'APPROVED_ISSUED', @approved_by, N'Issued after Service PO cycle approval (Agreement ' + @agreement_no + N').', 'Y');

                UPDATE dbo.service_po_cycle_vendor SET po_basic_sno = @new_po_sno WHERE cycle_vendor_sno = @cv_sno;

                -- The first PO is the "primary" one kept on the cycle / recurring log
                IF @out_po_basic_sno IS NULL
                BEGIN
                    SET @out_po_basic_sno = @new_po_sno;
                    SET @out_po_no = @new_po_no;
                END
                SET @po_list = @po_list + CASE WHEN @po_list = '' THEN '' ELSE ',' END + CAST(@new_po_sno AS VARCHAR(20));

                FETCH NEXT FROM po_cur INTO @cv_sno, @cv_vendor, @cv_rate, @cv_net, @cv_pct;
            END
            CLOSE po_cur;
            DEALLOCATE po_cur;

            UPDATE dbo.service_po_cycle SET status = 'GENERATED', po_basic_sno = @out_po_basic_sno WHERE cycle_sno = @cycle_sno;

            UPDATE dbo.service_agreement_recurring_pr_log
            SET po_basic_sno = @out_po_basic_sno, po_no = @out_po_no
            WHERE agreement_sno = @agreement_sno AND pr_basic_sno = @pr_basic_sno;
        END

        DROP TABLE #po_approval_stages;
        COMMIT TRANSACTION;

        SELECT
            'SUCCESS' AS result, @cycle_sno AS cycle_sno, @approved_by AS approved_by, GETDATE() AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE') AS next_approver,
            @out_po_basic_sno AS po_basic_sno, @out_po_no AS po_no,
            @po_list AS po_basic_snos, @supplier_count AS po_count;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF OBJECT_ID('tempdb..#po_approval_stages') IS NOT NULL DROP TABLE #po_approval_stages;
        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO

-- ============================================================
-- 18) sp_nt_GetServicePoCycles / ...ForApproval — add the actual split
--     (vendors_json, present once a rate is entered), the agreement's
--     configured suppliers (agreement_vendors_json, always present, so a
--     Pending Entry cycle can preview who gets what) and the facility block.
--     vendor_name stays the primary supplier's name.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServicePoCycles', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServicePoCycles;
GO
CREATE PROCEDURE dbo.sp_nt_GetServicePoCycles
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

    SELECT spc.cycle_sno, spc.agreement_sno, sa.agreement_no,
           spc.com_sno, spc.div_sno, spc.brn_sno, spc.dept_sno,
           sm.service_name, st.service_type_code, st.service_type_name,
           k.company_name AS vendor_name,
           (
               SELECT cv.vendor_sno, kv.company_name AS vendor_name, cv.share_pct, cv.rate_amount, cv.net_cost,
                      cv.po_basic_sno, po2.po_df_no AS po_no
               FROM dbo.service_po_cycle_vendor cv
               LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = cv.vendor_sno
               LEFT JOIN dbo.po_request_info po2 ON po2.po_basic_sno = cv.po_basic_sno
               WHERE cv.cycle_sno = spc.cycle_sno
               ORDER BY cv.cycle_vendor_sno
               FOR JSON PATH
           ) AS vendors_json,
           (
               SELECT v.vendor_sno, kv.company_name AS vendor_name, v.share_amount, v.share_pct
               FROM dbo.service_agreement_vendor v
               LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = v.vendor_sno
               WHERE v.agreement_sno = spc.agreement_sno
               ORDER BY v.sort_order, v.agreement_vendor_sno
               FOR JSON PATH
           ) AS agreement_vendors_json,
           spc.billing_period_start, spc.qty, spc.rate_amount, spc.discount_pct, spc.gst_pct, spc.net_cost,
           sa.ceiling_amount, spc.status, spc.current_approver_id,
           stt.facility_type, stt.rate_type, stt.interest_rate_pct, stt.sanctioned_amount,
           spc.po_basic_sno, po.po_df_no AS po_no, po.po_date,
           spc.entered_by, spc.entered_at, spc.created_at
    FROM dbo.service_po_cycle spc
    JOIN dbo.service_agreement sa ON sa.agreement_sno = spc.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.po_request_info po ON po.po_basic_sno = spc.po_basic_sno
    LEFT JOIN dbo.service_agreement_statutory stt ON stt.agreement_sno = sa.agreement_sno
    WHERE (@com_sno IS NULL OR spc.com_sno = @com_sno)
      AND (@div_sno IS NULL OR spc.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR spc.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR spc.dept_sno = @dept_sno)
    ORDER BY spc.cycle_sno DESC;
END;
GO

IF OBJECT_ID('dbo.sp_nt_GetServicePoCyclesForApproval', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServicePoCyclesForApproval;
GO
CREATE PROCEDURE dbo.sp_nt_GetServicePoCyclesForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT spc.cycle_sno, spc.agreement_sno, sa.agreement_no,
           sm.service_name, st.service_type_code, st.service_type_name,
           k.company_name AS vendor_name,
           (
               SELECT cv.vendor_sno, kv.company_name AS vendor_name, cv.share_pct, cv.rate_amount, cv.net_cost
               FROM dbo.service_po_cycle_vendor cv
               LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = cv.vendor_sno
               WHERE cv.cycle_sno = spc.cycle_sno
               ORDER BY cv.cycle_vendor_sno
               FOR JSON PATH
           ) AS vendors_json,
           spc.billing_period_start, spc.qty, spc.rate_amount, spc.discount_pct, spc.gst_pct, spc.net_cost,
           sa.ceiling_amount, spc.status, spc.current_approver_id, spc.entered_by, spc.entered_at,
           stt.facility_type, stt.rate_type, stt.interest_rate_pct, stt.sanctioned_amount,
           (
               SELECT ws.stage_order_json
               FROM dbo.workflow_stage ws
               WHERE ws.workflow_types_id = spc.workflow_types_id AND ws.is_active = 'Y'
           ) AS stage_order_json
    FROM dbo.service_po_cycle spc
    JOIN dbo.service_agreement sa ON sa.agreement_sno = spc.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.service_agreement_statutory stt ON stt.agreement_sno = sa.agreement_sno
    WHERE spc.status = 'PENDING_APPROVAL' AND spc.current_approver_id = @Ecno
    ORDER BY spc.cycle_sno DESC;
END;
GO
