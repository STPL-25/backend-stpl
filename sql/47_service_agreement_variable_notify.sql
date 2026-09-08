-- ============================================================
-- Unfixed (Variable) Recurring: allow notify_days_before
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/ServiceAgreement (existing)
--
-- Why this is needed
-- ------------------
-- sp_nt_CreateServiceAgreement v5 (39_service_agreement_scheduling_and_
-- notifications.sql) force-NULLs notify_days_before for VARIABLE_RECURRING
-- unconditionally, even though the column itself has no type restriction —
-- only the create proc enforces it. The user asked for Unfixed Recurring to
-- also get a bell reminder. Since Variable Recurring is invoice-driven (no
-- auto-PO, no po_generation_day concept — the user submits a Service Bill
-- Request each cycle), "due" here means "remind N days before the next
-- expected billing-cycle boundary" so the user remembers to submit it —
-- reusing the exact cadence-anniversary math already proven in
-- sp_nt_ProcessDueRecurringServiceAgreements, just without the
-- po_generation_day branch (meaningless for this type, stays NULL).
--
-- sp_nt_GetAgreementsDueForNotification hardcoded
-- service_type_code = 'FIXED_RECURRING' and reused po_generation_day/
-- anniversary math specific to that type — v2 below drops the hardcoded
-- filter and adds a parallel, simpler predicate for VARIABLE_RECURRING.
-- RecurringPrJob.js's runAgreementNotificationSweep() needs no change — it
-- already calls this SP generically and creates a notification per row
-- returned, regardless of which type produced it.
-- ============================================================

-- ============================================================
-- sp_nt_CreateServiceAgreement v6 — only the VARIABLE_RECURRING branch
-- changes from v5 (39_...sql): notify_days_before is now validated (>=0)
-- and kept instead of forced NULL. po_generation_day stays force-NULL for
-- this type — still meaningless, there's no auto-PO date to speak of.
-- Everything else byte-for-byte unchanged from v5.
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

            -- po_generation_day still doesn't apply — no auto-PO date for
            -- this type. notify_days_before now DOES apply (this is the
            -- change from v5): the bell reminds the user before the next
            -- expected billing cycle so they remember to submit a Service
            -- Bill Request. Validated the same way as Fixed Recurring's.
            SET @po_generation_day = NULL;

            IF @notify_days_before IS NOT NULL AND @notify_days_before < 0
                THROW 53023, 'notify_days_before must not be negative.', 1;
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
-- sp_nt_GetAgreementsDueForNotification v2 — drops the hardcoded
-- service_type_code = 'FIXED_RECURRING' filter. FIXED_RECURRING keeps its
-- exact po_generation_day/anniversary predicate from v1 (39_...sql), unchanged.
-- VARIABLE_RECURRING gets a parallel, simpler cadence-anniversary predicate
-- (no po_generation_day branch — stays NULL for this type by design). Claim-
-- then-report idempotency (service_agreement_notification_log) unchanged.
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
    WHERE sa.status = 'A' AND sa.is_active = 'Y'
      AND st.service_type_code IN ('FIXED_RECURRING', 'VARIABLE_RECURRING')
      AND ISNULL(sa.notify_days_before, 0) > 0
      AND t.target_date BETWEEN sa.period_start_date AND sa.period_end_date
      AND (
            (st.service_type_code = 'FIXED_RECURRING' AND (
                  (rc.interval_unit = 'DAY' AND DATEDIFF(DAY, sa.period_start_date, t.target_date) % rc.interval_value = 0)
               OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NOT NULL
                   AND DATEDIFF(MONTH, sa.period_start_date, t.target_date) % rc.interval_value = 0
                   AND (DAY(t.target_date) = sa.po_generation_day
                        OR (sa.po_generation_day > DAY(EOMONTH(t.target_date)) AND t.target_date = EOMONTH(t.target_date))))
               OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NULL
                   AND DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, t.target_date) / rc.interval_value) * rc.interval_value, sa.period_start_date) = t.target_date)
            ))
            OR
            (st.service_type_code = 'VARIABLE_RECURRING' AND (
                  (rc.interval_unit = 'DAY' AND DATEDIFF(DAY, sa.period_start_date, t.target_date) % rc.interval_value = 0)
               OR (rc.interval_unit = 'MONTH' AND DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, t.target_date) / rc.interval_value) * rc.interval_value, sa.period_start_date) = t.target_date)
            ))
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
-- After running, confirm:
--   EXEC dbo.sp_nt_GetAgreementsDueForNotification;  -- should return cleanly, no error
--   -- create a VARIABLE_RECURRING agreement with notify_days_before set and
--   -- confirm it round-trips (not forced NULL):
--   SELECT agreement_sno, recurrence_cadence, notify_days_before, po_generation_day
--   FROM dbo.service_agreement sa
--   JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
--   JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
--   WHERE st.service_type_code = 'VARIABLE_RECURRING'
--   ORDER BY agreement_sno DESC;
-- ============================================================
