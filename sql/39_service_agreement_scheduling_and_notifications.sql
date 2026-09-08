-- ============================================================
-- Service Agreement: explicit PO-generation day + notify-before-generation
-- reminders, plus a vendor picker for the new frontend
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/ServiceAgreement (existing), new
--            nt-frontend-stpl/src/Application/ServiceAgreement/* (this pass)
--
-- Why this is needed
-- ------------------
-- The Fixed Recurring engine (23_service_recurring_flow_redesign.sql) only
-- fires a MONTH-unit cadence on the calendar anniversary-day-of-month of
-- period_start_date — there was no way to say "generate on the 5th of every
-- month" independent of when the agreement happened to be signed. There was
-- also no reminder of any kind before a cycle auto-fires. This file adds
-- both, purely additively:
--   - service_agreement.po_generation_day (1-31, MONTH-unit cadences only) —
--     when set, sp_nt_ProcessDueRecurringServiceAgreements fires on that
--     explicit day instead of the start-date anniversary. NULL (every
--     pre-existing row, and any DAY-unit cadence) falls back to the exact
--     original anniversary predicate, unchanged — no backfill needed.
--   - service_agreement.notify_days_before + service_agreement_notification_log
--     + sp_nt_GetAgreementsDueForNotification/sp_nt_MarkAgreementNotificationSent
--     — an in-app "bell" reminder N days before a cycle fires. Delivery
--     itself (calling notification-service) is a Node-side change
--     (RecurringPrJob.js's new third sweep tick) — these procs only do the
--     claim-then-report SQL half, same split sp_nt_IssueRecurringServicePOCycle
--     already uses for PO issuance (the actual send is an HTTP call, so SQL
--     can't claim-and-send atomically).
--
-- sp_nt_GetApprovedVendorsForServicePicker is unrelated to the above but
-- ships in this same file since both are needed by the same new frontend
-- page. It's a NEW name, not a reuse of the sp_nt_GetApprovedVendors already
-- referenced by PurchaseTeam.repository.js — that proc has no definition
-- anywhere in this repo (only live on the DB server, unverifiable), so
-- reusing/overwriting its name risks breaking that unrelated call site
-- blind. Column names verified directly against live INFORMATION_SCHEMA.COLUMNS
-- (kyc_basic_info predates this repo's migration-file convention, same as
-- category_master/product_master — see reference-non-trade-codebase-conventions):
-- the checked-in sp_fetch_vendor_datas.sql assumes kyc_status/vendor_code/
-- mobile_no, none of which exist live; the real columns are status/supp_code/
-- mobile_number, and status='A' is "fully approved" (confirmed by reading
-- sp_approve_kyc_datas's live body — status flips to 'A' + supp_code gets
-- generated only at the final approval stage).
-- ============================================================

-- ── service_agreement: two new nullable columns ─────────────────────────────

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_agreement') AND name = 'po_generation_day')
    ALTER TABLE dbo.service_agreement ADD po_generation_day SMALLINT NULL
        CONSTRAINT CK_service_agreement_po_generation_day CHECK (po_generation_day IS NULL OR po_generation_day BETWEEN 1 AND 31);
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_agreement') AND name = 'notify_days_before')
    ALTER TABLE dbo.service_agreement ADD notify_days_before SMALLINT NULL
        CONSTRAINT CK_service_agreement_notify_days_before CHECK (notify_days_before IS NULL OR notify_days_before >= 0);
GO

-- ── service_agreement_notification_log ──────────────────────────────────────
-- Claim-then-report idempotency table, mirrors service_agreement_recurring_pr_log
-- (13_recurring_pr_job.sql / 23_service_recurring_flow_redesign.sql). The
-- unique key is the FUTURE billing_period_start being notified about (not
-- "today"), so it naturally fires once per cycle regardless of when the
-- sweep happens to run within the notify window.

IF OBJECT_ID('dbo.service_agreement_notification_log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_agreement_notification_log (
        log_sno              INT IDENTITY(1,1) PRIMARY KEY,
        agreement_sno        INT NOT NULL,
        billing_period_start DATE NOT NULL,
        status               VARCHAR(20) NOT NULL DEFAULT 'PENDING',
        notif_sno            INT NULL,
        error_message        NVARCHAR(500) NULL,
        created_at           DATETIME NOT NULL DEFAULT GETDATE(),
        modified_at          DATETIME NULL,
        CONSTRAINT UQ_service_agreement_notification_log UNIQUE (agreement_sno, billing_period_start),
        CONSTRAINT FK_service_agreement_notification_log_agreement FOREIGN KEY (agreement_sno)
            REFERENCES dbo.service_agreement (agreement_sno),
        CONSTRAINT CK_service_agreement_notification_log_status CHECK (status IN ('PENDING', 'SENT', 'FAILED'))
    );
END;
GO

-- ============================================================
-- sp_nt_CreateServiceAgreement v5 — adds po_generation_day/notify_days_before.
-- Same shape as v4 (10_service_agreement.sql -> 23_service_recurring_flow_redesign.sql),
-- see that file for the unchanged parts' rationale.
-- @jsonInput adds: po_generation_day?, notify_days_before?
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateServiceAgreement', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateServiceAgreement;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @com_sno              INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno              INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno              INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno             INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @service_sno          INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @vendor_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @rate_amount          DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @rate_uom_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_uom_sno') AS INT);
        DECLARE @ceiling_amount       DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @variance_tolerance_pct DECIMAL(5,2)= TRY_CAST(JSON_VALUE(@jsonInput, '$.variance_tolerance_pct') AS DECIMAL(5,2));
        DECLARE @recurrence_cadence   VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.recurrence_cadence');
        DECLARE @recurrence_cadence_sno INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_cadence_sno') AS INT);
        DECLARE @po_generation_day    SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_generation_day') AS SMALLINT);
        DECLARE @notify_days_before   SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.notify_days_before') AS SMALLINT);
        DECLARE @period_start_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date      DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url    NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks              NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @created_by           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @service_sno IS NULL OR @created_by IS NULL
            THROW 53001, 'com_sno, div_sno, brn_sno, dept_sno, service_sno and created_by are required.', 1;

        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 53003, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;

        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 53004, 'agreement_doc_url is required — upload the agreement document before submitting.', 1;

        -- ── Resolve recurrence cadence against the master (mandatory) ──────
        IF @recurrence_cadence_sno IS NULL AND @recurrence_cadence IS NOT NULL
            SELECT @recurrence_cadence_sno = recurrence_cadence_sno
            FROM dbo.recurrence_cadence_master
            WHERE cadence_code = @recurrence_cadence AND is_active = 'Y';

        IF @recurrence_cadence_sno IS NULL
            THROW 53020, 'recurrence_cadence_sno (or a matching recurrence_cadence code) is required — see sp_nt_GetRecurrenceCadenceRecords for valid options.', 1;

        DECLARE @interval_unit VARCHAR(10);
        SELECT @recurrence_cadence = cadence_code, @interval_unit = interval_unit
        FROM dbo.recurrence_cadence_master
        WHERE recurrence_cadence_sno = @recurrence_cadence_sno AND is_active = 'Y';

        IF @recurrence_cadence IS NULL
            THROW 53021, 'recurrence_cadence_sno does not reference an active recurrence cadence.', 1;

        DECLARE @service_type_code VARCHAR(30), @is_recurring BIT;
        SELECT @service_type_code = st.service_type_code,
               @is_recurring      = sm.is_recurring
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';

        IF @service_type_code IS NULL
            THROW 53005, 'Unknown or inactive service_sno.', 1;

        IF ISNULL(@is_recurring, 0) = 0 OR @service_type_code NOT IN ('FIXED_RECURRING', 'VARIABLE_RECURRING')
            THROW 53006, 'service_sno must reference an active Fixed Recurring or Variable Recurring, recurring service.', 1;

        -- Branch by billing pattern: Fixed Recurring authorizes a rate,
        -- Variable Recurring authorizes a ceiling + tolerance.
        IF @service_type_code = 'FIXED_RECURRING'
        BEGIN
            IF @rate_amount IS NULL OR @rate_amount <= 0
                THROW 53002, 'rate_amount must be a positive amount.', 1;

            -- po_generation_day only means something for a MONTH-unit cadence
            -- (a DAY-unit cadence like FIFTEEN_DAYS counts elapsed days from
            -- period_start_date, not a calendar day-of-month) — required
            -- there so every new agreement has an explicit trigger day
            -- rather than silently depending on the anniversary fallback.
            IF @interval_unit = 'MONTH'
            BEGIN
                IF @po_generation_day IS NULL OR @po_generation_day NOT BETWEEN 1 AND 31
                    THROW 53022, 'po_generation_day (1-31) is required for a Fixed Recurring agreement on a monthly-family cadence.', 1;
            END
            ELSE
                SET @po_generation_day = NULL;

            IF @notify_days_before IS NOT NULL AND @notify_days_before < 0
                THROW 53023, 'notify_days_before must not be negative.', 1;
        END
        ELSE -- VARIABLE_RECURRING
        BEGIN
            IF @ceiling_amount IS NULL OR @ceiling_amount <= 0
                THROW 53010, 'ceiling_amount must be a positive amount for a Variable Recurring agreement.', 1;
            IF @variance_tolerance_pct IS NULL
                THROW 53011, 'variance_tolerance_pct is required for a Variable Recurring agreement.', 1;

            -- Neither field applies — Variable Recurring is invoice-driven
            -- (service_bill_request), never swept by
            -- sp_nt_ProcessDueRecurringServiceAgreements. Force NULL
            -- regardless of what the client sent.
            SET @po_generation_day  = NULL;
            SET @notify_days_before = NULL;
        END

        -- ── Resolve the ServiceAgreement workflow for this org scope ───────
        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);

        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceAgreement';

        IF @workflow_types_id IS NULL
            THROW 53007, 'No ServiceAgreement workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key] = '0' AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 53008, 'No approver found for the first stage of the ServiceAgreement workflow.', 1;

        -- ── Number: AGR-YYYY-NNNN, same scheme as ServicePO's SVO-YYYY-NNNN ─
        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(agreement_no, 4) AS INT)), 0) + 1
        FROM dbo.service_agreement WITH (UPDLOCK, HOLDLOCK)
        WHERE agreement_no LIKE 'AGR-' + @year + '-%';
        DECLARE @agreement_no VARCHAR(30) = 'AGR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.service_agreement (
            agreement_no, com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
            rate_amount, rate_uom_sno, ceiling_amount, variance_tolerance_pct,
            recurrence_cadence, recurrence_cadence_sno, po_generation_day, notify_days_before,
            period_start_date, period_end_date,
            agreement_doc_url, remarks, workflow_types_id, current_approver_id, status,
            is_active, created_by
        )
        VALUES (
            @agreement_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @service_sno, @vendor_sno,
            @rate_amount, @rate_uom_sno, @ceiling_amount, @variance_tolerance_pct,
            @recurrence_cadence, @recurrence_cadence_sno, @po_generation_day, @notify_days_before,
            @period_start_date, @period_end_date,
            @agreement_doc_url, @remarks, @workflow_types_id, @first_approver, 'P',
            'Y', @created_by
        );

        DECLARE @agreement_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, is_active)
        VALUES (@agreement_sno, 'SUBMITTED', @created_by, NULL, 'Y');

        COMMIT TRANSACTION;

        SELECT
            @agreement_sno AS agreement_sno,
            @agreement_no  AS agreement_no,
            'SUCCESS'      AS result,
            N'Service agreement submitted for approval.' AS message;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- sp_nt_ProcessDueRecurringServiceAgreements v3 — only the WHERE predicate
-- changes from v2 (23_service_recurring_flow_redesign.sql); everything else
-- (the cursor over @due calling sp_nt_IssueRecurringServicePOCycle per row)
-- is byte-for-byte unchanged. The old single MONTH expression conflated two
-- independent tests (which months are eligible, and which day within that
-- month) — DATEADD(MONTH, (DATEDIFF(MONTH,start,today)/interval)*interval,
-- start) = today is algebraically true iff months-since-start % interval = 0
-- AND today's day-of-month = start's day-of-month. Split so the day-test can
-- be overridden by an explicit po_generation_day while month-eligibility
-- stays untouched. The EOMONTH clamp (po_generation_day > days in this
-- month -> fire on the month's last day instead) and the unclamped exact
-- match are mutually exclusive by construction, so exactly one firing day
-- per eligible month either way.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ProcessDueRecurringServiceAgreements', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_ProcessDueRecurringServiceAgreements;
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
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    WHERE sa.status = 'A' AND sa.is_active = 'Y' AND st.service_type_code = 'FIXED_RECURRING'
      AND @today BETWEEN sa.period_start_date AND sa.period_end_date
      AND (
            -- DAY-unit cadences (e.g. FIFTEEN_DAYS): unchanged.
            (rc.interval_unit = 'DAY' AND DATEDIFF(DAY, sa.period_start_date, @today) % rc.interval_value = 0)

            -- MONTH-unit, explicit po_generation_day set: NEW branch.
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NOT NULL
             AND DATEDIFF(MONTH, sa.period_start_date, @today) % rc.interval_value = 0
             AND (DAY(@today) = sa.po_generation_day
                  OR (sa.po_generation_day > DAY(EOMONTH(@today)) AND @today = EOMONTH(@today))))

            -- MONTH-unit, no po_generation_day (pre-existing agreements from
            -- before this file, or any future one that leaves it unset on a
            -- DAY-unit cadence's sibling path): original anniversary predicate, unchanged.
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NULL
             AND DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, @today) / rc.interval_value) * rc.interval_value, sa.period_start_date) = @today)
          )
      AND NOT EXISTS (
          SELECT 1 FROM dbo.service_agreement_recurring_pr_log l
          WHERE l.agreement_sno = sa.agreement_sno AND l.billing_period_start = @today
      );

    DECLARE @agreement_sno INT, @billing_period_start DATE;
    DECLARE @success_count INT = 0, @skipped_count INT = 0, @failed_count INT = 0;
    DECLARE @row_result VARCHAR(30), @row_po INT, @row_po_no VARCHAR(50), @row_pr INT, @row_pr_no VARCHAR(20), @rowJson NVARCHAR(MAX);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT agreement_sno, billing_period_start FROM @due;
    OPEN cur;
    FETCH NEXT FROM cur INTO @agreement_sno, @billing_period_start;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @rowJson = (
            SELECT @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start, 'SYSTEM' AS issued_by
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC dbo.sp_nt_IssueRecurringServicePOCycle
            @jsonInput = @rowJson, @silent = 1,
            @out_result = @row_result OUTPUT, @out_po_basic_sno = @row_po OUTPUT, @out_po_no = @row_po_no OUTPUT,
            @out_pr_basic_sno = @row_pr OUTPUT, @out_pr_no = @row_pr_no OUTPUT;

        IF @row_result = 'SUCCESS'
            SET @success_count = @success_count + 1;
        ELSE IF @row_result LIKE 'SKIPPED%'
            SET @skipped_count = @skipped_count + 1;
        ELSE
            SET @failed_count = @failed_count + 1;

        FETCH NEXT FROM cur INTO @agreement_sno, @billing_period_start;
    END
    CLOSE cur;
    DEALLOCATE cur;

    SELECT
        (SELECT COUNT(*) FROM @due) AS due_count,
        @success_count AS success_count,
        @skipped_count AS skipped_count,
        @failed_count  AS failed_count;
END;
GO

-- ============================================================
-- sp_nt_GetAgreementsDueForNotification — re-evaluates the exact predicate
-- above with (@today + notify_days_before) substituted for @today, bounded
-- by the agreement's own period, checked against
-- service_agreement_notification_log instead of the PR log (a distinct
-- concern — a reminder firing doesn't imply the PR/PO log has anything for
-- that future date yet). Claims each due row as PENDING before returning it
-- (cursor, not one set-based INSERT, so one row's unique-key collision can't
-- abort the batch and silently drop every other agreement's reminder) —
-- only successfully-claimed rows come back to the caller.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetAgreementsDueForNotification', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetAgreementsDueForNotification;
GO
CREATE PROCEDURE dbo.sp_nt_GetAgreementsDueForNotification
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @today DATE = CAST(GETDATE() AS DATE);

    DECLARE @due TABLE (
        agreement_sno INT, agreement_no VARCHAR(30), notify_ecno VARCHAR(20),
        service_name NVARCHAR(200), rate_amount DECIMAL(18,2),
        po_generation_day SMALLINT, notify_days_before SMALLINT, due_date DATE
    );

    INSERT INTO @due (agreement_sno, agreement_no, notify_ecno, service_name, rate_amount, po_generation_day, notify_days_before, due_date)
    SELECT sa.agreement_sno, sa.agreement_no, sa.created_by, sm.service_name, sa.rate_amount,
           sa.po_generation_day, sa.notify_days_before, t.target_date
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    CROSS APPLY (SELECT DATEADD(DAY, sa.notify_days_before, @today) AS target_date) t
    WHERE sa.status = 'A' AND sa.is_active = 'Y' AND st.service_type_code = 'FIXED_RECURRING'
      AND ISNULL(sa.notify_days_before, 0) > 0
      AND t.target_date BETWEEN sa.period_start_date AND sa.period_end_date
      AND (
            (rc.interval_unit = 'DAY' AND DATEDIFF(DAY, sa.period_start_date, t.target_date) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NOT NULL
             AND DATEDIFF(MONTH, sa.period_start_date, t.target_date) % rc.interval_value = 0
             AND (DAY(t.target_date) = sa.po_generation_day
                  OR (sa.po_generation_day > DAY(EOMONTH(t.target_date)) AND t.target_date = EOMONTH(t.target_date))))
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NULL
             AND DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, t.target_date) / rc.interval_value) * rc.interval_value, sa.period_start_date) = t.target_date)
          )
      AND NOT EXISTS (
          SELECT 1 FROM dbo.service_agreement_notification_log l
          WHERE l.agreement_sno = sa.agreement_sno AND l.billing_period_start = t.target_date
      );

    DECLARE @agreement_sno INT, @due_date DATE;
    DECLARE @claimed TABLE (
        agreement_sno INT, agreement_no VARCHAR(30), notify_ecno VARCHAR(20),
        service_name NVARCHAR(200), rate_amount DECIMAL(18,2),
        po_generation_day SMALLINT, notify_days_before SMALLINT, due_date DATE
    );

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT agreement_sno, due_date FROM @due;
    OPEN cur;
    FETCH NEXT FROM cur INTO @agreement_sno, @due_date;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.service_agreement_notification_log (agreement_sno, billing_period_start, status)
            VALUES (@agreement_sno, @due_date, 'PENDING');

            INSERT INTO @claimed
            SELECT agreement_sno, agreement_no, notify_ecno, service_name, rate_amount, po_generation_day, notify_days_before, due_date
            FROM @due
            WHERE agreement_sno = @agreement_sno AND due_date = @due_date;
        END TRY
        BEGIN CATCH
            -- UNIQUE violation: another sweep already claimed this slot this
            -- run — skip silently, same as the PR log's claim pattern.
        END CATCH

        FETCH NEXT FROM cur INTO @agreement_sno, @due_date;
    END
    CLOSE cur;
    DEALLOCATE cur;

    SELECT agreement_sno, agreement_no, notify_ecno, service_name, rate_amount,
           po_generation_day, notify_days_before, due_date
    FROM @claimed;
END;
GO

-- ============================================================
-- sp_nt_MarkAgreementNotificationSent — flips a claimed PENDING row to
-- SENT/FAILED after Node actually calls notification-service. Necessarily
-- separate from the claim proc above: the send is an HTTP call only Node
-- can make, so SQL can't claim-and-send atomically the way
-- sp_nt_IssueRecurringServicePOCycle does for pure-SQL PO issuance.
-- @jsonInput: { agreement_sno, billing_period_start, status: 'SENT'|'FAILED',
--   notif_sno?, error_message? }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_MarkAgreementNotificationSent', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_MarkAgreementNotificationSent;
GO
CREATE PROCEDURE dbo.sp_nt_MarkAgreementNotificationSent
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @agreement_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
    DECLARE @billing_period_start DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.billing_period_start') AS DATE);
    DECLARE @status               VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @notif_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.notif_sno') AS INT);
    DECLARE @error_message        NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.error_message');

    IF @agreement_sno IS NULL OR @billing_period_start IS NULL OR @status NOT IN ('SENT', 'FAILED')
        THROW 53024, 'agreement_sno, billing_period_start and a status of SENT or FAILED are required.', 1;

    UPDATE dbo.service_agreement_notification_log
    SET status = @status, notif_sno = @notif_sno, error_message = @error_message, modified_at = GETDATE()
    WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start AND status = 'PENDING';

    SELECT @@ROWCOUNT AS rows_updated;
END;
GO

-- ============================================================
-- sp_nt_GetServiceAgreements v2 — adds po_generation_day/notify_days_before
-- to the SELECT list (list screen should show what's configured). Filter
-- logic unchanged from v1 (10_service_agreement.sql).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServiceAgreements', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetServiceAgreements;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceAgreements
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL,
            @service_sno INT = NULL, @status VARCHAR(1) = NULL, @vendor_sno INT = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @com_sno     = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno     = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno     = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno    = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        SET @service_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        SET @status      = JSON_VALUE(@jsonInput, '$.status');
        SET @vendor_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    END

    SELECT
        sa.agreement_sno,
        sa.agreement_no,
        sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
        sa.service_sno,
        sm.service_name,
        st.service_type_code,
        sa.vendor_sno,
        k.company_name        AS vendor_name,
        sa.rate_amount,
        sa.rate_uom_sno,
        um.uom_name            AS rate_uom_name,
        sa.ceiling_amount,
        sa.variance_tolerance_pct,
        sa.recurrence_cadence,
        sa.po_generation_day,
        sa.notify_days_before,
        sa.period_start_date,
        sa.period_end_date,
        sa.agreement_doc_url,
        sa.remarks,
        sa.workflow_types_id,
        sa.current_approver_id,
        sa.status,
        sa.created_by,
        sa.created_at
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm      ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.uom_master um      ON um.uom_sno = sa.rate_uom_sno
    LEFT JOIN dbo.kyc_basic_info k   ON k.kyc_basic_info_sno = sa.vendor_sno
    WHERE sa.is_active = 'Y'
      AND (@com_sno IS NULL OR sa.com_sno = @com_sno)
      AND (@div_sno IS NULL OR sa.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR sa.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR sa.dept_sno = @dept_sno)
      AND (@service_sno IS NULL OR sa.service_sno = @service_sno)
      AND (@status IS NULL OR sa.status = @status)
      AND (@vendor_sno IS NULL OR sa.vendor_sno = @vendor_sno)
    ORDER BY sa.agreement_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetServiceAgreementsForApproval v2 — adds po_generation_day/
-- notify_days_before to the SELECT list. Everything else unchanged from v1
-- (10_service_agreement.sql).
-- @Ecno VARCHAR(50)
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServiceAgreementsForApproval', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetServiceAgreementsForApproval;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceAgreementsForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        sa.agreement_sno,
        sa.agreement_no,
        sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
        sa.service_sno,
        sm.service_name,
        sa.vendor_sno,
        k.company_name     AS vendor_name,
        sa.rate_amount,
        sa.rate_uom_sno,
        um.uom_name          AS rate_uom_name,
        sa.ceiling_amount,
        sa.variance_tolerance_pct,
        sa.recurrence_cadence,
        sa.po_generation_day,
        sa.notify_days_before,
        sa.period_start_date,
        sa.period_end_date,
        sa.agreement_doc_url,
        sa.remarks,
        sa.workflow_types_id,
        sa.current_approver_id,
        sa.status,
        (
            SELECT ws.stage_order_json
            FROM dbo.workflow_stage ws
            WHERE ws.workflow_types_id = sa.workflow_types_id AND ws.is_active = 'Y'
        ) AS stage_order_json
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm     ON sm.service_sno = sa.service_sno
    LEFT JOIN dbo.uom_master um     ON um.uom_sno = sa.rate_uom_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = sa.vendor_sno
    WHERE sa.current_approver_id = @Ecno
      AND sa.status = 'P'
      AND sa.is_active = 'Y'
    ORDER BY sa.agreement_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetApprovedVendorsForServicePicker — {label,value}-shaped vendor list
-- for the new frontend's search-select (wired into CommonMasterRepo.js as
-- 'VendorMaster'). See header comment for why this is a new proc, not a
-- reuse of the unverifiable sp_nt_GetApprovedVendors.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetApprovedVendorsForServicePicker', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetApprovedVendorsForServicePicker;
GO
CREATE PROCEDURE dbo.sp_nt_GetApprovedVendorsForServicePicker
AS
BEGIN
    SET NOCOUNT ON;

    SELECT kyc_basic_info_sno, company_name, supp_code, email, mobile_number
    FROM dbo.kyc_basic_info
    WHERE status = 'A' AND is_active = 'Y'
    ORDER BY company_name;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_agreement') AND name IN ('po_generation_day','notify_days_before');
--   SELECT OBJECT_ID('dbo.service_agreement_notification_log');
--   SELECT OBJECT_ID('dbo.sp_nt_CreateServiceAgreement'), OBJECT_ID('dbo.sp_nt_ProcessDueRecurringServiceAgreements'),
--          OBJECT_ID('dbo.sp_nt_GetAgreementsDueForNotification'), OBJECT_ID('dbo.sp_nt_MarkAgreementNotificationSent'),
--          OBJECT_ID('dbo.sp_nt_GetApprovedVendorsForServicePicker');
--   EXEC dbo.sp_nt_ProcessDueRecurringServiceAgreements;   -- should return 0 due_count, no error
--   EXEC dbo.sp_nt_GetAgreementsDueForNotification;        -- should return zero rows, no error
-- ============================================================
