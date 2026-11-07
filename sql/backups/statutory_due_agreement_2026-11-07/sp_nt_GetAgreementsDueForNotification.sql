CREATE PROCEDURE dbo.sp_nt_GetAgreementsDueForNotification
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @due TABLE (agreement_sno INT, due_date DATE);

    INSERT INTO @due (agreement_sno, due_date)
    SELECT sa.agreement_sno, DATEADD(DAY, sa.notify_days_before, @today)
    FROM dbo.service_agreement sa
    JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    WHERE sa.status = 'A' AND sa.is_active = 'Y' AND sa.notify_days_before > 0
      AND DATEADD(DAY, sa.notify_days_before, @today) BETWEEN sa.period_start_date AND sa.period_end_date
      AND (
            (rc.interval_unit = 'DAY' AND DATEDIFF(DAY, sa.period_start_date, DATEADD(DAY, sa.notify_days_before, @today)) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NOT NULL
             AND DAY(DATEADD(DAY, sa.notify_days_before, @today)) = CASE WHEN sa.po_generation_day > DAY(EOMONTH(DATEADD(DAY, sa.notify_days_before, @today))) THEN DAY(EOMONTH(DATEADD(DAY, sa.notify_days_before, @today))) ELSE sa.po_generation_day END
             AND DATEDIFF(MONTH, sa.period_start_date, DATEADD(DAY, sa.notify_days_before, @today)) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NULL
             AND DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, DATEADD(DAY, sa.notify_days_before, @today)) / rc.interval_value) * rc.interval_value, sa.period_start_date) = DATEADD(DAY, sa.notify_days_before, @today))
          )
      AND NOT EXISTS (SELECT 1 FROM dbo.service_agreement_notification_log l WHERE l.agreement_sno = sa.agreement_sno AND l.billing_period_start = DATEADD(DAY, sa.notify_days_before, @today));

    DECLARE @claimed TABLE (agreement_sno INT, due_date DATE);
    DECLARE @a_sno INT, @d_date DATE;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT agreement_sno, due_date FROM @due;
    OPEN cur;
    FETCH NEXT FROM cur INTO @a_sno, @d_date;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.service_agreement_notification_log (agreement_sno, billing_period_start, status)
            VALUES (@a_sno, @d_date, 'PENDING');
            INSERT INTO @claimed (agreement_sno, due_date) VALUES (@a_sno, @d_date);
        END TRY
        BEGIN CATCH
            -- Unique-key collision: another sweep already claimed this row. Skip it.
        END CATCH
        FETCH NEXT FROM cur INTO @a_sno, @d_date;
    END
    CLOSE cur;
    DEALLOCATE cur;

    SELECT sa.agreement_sno, sa.agreement_no, sa.created_by AS notify_ecno, sm.service_name,
           sa.rate_amount, sa.po_generation_day, sa.notify_days_before, c.due_date
    FROM @claimed c
    JOIN dbo.service_agreement sa ON sa.agreement_sno = c.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno;
END;