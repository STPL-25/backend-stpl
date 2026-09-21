-- ============================================================
-- Service Agreement: supplier/incharge dispatch + Unfixed GRN
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Context
-- -------
-- Builds on backend-stpl/sql/73_service_agreement_rebuild.sql (still not run
-- live as of this file). Adds, per a follow-up conversation:
--   1) A per-service "Incharge" (responsible employee, opaque ecno string —
--      same convention as approver_ecno elsewhere, no FK to an employee
--      table since that table isn't known/checked-in anywhere in this repo).
--   2) A per-agreement dispatch_type ('S'=Supplier, 'I'=Incharge), chosen by
--      the approver at an Unfixed agreement's final approval stage and
--      reused for every future recurring PO on that agreement. Fixed
--      agreements always stay 'S' (default, no UI to change it).
--   3) A dispatch-info lookup for Node to act on (this DB can't send email
--      itself) — reuses the existing sendPOGeneratedEmail/notification-service
--      pipeline and the existing sp_nt_LogPOSentToSupplier po_history_data
--      log for the Supplier path; only the Incharge path needs one small new
--      proc, since nothing logs that transition today.
--   4) A minimal Service GRN (PO reference + invoice number + invoice file +
--      received date + remarks) for Unfixed agreements only — no stock/FIFO
--      tracking, deliberately out of scope per this pass's own instructions.
--
-- Idempotent throughout (IF NOT EXISTS / IF OBJECT_ID...DROP), matching this
-- repo's migration-file convention. Safe to re-run.
--
-- NOT YET RUN AGAINST THE LIVE DB — same as 73, apply by hand against
-- 10.0.21.8 (this repo has no migration runner). Run 73 first if it hasn't
-- been run yet; this file depends on tables it creates.
-- ============================================================

-- ============================================================
-- 1) service_master.incharge_ecno — responsible employee when a service is
--    fulfilled internally instead of by a vendor. Set at service creation
--    only (no update proc for service_master exists or is being added).
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_master') AND name = 'incharge_ecno')
    ALTER TABLE dbo.service_master ADD incharge_ecno VARCHAR(20) NULL;
GO

IF OBJECT_ID('dbo.sp_nt_CreateServiceRecords', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateServiceRecords;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 58004, N'Invalid JSON payload provided.', 1;

    DECLARE @service_name     NVARCHAR(150) = JSON_VALUE(@jsonInput, '$.service_name'),
            @service_code     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.service_code'),
            @service_type_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_type_sno') AS INT),
            @default_uom_sno  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.default_uom_sno') AS INT),
            @description      NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.description'),
            @incharge_ecno    VARCHAR(20)   = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.incharge_ecno'))), ''),
            @created_by       VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @service_name IS NULL OR @service_code IS NULL OR @service_type_sno IS NULL
        THROW 58005, N'service_name, service_code and service_type_sno are required.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.service_type_master WHERE service_type_sno = @service_type_sno AND is_active = 'Y')
        THROW 58006, N'service_type_sno does not reference an active service type.', 1;

    IF EXISTS (SELECT 1 FROM dbo.service_master WHERE service_code = @service_code)
        THROW 58007, N'A service with this code already exists.', 1;

    INSERT INTO dbo.service_master (service_name, service_code, service_type_sno, default_uom_sno, description, incharge_ecno, is_active, created_by)
    VALUES (@service_name, @service_code, @service_type_sno, @default_uom_sno, @description, @incharge_ecno, 'Y', @created_by);

    SELECT SCOPE_IDENTITY() AS service_sno, @service_code AS service_code, N'SUCCESS' AS status;
END;
GO

IF OBJECT_ID('dbo.sp_nt_GetServiceRecords', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceRecords;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceRecords
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @service_type_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @service_type_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_type_sno') AS INT);

    SELECT sm.service_sno, sm.service_name, sm.service_code, sm.service_type_sno,
           st.service_type_code, st.service_type_name,
           sm.default_uom_sno, um.uom_name AS default_uom_name,
           sm.description, sm.incharge_ecno, sm.is_active
    FROM dbo.service_master sm
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = sm.default_uom_sno
    WHERE sm.is_active = 'Y'
      AND (@service_type_sno IS NULL OR sm.service_type_sno = @service_type_sno)
    ORDER BY sm.service_name;
END;
GO

-- ============================================================
-- 2) service_agreement.dispatch_type — 'S' (Supplier) or 'I' (Incharge).
--    Chosen by the approver at an Unfixed agreement's final approval stage
--    (see sp_approve_service_agreement below); Fixed agreements never change
--    it away from the default.
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_agreement') AND name = 'dispatch_type')
    ALTER TABLE dbo.service_agreement ADD dispatch_type CHAR(1) NOT NULL CONSTRAINT DF_service_agreement_dispatch_type DEFAULT 'S';
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_service_agreement_dispatch_type')
    ALTER TABLE dbo.service_agreement ADD CONSTRAINT CK_service_agreement_dispatch_type CHECK (dispatch_type IN ('S', 'I'));
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
           sa.qty, sa.rate_amount, sa.rate_uom_sno, um.uom_name AS rate_uom_name,
           sa.recurrence_cadence_sno, rc.cadence_name, rc.interval_unit, rc.interval_value,
           sa.po_generation_day, sa.notify_days_before,
           sa.period_start_date, sa.period_end_date, sa.agreement_doc_url, sa.remarks,
           sa.current_approver_id, sa.status, sa.dispatch_type, sm.incharge_ecno,
           sa.created_by, sa.created_at
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = sa.rate_uom_sno
    LEFT JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
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
           sa.qty, sa.rate_amount, sa.rate_uom_sno, um.uom_name AS rate_uom_name,
           sa.recurrence_cadence_sno, rc.cadence_name,
           sa.po_generation_day, sa.notify_days_before,
           sa.period_start_date, sa.period_end_date, sa.agreement_doc_url, sa.remarks,
           sa.current_approver_id, sa.status, sa.dispatch_type, sm.incharge_ecno,
           sa.created_by, sa.created_at,
           ws.stages_json AS stage_order_json
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = sa.rate_uom_sno
    LEFT JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    LEFT JOIN dbo.vw_workflow_stages ws ON ws.workflow_types_id = sa.workflow_types_id
    WHERE sa.is_active = 'Y' AND sa.status = 'P' AND sa.current_approver_id = @Ecno
    ORDER BY sa.agreement_sno DESC;
END;
GO

-- ============================================================
-- 3) sp_approve_service_agreement — same as 73's version, PLUS:
--    at the true final stage of an Unfixed (VARIABLE_RECURRING) agreement,
--    @dispatch_type ('S'|'I') is now required and persisted. Choosing 'I'
--    requires the service to have an incharge_ecno configured. Fixed
--    agreements ignore @dispatch_type entirely (column stays default 'S').
-- @jsonInput: { agreement_sno, approved_by, comments, approval_stages,
--   action, final_rate_amount?, final_qty?, dispatch_type? }
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
                @action           VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action'),
                @final_rate_amount DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.final_rate_amount') AS DECIMAL(18,2)),
                @final_qty        DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.final_qty') AS DECIMAL(18,4)),
                @dispatch_type    CHAR(1)       = NULLIF(JSON_VALUE(@jsonInput, '$.dispatch_type'), '');

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
            INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment)
            VALUES (@agreement_sno, 'REJECTED', @approved_by, @comments);

            UPDATE dbo.service_agreement SET status = 'R', current_approver_id = NULL WHERE agreement_sno = @agreement_sno;

            DROP TABLE #approval_stages;
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

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment)
        VALUES (@agreement_sno, 'APPROVED', @approved_by, @comments);

        UPDATE dbo.service_agreement SET current_approver_id = @next_current_approver WHERE agreement_sno = @agreement_sno;

        DECLARE @auto_po_result VARCHAR(200) = NULL, @auto_po_basic_sno INT = NULL, @auto_po_no VARCHAR(50) = NULL,
                @auto_pr_basic_sno INT = NULL, @auto_pr_no VARCHAR(20) = NULL;

        IF @next_current_approver IS NULL
        BEGIN
            -- ── Final stage: for Unfixed, require + apply the one-time real value,
            --    plus the Supplier/Incharge dispatch choice ──
            DECLARE @service_type_code VARCHAR(30), @period_start DATE, @old_rate DECIMAL(18,2), @old_qty DECIMAL(18,4), @service_sno_local INT;
            SELECT @service_type_code = st.service_type_code, @period_start = sa.period_start_date,
                   @old_rate = sa.rate_amount, @old_qty = sa.qty, @service_sno_local = sa.service_sno
            FROM dbo.service_agreement sa
            JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
            JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
            WHERE sa.agreement_sno = @agreement_sno;

            IF @service_type_code = 'VARIABLE_RECURRING'
            BEGIN
                IF @final_rate_amount IS NULL OR @final_rate_amount <= 0 OR @final_qty IS NULL OR @final_qty <= 0
                BEGIN
                    RAISERROR('This is an Unfixed agreement — final_rate_amount and final_qty are required to complete the final approval.', 16, 1);
                    RETURN;
                END

                IF @dispatch_type IS NULL OR @dispatch_type NOT IN ('S', 'I')
                BEGIN
                    RAISERROR('This is an Unfixed agreement — dispatch_type (S=Supplier or I=Incharge) is required to complete the final approval.', 16, 1);
                    RETURN;
                END

                IF @dispatch_type = 'I'
                BEGIN
                    DECLARE @svc_incharge VARCHAR(20);
                    SELECT @svc_incharge = incharge_ecno FROM dbo.service_master WHERE service_sno = @service_sno_local;
                    IF @svc_incharge IS NULL OR LTRIM(RTRIM(@svc_incharge)) = ''
                    BEGIN
                        RAISERROR('This service has no Incharge configured in Service Master — set one before routing to Incharge, or choose Supplier instead.', 16, 1);
                        RETURN;
                    END
                END

                UPDATE dbo.service_agreement SET rate_amount = @final_rate_amount, qty = @final_qty, dispatch_type = @dispatch_type WHERE agreement_sno = @agreement_sno;

                INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment)
                VALUES (@agreement_sno, 'RATE_FINALIZED', @approved_by,
                        N'Rate ' + CAST(@old_rate AS VARCHAR(30)) + N' -> ' + CAST(@final_rate_amount AS VARCHAR(30))
                        + N', Qty ' + CAST(@old_qty AS VARCHAR(30)) + N' -> ' + CAST(@final_qty AS VARCHAR(30))
                        + N', Dispatch -> ' + CASE WHEN @dispatch_type = 'I' THEN N'Incharge' ELSE N'Supplier' END);
            END

            UPDATE dbo.service_agreement SET status = 'A' WHERE agreement_sno = @agreement_sno;

            IF NOT EXISTS (SELECT 1 FROM dbo.service_agreement_recurring_pr_log WHERE agreement_sno = @agreement_sno)
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

        SELECT
            'SUCCESS' AS result, @agreement_sno AS agreement_sno, @approved_by AS approved_by, GETDATE() AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE') AS next_approver,
            @auto_po_result AS auto_po_result, @auto_po_basic_sno AS auto_po_basic_sno, @auto_po_no AS auto_po_no,
            @auto_pr_basic_sno AS auto_pr_basic_sno, @auto_pr_no AS auto_pr_no;
    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL DROP TABLE #approval_stages;
        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO

-- ============================================================
-- 4) sp_nt_ProcessDueRecurringServiceAgreements — same as 73's version, PLUS
--    a second result set listing every PO actually issued in this sweep run,
--    so the Node job can dispatch (email/in-app) each one individually —
--    the aggregate-only summary that already existed doesn't have enough
--    detail for that.
-- ============================================================
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
    DECLARE @issued TABLE (po_basic_sno INT, po_no VARCHAR(50));

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

        IF @row_result = 'SUCCESS'
        BEGIN
            SET @success_count = @success_count + 1;
            INSERT INTO @issued (po_basic_sno, po_no) VALUES (@row_po, @row_po_no);
        END
        ELSE IF @row_result LIKE 'SKIPPED%' SET @skipped_count = @skipped_count + 1;
        ELSE SET @failed_count = @failed_count + 1;

        FETCH NEXT FROM cur INTO @agreement_sno, @billing_period_start;
    END
    CLOSE cur;
    DEALLOCATE cur;

    SELECT (SELECT COUNT(*) FROM @due) AS due_count, @success_count AS success_count, @skipped_count AS skipped_count, @failed_count AS failed_count;

    SELECT po_basic_sno, po_no FROM @issued;
END;
GO

-- ============================================================
-- 5) sp_nt_GetServicePoDispatchInfo — everything Node needs to email/notify
--    the right recipient for one issued service PO. Works for both the
--    inline (final-approval) and recurring-sweep issuance paths, since both
--    always go through service_agreement_recurring_pr_log.
--
--    Deliberately reuses existing infrastructure instead of adding new mail/
--    log plumbing: `sendPOGeneratedEmail` (backend-stpl/src/Utils/Notify/
--    notifyClient.js) already calls the real notification-service for the
--    regular PO flow (PurchaseTeamService.sendPOEmail), and
--    `sp_nt_LogPOSentToSupplier` (sql/29_pr_tracking.sql) already logs a
--    'SENT_TO_SUPPLIER' row into the shared po_history_data table — both are
--    reused as-is for the Supplier path below. Only the Incharge path needs
--    one small new proc (§6), since nothing logs that transition today.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServicePoDispatchInfo', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServicePoDispatchInfo;
GO
CREATE PROCEDURE dbo.sp_nt_GetServicePoDispatchInfo
    @po_basic_sno INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT po.po_basic_sno, po.po_df_no AS po_no, po.po_date, po.required_date,
           sa.agreement_sno, sa.agreement_no, sm.service_name,
           sa.dispatch_type, sa.vendor_sno, k.company_name AS vendor_name, k.email AS vendor_email,
           sm.incharge_ecno, sa.rate_amount, sa.qty, sa.created_by
    FROM dbo.po_request_info po
    JOIN dbo.service_agreement_recurring_pr_log l ON l.po_basic_sno = po.po_basic_sno
    JOIN dbo.service_agreement sa ON sa.agreement_sno = l.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    WHERE po.po_basic_sno = @po_basic_sno;
END;
GO

-- ============================================================
-- 6) sp_nt_LogServicePoDispatchedToIncharge — the Incharge-path equivalent
--    of sp_nt_LogPOSentToSupplier (same table, same shape, different
--    action_type), since that existing proc hardcodes 'SENT_TO_SUPPLIER'.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_LogServicePoDispatchedToIncharge', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_LogServicePoDispatchedToIncharge;
GO
CREATE PROCEDURE dbo.sp_nt_LogServicePoDispatchedToIncharge
    @po_basic_sno INT,
    @status_by    VARCHAR(20),
    @comment      VARCHAR(250) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
    VALUES (@po_basic_sno, 'SENT_TO_INCHARGE', @status_by, @comment, 'Y');

    SELECT 'LOGGED' AS result, @po_basic_sno AS po_basic_sno, SCOPE_IDENTITY() AS po_history_sno;
END;
GO

-- ============================================================
-- 7) service_grn — minimal receipt record for Unfixed-agreement POs only.
--    No stock/qty/FIFO tracking — just proof the service was delivered and
--    billed (PO ref + invoice number + invoice file + received date).
-- ============================================================
IF OBJECT_ID('dbo.service_grn', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_grn (
        grn_sno         INT IDENTITY(1,1) PRIMARY KEY,
        grn_no          VARCHAR(30) NOT NULL,
        po_basic_sno    INT NOT NULL,
        agreement_sno   INT NOT NULL,
        invoice_no      VARCHAR(50) NOT NULL,
        invoice_doc_url NVARCHAR(500) NOT NULL,
        received_date   DATE NOT NULL,
        remarks         NVARCHAR(500) NULL,
        entered_by      VARCHAR(20) NOT NULL,
        created_at      DATETIME NOT NULL DEFAULT GETDATE(),
        CONSTRAINT UQ_service_grn_no UNIQUE (grn_no),
        CONSTRAINT UQ_service_grn_po UNIQUE (po_basic_sno),
        CONSTRAINT FK_service_grn_agreement FOREIGN KEY (agreement_sno) REFERENCES dbo.service_agreement (agreement_sno)
    );
END;
GO

IF OBJECT_ID('dbo.sp_nt_CreateServiceGrn', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateServiceGrn;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceGrn
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @po_basic_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT);
        DECLARE @invoice_no      VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.invoice_no');
        DECLARE @invoice_doc_url NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.invoice_doc_url');
        DECLARE @received_date   DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.received_date') AS DATE);
        DECLARE @remarks         NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @entered_by      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.entered_by');

        IF @po_basic_sno IS NULL OR @entered_by IS NULL
            THROW 58301, 'po_basic_sno and entered_by are required.', 1;
        IF @invoice_no IS NULL OR LTRIM(RTRIM(@invoice_no)) = ''
            THROW 58302, 'invoice_no is required.', 1;
        IF @invoice_doc_url IS NULL OR LTRIM(RTRIM(@invoice_doc_url)) = ''
            THROW 58303, 'invoice_doc_url is required — upload the invoice before submitting.', 1;
        IF @received_date IS NULL
            THROW 58304, 'received_date is required.', 1;

        DECLARE @agreement_sno INT, @service_type_code VARCHAR(30);
        SELECT TOP 1 @agreement_sno = l.agreement_sno
        FROM dbo.service_agreement_recurring_pr_log l
        WHERE l.po_basic_sno = @po_basic_sno AND l.status = 'CREATED';

        IF @agreement_sno IS NULL
            THROW 58305, 'This PO is not linked to an issued Service Agreement PO.', 1;

        SELECT @service_type_code = st.service_type_code
        FROM dbo.service_agreement sa
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sa.agreement_sno = @agreement_sno;

        IF @service_type_code <> 'VARIABLE_RECURRING'
            THROW 58306, 'A Service GRN only applies to Unfixed (Variable) service agreements.', 1;

        IF EXISTS (SELECT 1 FROM dbo.service_grn WHERE po_basic_sno = @po_basic_sno)
            THROW 58307, 'A GRN already exists for this PO.', 1;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(grn_no, 4) AS INT)), 0) + 1
        FROM dbo.service_grn WITH (UPDLOCK, HOLDLOCK)
        WHERE grn_no LIKE 'SGRN-' + @year + '-%';
        DECLARE @grn_no VARCHAR(30) = 'SGRN-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.service_grn (grn_no, po_basic_sno, agreement_sno, invoice_no, invoice_doc_url, received_date, remarks, entered_by)
        VALUES (@grn_no, @po_basic_sno, @agreement_sno, @invoice_no, @invoice_doc_url, @received_date, @remarks, @entered_by);

        COMMIT TRANSACTION;

        SELECT SCOPE_IDENTITY() AS grn_sno, @grn_no AS grn_no, 'SUCCESS' AS result;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

IF OBJECT_ID('dbo.sp_nt_GetPendingServiceGrnPOs', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetPendingServiceGrnPOs;
GO
CREATE PROCEDURE dbo.sp_nt_GetPendingServiceGrnPOs
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

    SELECT po.po_basic_sno, po.po_df_no AS po_no, po.po_date, po.com_sno, po.div_sno, po.brn_sno, po.dept_sno,
           sa.agreement_sno, sa.agreement_no, sa.dispatch_type, sm.incharge_ecno,
           sa.vendor_sno, k.company_name AS vendor_name, sm.service_name,
           pid.qty, pid.unit_name, pid.agreed_unit_price, pid.net_cost
    FROM dbo.service_agreement_recurring_pr_log l
    JOIN dbo.po_request_info po ON po.po_basic_sno = l.po_basic_sno
    JOIN dbo.service_agreement sa ON sa.agreement_sno = l.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.po_item_details pid ON pid.po_basic_sno = po.po_basic_sno
    WHERE l.status = 'CREATED' AND st.service_type_code = 'VARIABLE_RECURRING'
      AND NOT EXISTS (SELECT 1 FROM dbo.service_grn g WHERE g.po_basic_sno = l.po_basic_sno)
      AND (@com_sno IS NULL OR po.com_sno = @com_sno)
      AND (@div_sno IS NULL OR po.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR po.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR po.dept_sno = @dept_sno)
    ORDER BY po.po_basic_sno DESC;
END;
GO

IF OBJECT_ID('dbo.sp_nt_GetServiceGrns', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceGrns;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceGrns
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

    SELECT g.grn_sno, g.grn_no, g.po_basic_sno, po.po_df_no AS po_no, po.com_sno, po.div_sno, po.brn_sno, po.dept_sno,
           g.agreement_sno, sa.agreement_no, sm.service_name, sa.vendor_sno, k.company_name AS vendor_name,
           g.invoice_no, g.invoice_doc_url, g.received_date, g.remarks, g.entered_by, g.created_at
    FROM dbo.service_grn g
    JOIN dbo.po_request_info po ON po.po_basic_sno = g.po_basic_sno
    JOIN dbo.service_agreement sa ON sa.agreement_sno = g.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    WHERE (@com_sno IS NULL OR po.com_sno = @com_sno)
      AND (@div_sno IS NULL OR po.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR po.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR po.dept_sno = @dept_sno)
    ORDER BY g.grn_sno DESC;
END;
GO

-- ============================================================
-- 8) Sidebar registration for the new Service GRN screen — same idempotent
--    pattern as 73 §18.
-- ============================================================
DECLARE @group_id       INT           = 2;
DECLARE @screen_code    VARCHAR(10)   = N'S18';
DECLARE @comp_img_value NVARCHAR(100) = N'PackageCheck';

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceGrnPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service GRN', @screen_code, 'ServiceGrnPage', @comp_img_value, @group_id, 25, 'Y');
GO

-- ============================================================
-- After running, confirm:
--   SELECT incharge_ecno FROM dbo.service_master;
--   SELECT dispatch_type FROM dbo.service_agreement;
--   SELECT * FROM dbo.screens WHERE comp = 'ServiceGrnPage';
--   SELECT name FROM sys.procedures WHERE name IN (
--     'sp_nt_GetServicePoDispatchInfo', 'sp_nt_LogServicePoDispatchedToIncharge',
--     'sp_nt_CreateServiceGrn', 'sp_nt_GetPendingServiceGrnPOs', 'sp_nt_GetServiceGrns'
--   );
--
-- Then, required manual steps (not automatable from this file):
--   - Set incharge_ecno on any Service Master record that should route to an
--     internal Incharge instead of the supplier.
--   - Grant the new ServiceGrnPage screen to the relevant users via
--     sp_nt_GrantScreenToUser (see 73_service_agreement_rebuild.sql §18).
--   - No new email config needed — dispatch reuses the existing
--     notification-service call (NOTIFICATION_SERVICE_URL /
--     INTERNAL_BROADCAST_SECRET, already in backend-stpl/.env) via
--     sendPOGeneratedEmail, same as the regular PO-email flow.
-- ============================================================
