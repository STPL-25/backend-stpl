-- ============================================================
-- 87_service_agreement_cycle_transaction_fix.sql
--
-- Found while verifying sql/86 live: approving AGR-2026-0003 (Unfixed,
-- single-stage) still failed — not with the final_rate_amount error sql/86
-- removed, but with a confusing "Cannot drop the table '#approval_stages'"
-- (error 3701) from sp_approve_service_agreement, and the agreement stayed
-- stuck at status='P'.
--
-- Root cause: sp_approve_service_agreement's final-stage block calls
-- sp_nt_IssueRecurringServicePOCycle (sql/83) inside its own already-open
-- BEGIN TRANSACTION, wrapped in a nested TRY/CATCH specifically so that a
-- failure issuing the first billing cycle does NOT fail the approval
-- itself (see the comment above that call — the recurring_pr_log FAILED
-- row is meant to be the only trace, retryable via a later sweep).
-- sp_nt_IssueRecurringServicePOCycle's OWN error handling breaks that
-- contract: its CATCH does a bare `IF @@TRANCOUNT > 0 ROLLBACK
-- TRANSACTION;` — in SQL Server, ROLLBACK TRANSACTION with no savepoint
-- name always unwinds to the OUTERMOST BEGIN TRAN, regardless of nesting
-- depth. Called from inside sp_approve_service_agreement's transaction,
-- this silently rolled back everything the approval had already done
-- (status change, history row, current_approver_id update) — and since
-- @silent=1 suppresses the THROW that would otherwise signal this, the
-- caller's nested TRY/CATCH never even saw an exception; it just returned
-- with @@TRANCOUNT already dropped to 0. sp_approve_service_agreement then
-- carried on assuming its transaction was still open, and its own
-- `DROP TABLE #approval_stages;` failed with 3701 because that temp table
-- (created inside the now-rolled-back transaction) no longer existed —
-- the 3701 is a secondary symptom, not the real bug.
--
-- Confirmed live: AGR-2026-0003's period_end_date (2026-01-31) is in the
-- past, so its first-cycle auto-issue correctly fails validation
-- (58213 "billing_period_start is past the agreement period_end_date") —
-- that specific failure is expected test-data behavior, not a bug. The bug
-- is that this (or any other) failure inside the auto-issue step was taking
-- the whole approval down with it instead of being swallowed as designed.
--
-- Fix: sp_nt_IssueRecurringServicePOCycle now detects whether it was
-- called inside an already-open transaction (@@TRANCOUNT > 0) and uses
-- SAVE TRANSACTION/ROLLBACK TRANSACTION <savepoint> for its own work in
-- that case, instead of BEGIN/ROLLBACK TRANSACTION — so a failure here
-- only undoes this proc's own PR/cycle rows, never the caller's
-- transaction. Standalone calls (the hourly sweep, sql/73's
-- sp_nt_ProcessDueRecurringServiceAgreements — no ambient transaction)
-- behave exactly as before. Everything else in the proc is unchanged.
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
