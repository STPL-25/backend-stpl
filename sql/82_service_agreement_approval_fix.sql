-- ============================================================
-- 82_service_agreement_approval_fix.sql
--
-- Fixes two bugs found while browser-verifying the Unfixed recurring
-- Service Agreement flow end-to-end for the first time (sql/73 + sql/81
-- had never been exercised through the UI before this session):
--
-- 1) sp_nt_GetServiceAgreementsForApproval returned stage_order_json via
--    dbo.vw_workflow_stages (ws.stages_json AS stage_order_json). That view
--    wraps the column in an extra FOR JSON PATH array — i.e. the frontend
--    received `[{"stage_order_json":"[{...}]"}]` instead of the flat
--    `[{...}]` every other approval screen (PR/PO — see
--    sql/63_vw_pr_basic_info_vendor_driven.sql's scalar-subquery pattern)
--    already returns and that ServiceAgreementApprovalScreen.tsx's
--    parseStages()/requiresFinalValues already assume.
--    Consequences of the double wrap, both silent (no error thrown):
--      a) requiresFinalValues (ServiceAgreementApprovalScreen.tsx:88-94)
--         always evaluated false — stages[stages.length-1]?.approver_ecno
--         was undefined — so the Final Rate/Qty inputs never appeared for
--         an Unfixed agreement's true final approval stage, no matter who
--         was approving.
--      b) The malformed approval_stages the frontend then submitted made
--         sp_approve_service_agreement's #approval_stages temp table end
--         up with approver_ecno = NULL for every row, so the
--         "SELECT @next_current_approver ... WHERE current_stage.approver_ecno
--         = @approved_by" lookup never matched anything and
--         @next_current_approver stayed NULL — i.e. it treated EVERY
--         approval as if it were the final stage, regardless of how many
--         stages the workflow actually has. Only visible on a 2+ stage
--         ServiceAgreement workflow (none configured live yet), which is
--         why it wasn't caught by the single-stage config used for this
--         session's test agreement — but it's a live correctness bug for
--         any future multi-stage config.
--    Fixed the same way PR already does it: a scalar subquery straight off
--    dbo.workflow_stage, no view, no extra wrapping.
--
-- 2) sp_approve_service_agreement had no transaction. Reproduced live:
--    approving AGR-2026-0002 (Unfixed, single-stage) without final_rate_amount/
--    final_qty (because of bug 1) wrote the APPROVED history row and cleared
--    current_approver_id to NULL, THEN hit the "Unfixed requires final
--    values" RAISERROR and exited — leaving the agreement stuck at
--    status='P' with current_approver_id=NULL: invisible to
--    sp_nt_GetServiceAgreementsForApproval (which filters on
--    current_approver_id = @Ecno) for every approver, permanently, with no
--    UI path to retry. Wrapped the real work (temp-table population
--    onward) in BEGIN TRANSACTION/COMMIT, with ROLLBACK added to the
--    existing CATCH block — every RAISERROR(...);RETURN; in this proc has
--    severity 16, which transfers control into CATCH, so this one change
--    covers all the early-exit paths without touching them individually.
--    The nested TRY/CATCH around sp_nt_IssueRecurringServicePOCycle is
--    untouched — that failure is already deliberately swallowed so a
--    downstream PO-issue problem doesn't undo a real approval.
--
-- Also includes a one-time data repair for the specific agreement this bug
-- was caught on (AGR-2026-0002), restoring it to a clean Pending state
-- with the original stage-1 approver so it can be re-approved correctly
-- once these fixes are live — safe to re-run (only touches that one row,
-- only if it's still in the stuck state).
-- ============================================================

-- ── 1) sp_nt_GetServiceAgreementsForApproval — flat stage_order_json ──────
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
    WHERE sa.is_active = 'Y' AND sa.status = 'P' AND sa.current_approver_id = @Ecno
    ORDER BY sa.agreement_sno DESC;
END;
GO

-- ── 2) sp_approve_service_agreement — transactional ────────────────────────
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
                @final_qty        DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.final_qty') AS DECIMAL(18,4));

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
            INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment)
            VALUES (@agreement_sno, 'REJECTED', @approved_by, @comments);

            UPDATE dbo.service_agreement SET status = 'R', current_approver_id = NULL WHERE agreement_sno = @agreement_sno;

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

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment)
        VALUES (@agreement_sno, 'APPROVED', @approved_by, @comments);

        UPDATE dbo.service_agreement SET current_approver_id = @next_current_approver WHERE agreement_sno = @agreement_sno;

        DECLARE @auto_po_result VARCHAR(200) = NULL, @auto_po_basic_sno INT = NULL, @auto_po_no VARCHAR(50) = NULL,
                @auto_pr_basic_sno INT = NULL, @auto_pr_no VARCHAR(20) = NULL;

        IF @next_current_approver IS NULL
        BEGIN
            -- ── Final stage: for Unfixed, require + apply the one-time real value ──
            DECLARE @service_type_code VARCHAR(30), @period_start DATE, @old_rate DECIMAL(18,2), @old_qty DECIMAL(18,4);
            SELECT @service_type_code = st.service_type_code, @period_start = sa.period_start_date,
                   @old_rate = sa.rate_amount, @old_qty = sa.qty
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

                UPDATE dbo.service_agreement SET rate_amount = @final_rate_amount, qty = @final_qty WHERE agreement_sno = @agreement_sno;

                INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment)
                VALUES (@agreement_sno, 'RATE_FINALIZED', @approved_by,
                        N'Rate ' + CAST(@old_rate AS VARCHAR(30)) + N' -> ' + CAST(@final_rate_amount AS VARCHAR(30))
                        + N', Qty ' + CAST(@old_qty AS VARCHAR(30)) + N' -> ' + CAST(@final_qty AS VARCHAR(30)));
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

-- ── 3) One-time data repair for AGR-2026-0002 (this session's test agreement) ──
-- Only touches it if it's still stuck (status='P', current_approver_id NULL,
-- has an APPROVED history row but no matching status change) — safe to re-run.
UPDATE sa
SET sa.current_approver_id = (
    SELECT JSON_VALUE(s.value, '$.approver_ecno')
    FROM OPENJSON((
        SELECT ws.stage_order_json FROM dbo.workflow_stage ws
        WHERE ws.workflow_types_id = sa.workflow_types_id AND ws.is_active = 'Y'
    )) AS s
    WHERE CAST(s.[key] AS INT) = 0
)
FROM dbo.service_agreement sa
WHERE sa.agreement_no = 'AGR-2026-0002'
  AND sa.status = 'P'
  AND sa.current_approver_id IS NULL
  AND EXISTS (
      SELECT 1 FROM dbo.service_agreement_history h
      WHERE h.agreement_sno = sa.agreement_sno AND h.action_type = 'APPROVED'
  );
GO
