-- ============================================================
-- 103: Service PO date alerts (Fixed + Unfixed) -- real-time bell notifications
-- Database: Non_trade_Dev (MSSQL). Re-runnable.
--
-- For every Fixed / Unfixed Service Agreement cycle, on
--   (a) the NOTIFICATION date  (PO date - notify_days_before),
--   (b) the PO date            (billing_period_start of the cycle), and
--   (c) EVERY DAY after the PO date while the PO is still not raised (OVERDUE,
--       carries days_late)
-- tell BOTH the ServicePO approver AND the PO-raising department.
--
-- "PO-raising department" = the agreement's creator + every active user who holds the
-- Service Purchase Orders screen (ServicePoPage) and whose org hierarchy covers the
-- agreement's company/division/branch (dept only matters when the hierarchy row has one).
-- Approver = the cycle's current approver, else the first approver of the ServicePO workflow.
-- "Not raised yet" = the cycle is PENDING_ENTRY or PENDING_APPROVAL.
-- Statutory (loan) agreements never raise POs, so they are excluded.
--
-- sp_nt_ClaimServicePoAlerts CLAIMS each alert (one row per agreement/period/kind/day in
-- service_po_alert_log) before returning it, so two sweeps can never double-send; a FAILED
-- claim from earlier today is re-claimed (retried) on the next sweep.
-- ============================================================

IF OBJECT_ID('dbo.service_po_alert_log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_po_alert_log (
        alert_sno            INT IDENTITY(1,1) PRIMARY KEY,
        agreement_sno        INT          NOT NULL,
        billing_period_start DATE         NOT NULL,
        alert_kind           VARCHAR(12)  NOT NULL,   -- NOTIFY_DATE | PO_DATE | OVERDUE
        alert_date           DATE         NOT NULL,   -- the day it was raised (OVERDUE repeats daily)
        cycle_sno            INT          NULL,
        days_late            INT          NULL,
        status               VARCHAR(10)  NOT NULL DEFAULT 'PENDING',  -- PENDING | SENT | FAILED
        recipient_count      INT          NULL,
        error_message        NVARCHAR(500) NULL,
        created_at           DATETIME     NOT NULL DEFAULT GETDATE(),
        modified_at          DATETIME     NULL,
        CONSTRAINT CK_service_po_alert_kind CHECK (alert_kind IN ('NOTIFY_DATE','PO_DATE','OVERDUE')),
        CONSTRAINT CK_service_po_alert_status CHECK (status IN ('PENDING','SENT','FAILED')),
        CONSTRAINT UQ_service_po_alert UNIQUE (agreement_sno, billing_period_start, alert_kind, alert_date)
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_ClaimServicePoAlerts
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);

    CREATE TABLE #cand (
        agreement_sno INT, billing_period_start DATE, alert_kind VARCHAR(12), cycle_sno INT NULL, days_late INT NULL
    );

    -- (a) notification date: today = a cycle date - notify_days_before (same cadence maths as
    --     sp_nt_GetAgreementsDueForNotification, minus loans).
    INSERT INTO #cand (agreement_sno, billing_period_start, alert_kind)
    SELECT sa.agreement_sno, t.target_date, 'NOTIFY_DATE'
    FROM dbo.service_agreement sa
    JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    CROSS APPLY (SELECT DATEADD(DAY, sa.notify_days_before, @today) AS target_date) t
    WHERE sa.status = 'A' AND sa.is_active = 'Y' AND ISNULL(sa.notify_days_before, 0) > 0
      AND st.service_type_code <> 'STATUTORY'
      AND t.target_date BETWEEN sa.period_start_date AND sa.period_end_date
      AND (
            (rc.interval_unit = 'DAY' AND DATEDIFF(DAY, sa.period_start_date, t.target_date) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NOT NULL
             AND DAY(t.target_date) = CASE WHEN sa.po_generation_day > DAY(EOMONTH(t.target_date)) THEN DAY(EOMONTH(t.target_date)) ELSE sa.po_generation_day END
             AND DATEDIFF(MONTH, sa.period_start_date, t.target_date) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NULL
             AND DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, t.target_date) / rc.interval_value) * rc.interval_value, sa.period_start_date) = t.target_date)
          );

    -- (b) PO date: the cycle for today exists but its PO isn't raised yet.
    INSERT INTO #cand (agreement_sno, billing_period_start, alert_kind, cycle_sno)
    SELECT c.agreement_sno, c.billing_period_start, 'PO_DATE', c.cycle_sno
    FROM dbo.service_po_cycle c
    WHERE c.billing_period_start = @today AND c.status IN ('PENDING_ENTRY', 'PENDING_APPROVAL');

    -- (c) overdue: PO date already passed and the PO is still not raised -> daily, with days_late.
    INSERT INTO #cand (agreement_sno, billing_period_start, alert_kind, cycle_sno, days_late)
    SELECT c.agreement_sno, c.billing_period_start, 'OVERDUE', c.cycle_sno, DATEDIFF(DAY, c.billing_period_start, @today)
    FROM dbo.service_po_cycle c
    WHERE c.billing_period_start < @today AND c.status IN ('PENDING_ENTRY', 'PENDING_APPROVAL');

    -- Claim. A retry of today's FAILED rows first, then brand-new rows.
    CREATE TABLE #claimed (alert_sno INT PRIMARY KEY);

    UPDATE l SET status = 'PENDING', error_message = NULL, modified_at = GETDATE()
    OUTPUT inserted.alert_sno INTO #claimed (alert_sno)
    FROM dbo.service_po_alert_log l
    WHERE l.status = 'FAILED' AND l.alert_date = @today;

    BEGIN TRY
        INSERT INTO dbo.service_po_alert_log (agreement_sno, billing_period_start, alert_kind, alert_date, cycle_sno, days_late, status)
        OUTPUT inserted.alert_sno INTO #claimed (alert_sno)
        SELECT c.agreement_sno, c.billing_period_start, c.alert_kind, @today, c.cycle_sno, c.days_late, 'PENDING'
        FROM #cand c
        WHERE NOT EXISTS (SELECT 1 FROM dbo.service_po_alert_log l
                          WHERE l.agreement_sno = c.agreement_sno AND l.billing_period_start = c.billing_period_start
                            AND l.alert_kind = c.alert_kind AND l.alert_date = @today);
    END TRY
    BEGIN CATCH
        -- Unique-key collision with a concurrent sweep: it owns those rows; the next sweep re-checks.
        IF ERROR_NUMBER() NOT IN (2601, 2627) THROW;
    END CATCH

    -- Recipients: approver (role APPROVER) + PO-raising department (role RAISER).
    CREATE TABLE #rcpt (alert_sno INT, ecno VARCHAR(50), role VARCHAR(10));

    DECLARE @a_sno INT, @com INT, @div INT, @brn INT, @dept INT, @cyc_approver VARCHAR(30), @created_by VARCHAR(50),
            @wf INT, @first VARCHAR(30);
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT l.alert_sno, sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno, c.current_approver_id, sa.created_by
        FROM #claimed cl
        JOIN dbo.service_po_alert_log l ON l.alert_sno = cl.alert_sno
        JOIN dbo.service_agreement sa ON sa.agreement_sno = l.agreement_sno
        LEFT JOIN dbo.service_po_cycle c ON c.cycle_sno = l.cycle_sno;
    OPEN cur;
    FETCH NEXT FROM cur INTO @a_sno, @com, @div, @brn, @dept, @cyc_approver, @created_by;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @first = @cyc_approver;
        IF @first IS NULL
        BEGIN
            BEGIN TRY
                SET @wf = NULL;
                EXEC dbo.sp_nt_ResolveServicePoWorkflow @com_sno = @com, @div_sno = @div, @brn_sno = @brn, @dept_sno = @dept,
                     @workflow_types_id = @wf OUTPUT, @first_approver = @first OUTPUT;
            END TRY
            BEGIN CATCH
                SET @first = NULL;   -- no ServicePO workflow configured: nobody to tell on the approver side
            END CATCH
        END
        IF @first IS NOT NULL INSERT INTO #rcpt (alert_sno, ecno, role) VALUES (@a_sno, @first, 'APPROVER');

        INSERT INTO #rcpt (alert_sno, ecno, role)
        SELECT @a_sno, x.ecno, 'RAISER'
        FROM (
            SELECT @created_by AS ecno
            UNION
            SELECT COALESCE(p.ecno, p.login_id)
            FROM dbo.nt_user_permissions_json p
            WHERE p.is_active = 'Y'
              AND EXISTS (SELECT 1 FROM OPENJSON(p.screens_json) WITH (screen_id INT '$.screen_id') s
                          JOIN dbo.screens sc ON sc.screen_id = s.screen_id AND sc.comp = 'ServicePoPage')
              AND EXISTS (SELECT 1 FROM OPENJSON(p.hierarchy_json)
                                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno', dept_sno INT '$.dept_sno') h
                          WHERE h.com_sno = @com
                            AND (h.div_sno IS NULL OR h.div_sno = @div)
                            AND (h.brn_sno IS NULL OR h.brn_sno = @brn)
                            AND (h.dept_sno IS NULL OR h.dept_sno = @dept))
        ) x
        WHERE x.ecno IS NOT NULL;

        FETCH NEXT FROM cur INTO @a_sno, @com, @div, @brn, @dept, @cyc_approver, @created_by;
    END
    CLOSE cur;
    DEALLOCATE cur;

    -- One row per (alert, person); a person who is both approver and raiser hears once, as approver.
    SELECT l.alert_sno, l.alert_kind, l.agreement_sno, sa.agreement_no, l.cycle_sno,
           sm.service_name, st.service_type_code, l.billing_period_start AS due_date, l.days_late,
           c.status AS cycle_status, c.pr_no,
           r.ecno AS recipient_ecno, r.role AS recipient_role
    FROM (SELECT alert_sno, ecno, MIN(role) AS role FROM #rcpt GROUP BY alert_sno, ecno) r   -- 'APPROVER' < 'RAISER'
    JOIN dbo.service_po_alert_log l ON l.alert_sno = r.alert_sno
    JOIN dbo.service_agreement sa ON sa.agreement_sno = l.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.service_po_cycle c ON c.cycle_sno = l.cycle_sno
    ORDER BY l.alert_sno, r.role;

    -- Claimed alerts with nobody to tell are closed out here so they never sit PENDING.
    UPDATE l SET status = 'SENT', recipient_count = 0, modified_at = GETDATE()
    FROM dbo.service_po_alert_log l
    WHERE l.alert_sno IN (SELECT alert_sno FROM #claimed)
      AND NOT EXISTS (SELECT 1 FROM #rcpt r WHERE r.alert_sno = l.alert_sno);
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_MarkServicePoAlertSent
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.service_po_alert_log
    SET status = CASE WHEN JSON_VALUE(@jsonInput, '$.status') = 'SENT' THEN 'SENT' ELSE 'FAILED' END,
        recipient_count = TRY_CAST(JSON_VALUE(@jsonInput, '$.recipient_count') AS INT),
        error_message = LEFT(JSON_VALUE(@jsonInput, '$.error_message'), 500),
        modified_at = GETDATE()
    WHERE alert_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.alert_sno') AS INT);
END;
GO
