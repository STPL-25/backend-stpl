-- ============================================================
-- Service Agreement: edit an existing (Approved/Rejected) agreement,
-- re-entering the approval workflow before the edit takes effect.
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/ServiceAgreement (updateServiceAgreement),
--            nt-frontend-stpl Application/ServiceAgreement/ServiceAgreementListPage.tsx
--
-- Why this is needed
-- ------------------
-- No precedent exists anywhere in this codebase for "edit an approved record
-- -> it re-enters approval" (confirmed via full-repo search this session —
-- KYC/PR/PO have no edit-after-approval path at all; the one thing that
-- looked like a candidate, sp_nt_ReviseServicePOCeiling, is explicitly an
-- immediate in-place admin revision with NO re-approval). This is modeled
-- directly on sp_nt_CreateServiceAgreement's own validation (v6, in
-- 47_service_agreement_variable_notify.sql) — same field checks, same
-- workflow-resolution query — but UPDATEs the existing row (same
-- agreement_no, same agreement_sno) instead of inserting a new one, and
-- only allowed when the row isn't already mid-approval.
--
-- Collision this also fixes: sp_approve_service_agreement's final-approval
-- side effect (auto-issuing the FIXED_RECURRING agreement's first PR+PO
-- cycle) must not fire again when this is a re-approval of an EDIT — cycles
-- are already running via the hourly sweep for an agreement that was
-- already Approved before. Guarded by checking
-- service_agreement_recurring_pr_log: a first-ever approval has no rows
-- there yet; a re-approval of an edit always does (the first approval
-- always writes one, success or failure).
-- ============================================================

IF OBJECT_ID('dbo.sp_nt_UpdateServiceAgreement', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_UpdateServiceAgreement;
GO
CREATE PROCEDURE dbo.sp_nt_UpdateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @agreement_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
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
        DECLARE @edited_by            VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.edited_by');

        IF @agreement_sno IS NULL
            THROW 53030, 'agreement_sno is required.', 1;

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @service_sno IS NULL OR @edited_by IS NULL
            THROW 53001, 'com_sno, div_sno, brn_sno, dept_sno, service_sno and edited_by are required.', 1;

        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 53003, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;

        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 53004, 'agreement_doc_url is required — upload the agreement document before submitting.', 1;

        DECLARE @current_status VARCHAR(1);
        SELECT @current_status = status
        FROM dbo.service_agreement WITH (UPDLOCK, HOLDLOCK)
        WHERE agreement_sno = @agreement_sno AND is_active = 'Y';

        IF @current_status IS NULL
            THROW 53031, 'Service agreement not found or inactive.', 1;

        IF @current_status NOT IN ('A', 'R')
            THROW 53032, 'Only an Approved or Rejected agreement can be edited (it is currently Pending approval).', 1;

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

        IF @service_type_code = 'FIXED_RECURRING'
        BEGIN
            IF @rate_amount IS NULL OR @rate_amount <= 0
                THROW 53002, 'rate_amount must be a positive amount.', 1;

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

            SET @po_generation_day = NULL;

            IF @notify_days_before IS NOT NULL AND @notify_days_before < 0
                THROW 53023, 'notify_days_before must not be negative.', 1;
        END

        -- ── Re-resolve the ServiceAgreement workflow for this org scope ────
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

        UPDATE dbo.service_agreement
        SET com_sno = @com_sno, div_sno = @div_sno, brn_sno = @brn_sno, dept_sno = @dept_sno,
            service_sno = @service_sno, vendor_sno = @vendor_sno,
            rate_amount = @rate_amount, rate_uom_sno = @rate_uom_sno,
            ceiling_amount = @ceiling_amount, variance_tolerance_pct = @variance_tolerance_pct,
            recurrence_cadence = @recurrence_cadence, recurrence_cadence_sno = @recurrence_cadence_sno,
            po_generation_day = @po_generation_day, notify_days_before = @notify_days_before,
            period_start_date = @period_start_date, period_end_date = @period_end_date,
            agreement_doc_url = @agreement_doc_url, remarks = @remarks,
            workflow_types_id = @workflow_types_id, current_approver_id = @first_approver,
            status = 'P',
            modified_by = @edited_by, modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, is_active)
        VALUES (@agreement_sno, 'RESUBMITTED', @edited_by, @remarks, 'Y');

        COMMIT TRANSACTION;

        SELECT
            @agreement_sno AS agreement_sno,
            'SUCCESS'      AS result,
            N'Service agreement updated and resubmitted for approval.' AS message;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- sp_approve_service_agreement v3 — adds one guard: skip the FIXED_RECURRING
-- auto-issue-first-cycle side effect when this agreement already has a
-- recurring-log row (meaning it was approved and cycling before; this
-- approval is a re-approval of an edit, not the agreement's first-ever
-- approval). Everything else is byte-for-byte identical to v2
-- (23_service_recurring_flow_redesign.sql).
-- ============================================================
IF OBJECT_ID('dbo.sp_approve_service_agreement', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_approve_service_agreement;
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

        DECLARE @agreement_sno   INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT),
                @comments        VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by     VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action          VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');

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
            INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, is_active)
            VALUES (@agreement_sno, 'REJECTED', @approved_by, @comments, 'Y');

            UPDATE dbo.service_agreement
            SET status = 'R', current_approver_id = NULL
            WHERE agreement_sno = @agreement_sno;

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
        LEFT JOIN #approval_stages next_stage
            ON next_stage.approver_ecno = current_stage.next_approver_ecno
        WHERE current_stage.approver_ecno = @approved_by;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, is_active)
        VALUES (@agreement_sno, 'APPROVED', @approved_by, @comments, 'Y');

        UPDATE dbo.service_agreement
        SET current_approver_id = @next_current_approver
        WHERE agreement_sno = @agreement_sno;

        DECLARE @auto_po_result VARCHAR(30) = NULL, @auto_po_basic_sno INT = NULL, @auto_po_no VARCHAR(50) = NULL,
                @auto_pr_basic_sno INT = NULL, @auto_pr_no VARCHAR(20) = NULL;

        IF @next_current_approver IS NULL
        BEGIN
            UPDATE dbo.service_agreement SET status = 'A' WHERE agreement_sno = @agreement_sno;

            -- Final approval: for a FIXED_RECURRING agreement, immediately
            -- issue the first billing cycle rather than waiting on the sweep
            -- — but ONLY if this agreement has never had a cycle issued
            -- before (a true first approval). A re-approval of an EDIT to an
            -- already-cycling agreement must not re-trigger this — cycles
            -- for it are already running via the hourly sweep, and issuing
            -- again here would double-bill the current period.
            IF NOT EXISTS (
                SELECT 1 FROM dbo.service_agreement_recurring_pr_log
                WHERE agreement_sno = @agreement_sno
            )
            BEGIN
                DECLARE @service_type_code VARCHAR(30), @period_start DATE;
                SELECT @service_type_code = st.service_type_code, @period_start = sa.period_start_date
                FROM dbo.service_agreement sa
                JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
                JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
                WHERE sa.agreement_sno = @agreement_sno;

                IF @service_type_code = 'FIXED_RECURRING'
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
                        -- Do not fail the approval itself — see file header.
                        SET @auto_po_result = 'ERROR: ' + ERROR_MESSAGE();
                    END CATCH
                END
            END
        END

        DROP TABLE #approval_stages;

        SELECT
            'SUCCESS'                                      AS result,
            @agreement_sno                                 AS agreement_sno,
            @approved_by                                    AS approved_by,
            GETDATE()                                        AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE')     AS next_approver,
            @auto_po_result                                    AS auto_po_result,
            @auto_po_basic_sno                                  AS auto_po_basic_sno,
            @auto_po_no                                          AS auto_po_no,
            @auto_pr_basic_sno                                    AS auto_pr_basic_sno,
            @auto_pr_no                                            AS auto_pr_no;

    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL
            DROP TABLE #approval_stages;

        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT name FROM sys.procedures WHERE name IN ('sp_nt_UpdateServiceAgreement','sp_approve_service_agreement');
--   SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.sp_approve_service_agreement'));
-- ============================================================
