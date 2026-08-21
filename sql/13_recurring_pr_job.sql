-- ============================================================
-- Recurring PR generation — the due-agreement query + idempotency log
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : new backend-stpl/src/ServiceAgreement/jobs/RecurringPrJob.js
--
-- Why this is needed
-- ------------------
-- backend-stpl/docs/service-agreement-approval-po-spec.md §5: once a Service
-- Agreement is approved, a PR for each billing period should appear
-- automatically on the agreement's recurrence_cadence boundary (e.g. the 1st
-- of every month for a Rent agreement whose period_start_date is the 1st) —
-- without a requester re-entering anything — until period_end_date. This is
-- the one piece of the spec with no existing scheduler/cron anywhere in this
-- codebase to model after (confirmed: grep for "recurring|subscription"
-- across backend-stpl/grn-service/notification-service returns nothing), so
-- the SQL here is new rather than a replacement of an existing procedure.
--
-- Design:
--   - sp_nt_GetAgreementsDueForRecurringPR is the only new procedure. It does
--     NOT create the PR itself — the Node job reuses the exact same
--     PRService.createPrRecords() -> usp_InsertPurchaseRequest path a manual
--     PR submission uses (per spec §5 step 2), so a recurring PR is
--     indistinguishable in the PR tables from one a person typed in, and
--     automatically gets the §4.1 agreement-validation/rate-override
--     treatment for free.
--   - "Is today a boundary" is computed per cadence with the
--     DATEADD(unit, DATEDIFF(unit, start, today), start) = today idiom: it's
--     true exactly on each unit-anniversary of period_start_date and lets SQL
--     Server's own date arithmetic handle short-month clipping (e.g. a 31st
--     start date anniversary in a 30-day month) rather than hand-rolling it.
--   - Idempotency has two layers, both required:
--       1. service_agreement_recurring_pr_log, one row per
--          (agreement_sno, billing_period_start) — UNIQUE-constrained, so
--          even if the job's sweep interval overlaps a slow run, only one
--          process can ever claim a given period. The Node job INSERTs a
--          'PENDING' row to claim the slot before calling
--          PRService.createPrRecords(), then updates it to CREATED/FAILED.
--       2. A second guard against a *manually*-created PR already covering
--          this period (the requester used §4's PR-line auto-fill
--          themselves, e.g. for the agreement's first period, before the job
--          ever ran) — pr_item_details.agreement_sno (added in
--          12_pr_agreement_autofill.sql) makes this checkable: if any active
--          PR item already references this agreement_sno with a
--          pr_basic_info.created_date after the *previous* boundary, skip.
--          Without this, the job would double-book a period someone already
--          submitted by hand.
--   - Known gap, intentionally out of scope here: a FAILED log row still
--     occupies its (agreement_sno, billing_period_start) slot, so a failed
--     attempt does not auto-retry until the *next* cadence boundary rather
--     than on the next sweep. Acceptable for a first pass (avoids retry-storm
--     complexity) but someone should periodically query this table for
--     status='FAILED' rows.
-- ============================================================

-- ── service_agreement_recurring_pr_log ──────────────────────────────────────

IF OBJECT_ID('dbo.service_agreement_recurring_pr_log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_agreement_recurring_pr_log (
        log_sno              INT IDENTITY(1,1) PRIMARY KEY,
        agreement_sno         INT           NOT NULL,
        -- the cadence boundary date this log row claims, e.g. 2026-03-01 for
        -- March's rent under a MONTHLY agreement whose period_start_date is
        -- the 1st
        billing_period_start   DATE          NOT NULL,
        pr_basic_sno             INT         NULL,
        pr_no                     VARCHAR(20) NULL,
        status                     VARCHAR(20) NOT NULL DEFAULT 'PENDING', -- PENDING | CREATED | FAILED
        error_message               NVARCHAR(500) NULL,
        created_at                   DATETIME  NOT NULL DEFAULT GETDATE(),
        modified_at                  DATETIME  NULL,
        CONSTRAINT UQ_service_agreement_recurring_pr_log UNIQUE (agreement_sno, billing_period_start),
        CONSTRAINT FK_service_agreement_recurring_pr_log_agreement FOREIGN KEY (agreement_sno)
            REFERENCES dbo.service_agreement (agreement_sno)
    );
END;
GO

-- ============================================================
-- sp_nt_GetAgreementsDueForRecurringPR — no @jsonInput; the Node job calls
-- this on every sweep and only acts on whatever comes back (usually nothing).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetAgreementsDueForRecurringPR', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetAgreementsDueForRecurringPR;
GO
CREATE PROCEDURE dbo.sp_nt_GetAgreementsDueForRecurringPR
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @today DATE = CAST(GETDATE() AS DATE);

    SELECT
        sa.agreement_sno,
        sa.agreement_no,
        sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
        sa.service_sno,
        sm.service_name,
        sa.recurrence_cadence,
        sa.period_start_date,
        sa.period_end_date,
        @today AS billing_period_start
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    CROSS APPLY (
        SELECT
            CASE sa.recurrence_cadence
                WHEN 'DAILY' THEN 1
                WHEN 'EVERY_N_DAYS' THEN
                    CASE WHEN ISNULL(sm.recurrence_interval_days, 0) > 0
                              AND DATEDIFF(DAY, sa.period_start_date, @today) % sm.recurrence_interval_days = 0
                         THEN 1 ELSE 0 END
                WHEN 'MONTHLY' THEN
                    CASE WHEN DATEADD(MONTH, DATEDIFF(MONTH, sa.period_start_date, @today), sa.period_start_date) = @today
                         THEN 1 ELSE 0 END
                WHEN 'QUARTERLY' THEN
                    CASE WHEN DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, @today) / 3) * 3, sa.period_start_date) = @today
                         THEN 1 ELSE 0 END
                WHEN 'HALF_YEARLY' THEN
                    CASE WHEN DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, @today) / 6) * 6, sa.period_start_date) = @today
                         THEN 1 ELSE 0 END
                WHEN 'YEARLY_FIXED_DATE' THEN
                    CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, sa.period_start_date, @today), sa.period_start_date) = @today
                         THEN 1 ELSE 0 END
                ELSE 0
            END AS is_boundary,
            -- the previous boundary date for this cadence, used only to scope
            -- the "already billed by a manual PR" check below
            CASE sa.recurrence_cadence
                WHEN 'DAILY'              THEN DATEADD(DAY,   -1, @today)
                WHEN 'EVERY_N_DAYS'       THEN DATEADD(DAY,   -ISNULL(sm.recurrence_interval_days, 1), @today)
                WHEN 'MONTHLY'            THEN DATEADD(MONTH, -1, @today)
                WHEN 'QUARTERLY'          THEN DATEADD(MONTH, -3, @today)
                WHEN 'HALF_YEARLY'        THEN DATEADD(MONTH, -6, @today)
                WHEN 'YEARLY_FIXED_DATE'  THEN DATEADD(YEAR,  -1, @today)
                ELSE sa.period_start_date
            END AS previous_boundary
    ) b
    WHERE sa.status = 'A' AND sa.is_active = 'Y'
      AND @today BETWEEN sa.period_start_date AND sa.period_end_date
      AND b.is_boundary = 1
      -- not already claimed/created by a previous run of this job
      AND NOT EXISTS (
          SELECT 1 FROM dbo.service_agreement_recurring_pr_log log
          WHERE log.agreement_sno = sa.agreement_sno AND log.billing_period_start = @today
      )
      -- not already billed this period by a manually-submitted PR (§4's
      -- auto-fill flow) — see file header
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.pr_item_details pid
          JOIN dbo.pr_basic_info pb ON pb.pr_basic_sno = pid.pr_basic_sno
          WHERE pid.agreement_sno = sa.agreement_sno
            AND pid.is_active = 'Y'
            AND pb.is_active = 'Y'
            AND pb.created_date > b.previous_boundary
      );
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM sys.tables WHERE name = 'service_agreement_recurring_pr_log';
--   SELECT name FROM sys.procedures WHERE name = 'sp_nt_GetAgreementsDueForRecurringPR';
--   EXEC dbo.sp_nt_GetAgreementsDueForRecurringPR; -- should return 0 rows on
--   an empty table, and correctly nothing until an Approved agreement's
--   period_start_date anniversary actually falls on today.
-- ============================================================
