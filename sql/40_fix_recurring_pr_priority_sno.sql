-- ============================================================
-- Fix: sp_nt_IssueRecurringServicePOCycle hardcoded priority_sno = NULL in
-- its auto-generated PR insert, but pr_basic_info.priority_sno is NOT NULL.
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Why this is needed
-- ------------------
-- Discovered live while testing the new po_generation_day/notify_days_before
-- feature (39_service_agreement_scheduling_and_notifications.sql): approving
-- a Fixed Recurring agreement calls sp_nt_IssueRecurringServicePOCycle for
-- cycle 1, which failed with "Cannot insert the value NULL into column
-- 'priority_sno'". This is a pre-existing bug in
-- 23_service_recurring_flow_redesign.sql, not something this session
-- introduced — sp_nt_IssueRecurringServicePOCycle is untouched by file 39.
-- It had simply never been exercised successfully before: agreement_sno 4
-- (the only prior Approved Fixed Recurring row) failed earlier in the same
-- proc on its own vendor_sno-is-NULL check, so execution never reached this
-- INSERT until today.
--
-- Fix: resolve a default priority_sno (prefers a 'Medium' row, falls back to
-- any active priority) instead of hardcoding NULL. Everything else in the
-- proc is byte-for-byte unchanged from 23_service_recurring_flow_redesign.sql.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_IssueRecurringServicePOCycle', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_IssueRecurringServicePOCycle;
GO
CREATE PROCEDURE dbo.sp_nt_IssueRecurringServicePOCycle
    @jsonInput NVARCHAR(MAX),
    @silent BIT = 0,
    @out_result VARCHAR(30) = NULL OUTPUT,
    @out_po_basic_sno INT = NULL OUTPUT,
    @out_po_no VARCHAR(50) = NULL OUTPUT,
    @out_pr_basic_sno INT = NULL OUTPUT,
    @out_pr_no VARCHAR(20) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @agreement_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
    DECLARE @billing_period_start DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.billing_period_start') AS DATE);
    DECLARE @issued_by VARCHAR(20) = ISNULL(JSON_VALUE(@jsonInput, '$.issued_by'), 'SYSTEM');

    BEGIN TRY
        IF @agreement_sno IS NULL OR @billing_period_start IS NULL
            THROW 55001, 'agreement_sno and billing_period_start are required.', 1;

        IF EXISTS (SELECT 1 FROM dbo.service_agreement_recurring_pr_log WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start)
        BEGIN
            SET @out_result = 'SKIPPED_ALREADY_CLAIMED';
            IF @silent = 0
                SELECT @out_result AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start;
            RETURN;
        END

        DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @service_sno INT, @vendor_sno INT,
                @rate_amount DECIMAL(18,2), @rate_uom_sno INT, @service_type_code VARCHAR(30),
                @agr_status CHAR(1), @period_end DATE;

        SELECT @com_sno = sa.com_sno, @div_sno = sa.div_sno, @brn_sno = sa.brn_sno, @dept_sno = sa.dept_sno,
               @service_sno = sa.service_sno, @vendor_sno = sa.vendor_sno, @rate_amount = sa.rate_amount,
               @rate_uom_sno = sa.rate_uom_sno, @agr_status = sa.status, @period_end = sa.period_end_date,
               @service_type_code = st.service_type_code
        FROM dbo.service_agreement sa
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sa.agreement_sno = @agreement_sno;

        IF @agr_status IS NULL
            THROW 55002, 'Agreement not found.', 1;
        IF @agr_status <> 'A'
            THROW 55003, 'Agreement is not Approved.', 1;
        IF @service_type_code <> 'FIXED_RECURRING'
            THROW 55004, 'Recurring PO auto-issue only applies to Fixed Recurring agreements.', 1;
        IF @billing_period_start > @period_end
            THROW 55005, 'billing_period_start is past the agreement period_end_date.', 1;
        IF @vendor_sno IS NULL
            THROW 55006, 'Agreement has no vendor_sno — cannot auto-issue a PO.', 1;

        -- Guard against double-booking a period someone already billed by
        -- hand via the PR-line auto-fill screen (usp_InsertPurchaseRequest §4)
        IF EXISTS (
            SELECT 1 FROM dbo.pr_item_details pid
            JOIN dbo.pr_basic_info pb ON pb.pr_basic_sno = pid.pr_basic_sno
            WHERE pid.agreement_sno = @agreement_sno AND pid.is_active = 'Y' AND pb.is_active = 'Y'
              AND pb.created_date >= @billing_period_start
        )
        BEGIN
            INSERT INTO dbo.service_agreement_recurring_pr_log (agreement_sno, billing_period_start, status, error_message)
            VALUES (@agreement_sno, @billing_period_start, 'SKIPPED_MANUAL', 'A PR already exists for this billing period, created manually.');

            SET @out_result = 'SKIPPED_MANUAL_PR_EXISTS';
            IF @silent = 0
                SELECT @out_result AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start;
            RETURN;
        END

        -- Claim the slot before doing any real work (see file header —
        -- committed outside the transaction below so it survives a rollback).
        INSERT INTO dbo.service_agreement_recurring_pr_log (agreement_sno, billing_period_start, status)
        VALUES (@agreement_sno, @billing_period_start, 'PENDING');

        BEGIN TRANSACTION;

        DECLARE @current_year VARCHAR(10) = dbo.fn_GetFinancialYear(GETDATE());
        DECLARE @pr_prefix VARCHAR(20) = 'PR' + @current_year;
        DECLARE @pr_seq INT;
        SELECT @pr_seq = ISNULL(MAX(CASE WHEN pr_no LIKE @pr_prefix + '%' THEN TRY_CAST(SUBSTRING(pr_no, LEN(@pr_prefix) + 1, LEN(pr_no)) AS INT) ELSE 0 END), 0) + 1
        FROM dbo.pr_basic_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE @pr_prefix + '%';
        DECLARE @pr_no VARCHAR(20) = @pr_prefix + RIGHT('0000' + CAST(@pr_seq AS VARCHAR(4)), 4);

        -- pr_basic_info.priority_sno is NOT NULL — resolve a sensible
        -- default for a system-generated PR (prefers 'Medium', falls back
        -- to any active priority so this doesn't break if that row is ever
        -- renamed/removed).
        DECLARE @default_priority_sno INT;
        SELECT TOP 1 @default_priority_sno = priority_sno
        FROM dbo.priority_master
        WHERE is_active = 'Y'
        ORDER BY CASE WHEN priority_name = 'Medium' THEN 0 ELSE 1 END, priority_sno;

        IF @default_priority_sno IS NULL
            THROW 55007, 'No active priority_master row found to assign to the auto-generated PR.', 1;

        -- Auto-approved PR: status='A', no workflow — the human decision
        -- already happened at agreement-approval time (see file header).
        INSERT INTO dbo.pr_basic_info (
            pr_no, com_sno, div_sno, brn_sno, dept_sno, reg_date, required_date, priority_sno, purpose,
            is_active, created_by, created_date, workflow_types_id, current_approver_id, status
        )
        VALUES (
            @pr_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @billing_period_start, @billing_period_start, @default_priority_sno,
            N'Auto-generated recurring PR — Service Agreement ' + CAST(@agreement_sno AS VARCHAR(10)),
            'Y', @issued_by, GETDATE(), NULL, NULL, 'A'
        );
        DECLARE @pr_basic_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.pr_item_details (
            pr_no, pr_basic_sno, prod_sno, qty, unit, est_cost, total_cost, remarks, specification,
            pr_prod_file, item_type, service_sno, agreement_sno, is_active, created_by, created_date
        )
        VALUES (
            @pr_no, @pr_basic_sno, NULL, 1, @rate_uom_sno, @rate_amount, @rate_amount, '', '',
            NULL, 'service', @service_sno, @agreement_sno, 'Y', @issued_by, GETDATE()
        );
        DECLARE @pr_item_sno INT = SCOPE_IDENTITY();

        DECLARE @poJson NVARCHAR(MAX) = (
            SELECT @com_sno AS com_sno, @div_sno AS div_sno, @brn_sno AS brn_sno, @dept_sno AS dept_sno,
                   @vendor_sno AS vendor_sno, @pr_basic_sno AS pr_basic_sno, 0 AS is_retrospective,
                   @pr_item_sno AS pr_item_sno, @service_sno AS service_sno, 1 AS qty, @rate_uom_sno AS uom_sno,
                   @rate_amount AS unit_price, 'RECURRING' AS po_type,
                   @billing_period_start AS validity_from, @period_end AS validity_to,
                   @issued_by AS issued_by,
                   (N'Auto-issued recurring Service PO — Service Agreement ' + CAST(@agreement_sno AS VARCHAR(10))
                    + N', period starting ' + CONVERT(VARCHAR(10), @billing_period_start, 120)) AS source_note,
                   (N'Recurring service PO — Service Agreement ' + CAST(@agreement_sno AS VARCHAR(10))) AS purpose
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        DECLARE @po_result VARCHAR(30), @po_basic_sno INT, @po_no VARCHAR(50);
        EXEC dbo.sp_nt_DirectIssueServicePO
            @jsonInput = @poJson, @silent = 1,
            @out_result = @po_result OUTPUT, @out_po_basic_sno = @po_basic_sno OUTPUT, @out_po_no = @po_no OUTPUT;

        UPDATE dbo.service_agreement_recurring_pr_log
        SET status = 'CREATED', pr_basic_sno = @pr_basic_sno, pr_no = @pr_no,
            po_basic_sno = @po_basic_sno, po_no = @po_no, modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start;

        COMMIT TRANSACTION;

        SET @out_result = 'SUCCESS';
        SET @out_po_basic_sno = @po_basic_sno;
        SET @out_po_no = @po_no;
        SET @out_pr_basic_sno = @pr_basic_sno;
        SET @out_pr_no = @pr_no;

        IF @silent = 0
            SELECT 'SUCCESS' AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start,
                   @pr_basic_sno AS pr_basic_sno, @pr_no AS pr_no, @po_basic_sno AS po_basic_sno, @po_no AS po_no;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        UPDATE dbo.service_agreement_recurring_pr_log
        SET status = 'FAILED', error_message = ERROR_MESSAGE(), modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start AND status = 'PENDING';

        SET @out_result = 'ERROR';
        IF @silent = 0
            THROW;
    END CATCH
END;
GO

-- ============================================================
-- After running, confirm:
--   EXEC dbo.sp_nt_IssueRecurringServicePOCycle
--     @jsonInput = N'{"agreement_sno":5,"billing_period_start":"2026-09-01","issued_by":"SYSTEM"}';
--   -- should now return SUCCESS with a real pr_basic_sno/po_basic_sno, not the
--   -- priority_sno NULL error — but only after the stuck FAILED log row for
--   -- (5, 2026-09-01) is cleared first (the proc's own claim-guard treats an
--   -- existing row, even FAILED, as SKIPPED_ALREADY_CLAIMED).
-- ============================================================
