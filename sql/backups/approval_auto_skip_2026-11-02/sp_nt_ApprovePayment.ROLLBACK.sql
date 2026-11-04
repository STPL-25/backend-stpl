-- ROLLBACK: live Non_trade_Dev definition of sp_nt_ApprovePayment taken 2026-11-02 before the auto-skip change
-- ── 4. approve / reject / forward / send back ───────────────────────────────
-- @jsonInput: { payment_sno, action: 'approve'|'reject'|'forward'|'send_back', approved_by, comments?, target_seq? }
--   forward   target_seq = a later stage (default: the caller picks one; stages in between are skipped)
--   send_back target_seq = an earlier stage that already acted in this round; remarks required
--   reject    remarks required
-- result = APPROVED_NEXT | FINAL | REJECTED | FORWARDED | SENT_BACK (+ next_approver). Errors are THROWN (56001-56019).
-- Like the PR engine this has no XACT_ABORT: a validation error leaves the caller's transaction rollback-able to our savepoint.
CREATE OR ALTER PROCEDURE dbo.sp_nt_ApprovePayment
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 56000, N'Invalid JSON payload.', 1;

    DECLARE @own_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    DECLARE @pay INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_sno') AS INT),
            @action VARCHAR(20) = LOWER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.action')))),
            @by VARCHAR(30) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.approved_by'))), ''),
            @comments NVARCHAR(1000) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.comments'))), ''),
            @target_seq INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.target_seq') AS INT);

    IF @pay IS NULL THROW 56001, N'Payment not found.', 1;
    IF @by IS NULL THROW 56003, N'The approver is required.', 1;
    IF @action IS NULL OR @action NOT IN ('approve', 'reject', 'forward', 'send_back') THROW 56005, N'action must be approve, reject, forward or send_back.', 1;
    IF @action IN ('reject', 'send_back') AND @comments IS NULL THROW 56004, N'Remarks are required for this action.', 1;

    DECLARE @status VARCHAR(20), @cur_appr VARCHAR(30), @wf INT, @creator VARCHAR(30), @pno VARCHAR(30), @vendor INT, @net DECIMAL(18,2),
            @com INT, @div INT, @brn INT, @dept INT;
    DECLARE @inst INT, @stages NVARCHAR(MAX), @cycle INT, @cur INT, @ret INT, @since DATETIME, @istatus CHAR(1);
    DECLARE @stage NVARCHAR(MAX), @stage_name NVARCHAR(100), @primary VARCHAR(30), @esc_h INT, @role VARCHAR(10);
    DECLARE @ctx NVARCHAR(MAX), @next INT, @next_appr VARCHAR(30), @result VARCHAR(20), @newstatus VARCHAR(20), @msg NVARCHAR(2048), @now DATETIME = GETDATE();

    BEGIN TRY
        IF @own_tran = 1
        BEGIN
            BEGIN TRAN;
        END
        ELSE
        BEGIN
            SAVE TRAN payment_approval_act;
        END

        SELECT @status = status, @cur_appr = current_approver_id, @wf = workflow_types_id, @creator = created_by, @pno = payment_no,
               @vendor = vendor_sno, @net = ISNULL(net_paid, amount), @com = com_sno, @div = div_sno, @brn = brn_sno, @dept = dept_sno
        FROM dbo.payment_info WITH (UPDLOCK) WHERE payment_sno = @pay AND is_active = 'Y';
        IF @status IS NULL THROW 56001, N'Payment not found.', 1;
        IF @status <> 'Pending Approval' THROW 56002, N'This payment is not awaiting approval.', 1;

        EXEC dbo.sp_nt_EnsurePaymentApprovalInstance @payment_sno = @pay;
        SELECT @inst = instance_id, @stages = stages_json, @cycle = cycle_no, @cur = current_seq, @ret = return_to_seq, @since = current_since, @istatus = status
        FROM dbo.approval_instance WITH (UPDLOCK, HOLDLOCK) WHERE entity_type = 'Payment' AND entity_ref_id = @pay;
        IF @inst IS NULL OR @istatus <> 'P' OR @cur IS NULL THROW 56002, N'This payment is not awaiting approval.', 1;

        SET @stage = (SELECT s.value FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@cur AS NVARCHAR(10)));
        SELECT @stage_name = JSON_VALUE(@stage, '$.stage'), @primary = JSON_VALUE(@stage, '$.approver_ecno'),
               @esc_h = ISNULL(TRY_CAST(JSON_VALUE(@stage, '$.escalation_hours') AS INT), 24);

        -- Self-heal: the payment was re-assigned outside the engine (manual SQL, a workflow approver replaced).
        IF ISNULL(@primary, '') <> ISNULL(@cur_appr, '')
        BEGIN
            DECLARE @healed INT;
            SELECT TOP 1 @healed = CAST(s.[key] AS INT) FROM OPENJSON(@stages) s WHERE JSON_VALUE(s.value, '$.approver_ecno') = @cur_appr ORDER BY CAST(s.[key] AS INT);
            IF @healed IS NULL THROW 56017, N'The approval chain and the current approver are out of step; ask an administrator to check the workflow.', 1;
            SET @cur = @healed;
            SET @stage = (SELECT s.value FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@cur AS NVARCHAR(10)));
            SELECT @stage_name = JSON_VALUE(@stage, '$.stage'), @primary = JSON_VALUE(@stage, '$.approver_ecno'),
                   @esc_h = ISNULL(TRY_CAST(JSON_VALUE(@stage, '$.escalation_hours') AS INT), 24);
            UPDATE dbo.approval_instance SET current_seq = @cur, current_since = @now, updated_at = @now WHERE instance_id = @inst;
            SET @since = @now;
        END

        -- who may act now
        IF @by = @primary
            SET @role = 'PRIMARY';
        ELSE IF EXISTS (SELECT 1 FROM OPENJSON(@stage, '$.alternates') a WHERE a.value COLLATE DATABASE_DEFAULT = @by)
        BEGIN
            IF DATEDIFF(MINUTE, @since, @now) >= @esc_h * 60
                SET @role = 'ALTERNATE';
            ELSE
            BEGIN
                SET @msg = CONCAT(N'You are the alternate approver for this stage. You can act once it has been pending for ', @esc_h,
                                  N' hours (from ', CONVERT(VARCHAR(16), DATEADD(HOUR, @esc_h, @since), 120), N').');
                THROW 56018, @msg, 1;
            END
        END
        ELSE
            THROW 56003, N'You are not the current approver of this payment.', 1;

        SELECT @ctx = context_json FROM dbo.fn_payment_approval_context(@pay);

        -- ════════ APPROVE ════════
        IF @action = 'approve'
        BEGIN
            SET @next = CASE WHEN @ret IS NOT NULL THEN @ret ELSE dbo.fn_approval_next_seq(@stages, @cur, @ctx) END;

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, to_seq, stage_name, acted_by, acted_as, comments)
            VALUES (@inst, 'Payment', @pay, @cycle, 'APPROVE', @cur, @next, @stage_name, @by, @role, @comments);

            IF @ret IS NULL
                INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, stage_name, acted_by, acted_as, comments)
                SELECT @inst, 'Payment', @pay, @cycle, 'SKIP', CAST(s.[key] AS INT), JSON_VALUE(s.value, '$.stage'), @by, 'SYSTEM', N'Not required - approval condition not met'
                FROM OPENJSON(@stages) s WHERE CAST(s.[key] AS INT) > @cur AND (@next IS NULL OR CAST(s.[key] AS INT) < @next);

            INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment) VALUES (@pay, 'APPROVED', @by, LEFT(@comments, 500));

            IF @next IS NULL
            BEGIN
                UPDATE dbo.approval_instance SET status = 'A', current_seq = NULL, return_to_seq = NULL, updated_at = @now WHERE instance_id = @inst;
                UPDATE dbo.payment_info SET status = 'Approved', current_approver_id = NULL, approved_at = @now, modified_by = @by, modified_date = @now WHERE payment_sno = @pay;
                SET @next_appr = NULL; SET @result = 'FINAL'; SET @newstatus = 'Approved';
            END
            ELSE
            BEGIN
                SET @next_appr = (SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@next AS NVARCHAR(10)));
                IF @next_appr IS NULL THROW 56013, N'The next approval stage has no approver configured.', 1;
                UPDATE dbo.approval_instance SET current_seq = @next, return_to_seq = NULL, current_since = @now, updated_at = @now WHERE instance_id = @inst;
                UPDATE dbo.payment_info SET current_approver_id = @next_appr, modified_by = @by, modified_date = @now WHERE payment_sno = @pay;
                SET @result = 'APPROVED_NEXT'; SET @newstatus = 'Pending Approval';
            END
        END

        -- ════════ REJECT ════════
        ELSE IF @action = 'reject'
        BEGIN
            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, stage_name, acted_by, acted_as, comments)
            VALUES (@inst, 'Payment', @pay, @cycle, 'REJECT', @cur, @stage_name, @by, @role, @comments);
            EXEC dbo.sp_nt_ReversePaymentReservation @payment_sno = @pay, @by = @by, @reason = @comments;
            UPDATE dbo.approval_instance SET status = 'R', current_seq = NULL, return_to_seq = NULL, updated_at = @now WHERE instance_id = @inst;
            UPDATE dbo.payment_info SET status = 'Rejected', current_approver_id = NULL, modified_by = @by, modified_date = @now WHERE payment_sno = @pay;
            INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment) VALUES (@pay, 'REJECTED', @by, LEFT(@comments, 500));
            SET @next_appr = NULL; SET @next = NULL; SET @result = 'REJECTED'; SET @newstatus = 'Rejected';
        END

        -- ════════ FORWARD (to a later stage, even one the rules did not require) ════════
        ELSE IF @action = 'forward'
        BEGIN
            IF ISNULL(JSON_VALUE(@stage, '$.can_forward'), 'N') <> 'Y' THROW 56011, N'This stage is not allowed to forward.', 1;
            IF @target_seq IS NULL OR @target_seq <= @cur THROW 56012, N'Choose a later stage to forward to.', 1;
            SET @next_appr = NULLIF(LTRIM(RTRIM((SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@target_seq AS NVARCHAR(10))))), '');
            IF @next_appr IS NULL THROW 56013, N'That stage does not exist or has no approver.', 1;

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, to_seq, stage_name, acted_by, acted_as, target_ecno, comments)
            VALUES (@inst, 'Payment', @pay, @cycle, 'FORWARD', @cur, @target_seq, @stage_name, @by, @role, @next_appr, @comments);
            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, stage_name, acted_by, acted_as, comments)
            SELECT @inst, 'Payment', @pay, @cycle, 'SKIP', CAST(s.[key] AS INT), JSON_VALUE(s.value, '$.stage'), @by, 'SYSTEM', N'Bypassed - forwarded past this stage'
            FROM OPENJSON(@stages) s WHERE CAST(s.[key] AS INT) > @cur AND CAST(s.[key] AS INT) < @target_seq;

            UPDATE dbo.approval_instance SET current_seq = @target_seq, return_to_seq = NULL, current_since = @now, updated_at = @now WHERE instance_id = @inst;
            UPDATE dbo.payment_info SET current_approver_id = @next_appr, modified_by = @by, modified_date = @now WHERE payment_sno = @pay;
            INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment)
            VALUES (@pay, 'FORWARDED', @by, LEFT(CONCAT(N'Forwarded to ', @next_appr, CASE WHEN @comments IS NULL THEN N'' ELSE N': ' + @comments END), 500));
            SET @next = @target_seq; SET @result = 'FORWARDED'; SET @newstatus = 'Pending Approval';
        END

        -- ════════ SEND BACK (to an earlier approver who already acted in this round) ════════
        ELSE IF @action = 'send_back'
        BEGIN
            IF ISNULL(JSON_VALUE(@stage, '$.can_backward'), 'N') <> 'Y' THROW 56014, N'This stage is not allowed to send back.', 1;
            IF @target_seq IS NULL OR @target_seq >= @cur THROW 56015, N'Choose an earlier approver to send this back to.', 1;
            IF NOT EXISTS (SELECT 1 FROM dbo.approval_action_log
                           WHERE instance_id = @inst AND cycle_no = @cycle AND from_seq = @target_seq AND action IN ('APPROVE', 'FORWARD'))
                THROW 56016, N'You can send back only to an approver who has already acted on this payment.', 1;
            SET @next_appr = NULLIF(LTRIM(RTRIM((SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@target_seq AS NVARCHAR(10))))), '');
            IF @next_appr IS NULL THROW 56013, N'That stage does not exist or has no approver.', 1;

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, to_seq, stage_name, acted_by, acted_as, target_ecno, comments)
            VALUES (@inst, 'Payment', @pay, @cycle, 'SEND_BACK', @cur, @target_seq, @stage_name, @by, @role, @next_appr, @comments);

            UPDATE dbo.approval_instance SET current_seq = @target_seq, return_to_seq = @cur, current_since = @now, updated_at = @now WHERE instance_id = @inst;
            UPDATE dbo.payment_info SET current_approver_id = @next_appr, modified_by = @by, modified_date = @now WHERE payment_sno = @pay;
            INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment)
            VALUES (@pay, 'SENT_BACK', @by, LEFT(CONCAT(N'Sent back to ', @next_appr, N': ', @comments), 500));
            SET @next = @target_seq; SET @result = 'SENT_BACK'; SET @newstatus = 'Pending Approval';
        END

        IF @own_tran = 1 COMMIT TRAN;

        SELECT @result AS result, @pay AS payment_sno, @pno AS payment_no, @vendor AS vendor_sno, @net AS net_paid, @creator AS created_by,
               @next_appr AS next_approver, @newstatus AS status, @com AS com_sno, @div AS div_sno, @brn AS brn_sno, @dept AS dept_sno,
               @role AS acted_as, @stage_name AS stage_name, @next AS next_seq;
    END TRY
    BEGIN CATCH
        IF @own_tran = 1
        BEGIN
            IF XACT_STATE() <> 0 ROLLBACK TRAN;
        END
        ELSE IF XACT_STATE() = 1
        BEGIN
            ROLLBACK TRAN payment_approval_act;      -- undo only our own writes; the caller decides the rest
        END;
        THROW;
    END CATCH
END
GO
