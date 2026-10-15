-- ── 5. The engine ───────────────────────────────────────────────────────────
-- @jsonInput: {"pr_no":"PR2627..","action":"approve|reject|forward|send_back|edit|resubmit",
--              "approved_by":"<session ecno>","comments":"..",
--              "target_seq":2,            -- forward (later stage) / send_back (earlier stage that acted)
--              "target":"REQUESTER",      -- send_back to the person who raised it
--              "edits":{"purpose":"..","required_date":"2026-10-01","priority_sno":1,
--                       "items":[{"pr_item_sno":12,"qty":5,"est_cost":100}]}}
-- Real errors are THROWN (the old procedure returned an 'ERROR' row that the screen
-- read as success).
CREATE     PROCEDURE dbo.sp_nt_PrApprovalAct
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    -- No XACT_ABORT: a validation THROW must leave the caller's transaction (if any)
    -- rollback-able to our savepoint instead of dooming it.

    IF ISJSON(@jsonInput) = 0
        THROW 52001, N'Invalid JSON payload.', 1;

    DECLARE @own_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    DECLARE @pr_in       VARCHAR(30)    = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.pr_no'))), ''),
            @action      VARCHAR(20)    = LOWER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.action')))),
            @by          VARCHAR(30)    = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.approved_by'))), ''),
            @comments    NVARCHAR(1000) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.comments'))), ''),
            @target_seq  INT            = TRY_CAST(JSON_VALUE(@jsonInput, '$.target_seq') AS INT),
            @target      VARCHAR(30)    = UPPER(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.target'))), '')),
            @edits       NVARCHAR(MAX)  = JSON_QUERY(@jsonInput, '$.edits');

    IF @pr_in IS NULL THROW 52002, N'pr_no is required.', 1;
    IF @by IS NULL    THROW 52003, N'Approver EC number is required.', 1;
    IF @action IS NULL OR @action NOT IN ('approve','reject','forward','send_back','edit','resubmit')
        THROW 52004, N'Invalid action. Use approve | reject | forward | send_back | edit | resubmit.', 1;
    IF @action IN ('reject','send_back','edit') AND @comments IS NULL
        THROW 52008, N'A comment is required for this action.', 1;

    -- The approval screen lists a split PR as "PRxxxx/2"; the row itself is the base number.
    DECLARE @pr_no VARCHAR(30) = LEFT(@pr_in, CASE WHEN CHARINDEX('/', @pr_in) > 0 THEN CHARINDEX('/', @pr_in) - 1 ELSE LEN(@pr_in) END);

    DECLARE @pr_sno INT, @pr_status CHAR(1), @created_by VARCHAR(20), @mode VARCHAR(30), @wf INT, @cur_appr VARCHAR(20);
    DECLARE @inst INT, @stages NVARCHAR(MAX), @cycle INT, @cur INT, @ret INT, @await BIT, @since DATETIME, @istatus CHAR(1);
    DECLARE @stage NVARCHAR(MAX), @stage_name NVARCHAR(100), @primary VARCHAR(30), @esc_h INT, @role VARCHAR(10);
    DECLARE @ctx NVARCHAR(MAX);
    DECLARE @next INT, @next_appr VARCHAR(30), @result VARCHAR(20), @msg NVARCHAR(2048), @now DATETIME = GETDATE();
    DECLARE @before NVARCHAR(MAX), @after NVARCHAR(MAX), @hist_floor INT;

    BEGIN TRY
        IF @own_tran = 1
        BEGIN
            BEGIN TRAN;
        END
        ELSE
        BEGIN
            SAVE TRAN pr_approval_act;
        END

        SELECT @pr_sno = pr_basic_sno, @pr_status = status, @created_by = created_by,
               @mode = request_mode, @wf = workflow_types_id, @cur_appr = current_approver_id
        FROM dbo.pr_basic_info WITH (UPDLOCK)
        WHERE pr_no = @pr_no AND is_active = 'Y';

        IF @pr_sno IS NULL THROW 52005, N'Purchase Request not found or inactive.', 1;
        IF @pr_status <> 'P' THROW 52009, N'This Purchase Request is no longer pending approval.', 1;

        -- ── the approval instance (created by the trigger; rebuilt here for PRs raised before it existed)
        SELECT @inst = instance_id, @stages = stages_json, @cycle = cycle_no, @cur = current_seq, @ret = return_to_seq,
               @await = awaiting_requester, @since = current_since, @istatus = status
        FROM dbo.approval_instance WITH (UPDLOCK, HOLDLOCK)
        WHERE entity_type = 'PurchaseRequisition' AND entity_ref_id = @pr_sno;

        IF @inst IS NULL
        BEGIN
            SELECT TOP 1 @stages = stage_order_json FROM dbo.workflow_stage
            WHERE workflow_types_id = @wf AND is_active = 'Y' AND ISJSON(stage_order_json) = 1 ORDER BY stage_id;
            IF @stages IS NULL
            BEGIN
                -- The workflow this PR was raised under has since been retired (no active stages). Rather than
                -- strand the PR, give it a single stage held by whoever it is currently with.
                IF @cur_appr IS NULL THROW 52006, N'No approval stages are configured for this requisition.', 1;
                SET @stages = (SELECT @cur_appr AS approver_ecno, N'Approval' AS stage, '1' AS required_approvals, 'Y' AS is_mandatory,
                                      '24' AS escalation_hours, '' AS approver_condition, '' AS next_approver_ecno,
                                      'N' AS can_forward, 'N' AS can_backward, 'N' AS can_edit_data FOR JSON PATH);
            END

            SELECT TOP 1 @cur = CAST(s.[key] AS INT) FROM OPENJSON(@stages) s
            WHERE JSON_VALUE(s.value, '$.approver_ecno') = @cur_appr ORDER BY CAST(s.[key] AS INT);
            IF @cur IS NULL THROW 52007, N'Could not work out the current approval stage for this requisition.', 1;

            INSERT INTO dbo.approval_instance (entity_type, entity_ref_id, workflow_types_id, stages_json, cycle_no, current_seq, status, current_since)
            VALUES ('PurchaseRequisition', @pr_sno, @wf, @stages, 1, @cur, 'P', @now);
            SELECT @inst = SCOPE_IDENTITY(), @cycle = 1, @ret = NULL, @await = 0, @since = @now, @istatus = 'P';
        END

        IF @istatus <> 'P' THROW 52009, N'This Purchase Request is no longer pending approval.', 1;

        SET @stage = (SELECT s.value FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@cur AS NVARCHAR(10)));
        SELECT @stage_name = JSON_VALUE(@stage, '$.stage'),
               @primary    = JSON_VALUE(@stage, '$.approver_ecno'),
               @esc_h      = ISNULL(TRY_CAST(JSON_VALUE(@stage, '$.escalation_hours') AS INT), 24);

        -- Self-heal: the PR was re-assigned outside the engine (manual SQL, an older screen).
        IF @await = 0 AND ISNULL(@primary, '') <> ISNULL(@cur_appr, '')
        BEGIN
            DECLARE @healed INT;
            SELECT TOP 1 @healed = CAST(s.[key] AS INT) FROM OPENJSON(@stages) s
            WHERE JSON_VALUE(s.value, '$.approver_ecno') = @cur_appr ORDER BY CAST(s.[key] AS INT);
            IF @healed IS NULL THROW 52007, N'The approval chain and the current approver are out of step; ask an administrator to check the workflow.', 1;
            SET @cur = @healed;
            SET @stage = (SELECT s.value FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@cur AS NVARCHAR(10)));
            SELECT @stage_name = JSON_VALUE(@stage, '$.stage'), @primary = JSON_VALUE(@stage, '$.approver_ecno'),
                   @esc_h = ISNULL(TRY_CAST(JSON_VALUE(@stage, '$.escalation_hours') AS INT), 24);
            UPDATE dbo.approval_instance SET current_seq = @cur, current_since = @now, updated_at = @now WHERE instance_id = @inst;
            SET @since = @now;
        END

        -- ── who may act now
        IF @await = 1
        BEGIN
            IF @by <> @created_by
                THROW 52020, N'This requisition was sent back to the requester and is waiting for their correction.', 1;
            IF @action NOT IN ('edit','resubmit')
                THROW 52021, N'The requester can only edit or resubmit a requisition that was sent back.', 1;
            SET @role = 'REQUESTER';
        END
        ELSE
        BEGIN
            IF @action = 'resubmit'
                THROW 52022, N'Resubmit applies only to a requisition that was sent back to the requester.', 1;

            IF @by = @primary
                SET @role = 'PRIMARY';
            ELSE IF EXISTS (SELECT 1 FROM OPENJSON(@stage, '$.alternates') a WHERE a.value COLLATE DATABASE_DEFAULT = @by)
            BEGIN
                IF DATEDIFF(MINUTE, @since, @now) >= @esc_h * 60
                    SET @role = 'ALTERNATE';
                ELSE
                BEGIN
                    SET @msg = CONCAT(N'You are the alternate approver for this stage. You can act once it has been pending for ',
                                      @esc_h, N' hours (from ', CONVERT(VARCHAR(16), DATEADD(HOUR, @esc_h, @since), 120), N').');
                    THROW 52023, @msg, 1;
                END
            END
            ELSE
            BEGIN
                SET @msg = CONCAT(N'User ', @by, N' is not the current approver (expected ', ISNULL(@primary, N'-'), N').');
                THROW 52024, @msg, 1;
            END
        END

        SELECT @ctx = context_json FROM dbo.fn_pr_approval_context(@pr_sno);

        -- ════════ APPROVE ════════
        IF @action = 'approve'
        BEGIN
            SET @next = CASE WHEN @ret IS NOT NULL THEN @ret
                             ELSE dbo.fn_approval_next_seq(@stages, @cur, @ctx) END;

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, to_seq, stage_name, acted_by, acted_as, comments)
            VALUES (@inst, 'PurchaseRequisition', @pr_sno, @cycle, 'APPROVE', @cur, @next, @stage_name, @by, @role, @comments);

            IF @ret IS NULL
                INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, stage_name, acted_by, acted_as, comments)
                SELECT @inst, 'PurchaseRequisition', @pr_sno, @cycle, 'SKIP', CAST(s.[key] AS INT), JSON_VALUE(s.value, '$.stage'), @by, 'SYSTEM',
                       N'Not required - approval condition not met'
                FROM OPENJSON(@stages) s
                WHERE CAST(s.[key] AS INT) > @cur AND (@next IS NULL OR CAST(s.[key] AS INT) < @next);

            INSERT INTO dbo.pr_history_data (pr_basic_sno, pr_edit_data, workflow_types_id, approver_ecno, status, status_by, status_date, commends, is_active, pr_no)
            VALUES (@pr_sno, NULL, NULL, @primary, 'A', @by, @now, LEFT(@comments, 250), 'Y', @pr_no);

            IF @next IS NULL
            BEGIN
                UPDATE dbo.approval_instance SET status = 'A', current_seq = NULL, return_to_seq = NULL, updated_at = @now WHERE instance_id = @inst;
                UPDATE dbo.pr_basic_info SET current_approver_id = NULL, status = 'A' WHERE pr_basic_sno = @pr_sno;
                SET @next_appr = NULL;
            END
            ELSE
            BEGIN
                SET @next_appr = (SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@next AS NVARCHAR(10)));
                IF @next_appr IS NULL THROW 52011, N'The next approval stage has no approver configured.', 1;
                UPDATE dbo.approval_instance SET current_seq = @next, return_to_seq = NULL, current_since = @now, updated_at = @now WHERE instance_id = @inst;
                UPDATE dbo.pr_basic_info SET current_approver_id = @next_appr WHERE pr_basic_sno = @pr_sno;
            END
            SET @result = 'SUCCESS';
        END

        -- ════════ REJECT ════════
        ELSE IF @action = 'reject'
        BEGIN
            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, stage_name, acted_by, acted_as, comments)
            VALUES (@inst, 'PurchaseRequisition', @pr_sno, @cycle, 'REJECT', @cur, @stage_name, @by, @role, @comments);

            INSERT INTO dbo.pr_history_data (pr_basic_sno, pr_edit_data, workflow_types_id, approver_ecno, status, status_by, status_date, commends, is_active, pr_no)
            VALUES (@pr_sno, NULL, NULL, @primary, 'R', @by, @now, LEFT(@comments, 250), 'Y', @pr_no);

            UPDATE dbo.approval_instance SET status = 'R', current_seq = NULL, return_to_seq = NULL, updated_at = @now WHERE instance_id = @inst;
            UPDATE dbo.pr_basic_info SET status = 'R', current_approver_id = NULL WHERE pr_basic_sno = @pr_sno;
            SET @result = 'REJECTED';
        END

        -- ════════ FORWARD (jump to a later stage, even one the rules did not require) ════════
        ELSE IF @action = 'forward'
        BEGIN
            IF ISNULL(JSON_VALUE(@stage, '$.can_forward'), 'N') <> 'Y'
                THROW 52030, N'This stage is not allowed to forward.', 1;
            IF @target_seq IS NULL OR @target_seq <= @cur
                THROW 52031, N'Choose a later stage to forward to.', 1;

            SET @next_appr = (SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@target_seq AS NVARCHAR(10)));
            IF @next_appr IS NULL THROW 52032, N'That stage does not exist or has no approver.', 1;

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, to_seq, stage_name, acted_by, acted_as, target_ecno, comments)
            VALUES (@inst, 'PurchaseRequisition', @pr_sno, @cycle, 'FORWARD', @cur, @target_seq, @stage_name, @by, @role, @next_appr, @comments);

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, stage_name, acted_by, acted_as, comments)
            SELECT @inst, 'PurchaseRequisition', @pr_sno, @cycle, 'SKIP', CAST(s.[key] AS INT), JSON_VALUE(s.value, '$.stage'), @by, 'SYSTEM',
                   N'Bypassed - forwarded past this stage'
            FROM OPENJSON(@stages) s
            WHERE CAST(s.[key] AS INT) > @cur AND CAST(s.[key] AS INT) < @target_seq;

            UPDATE dbo.approval_instance SET current_seq = @target_seq, return_to_seq = NULL, current_since = @now, updated_at = @now WHERE instance_id = @inst;
            UPDATE dbo.pr_basic_info SET current_approver_id = @next_appr WHERE pr_basic_sno = @pr_sno;
            SET @next = @target_seq;
            SET @result = 'FORWARDED';
        END

        -- ════════ SEND BACK (requester, or a stage that already acted in this cycle) ════════
        ELSE IF @action = 'send_back'
        BEGIN
            IF ISNULL(JSON_VALUE(@stage, '$.can_backward'), 'N') <> 'Y'
                THROW 52040, N'This stage is not allowed to send back.', 1;

            IF @target = 'REQUESTER'
            BEGIN
                INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, to_seq, stage_name, acted_by, acted_as, target_ecno, comments)
                VALUES (@inst, 'PurchaseRequisition', @pr_sno, @cycle, 'SEND_BACK', @cur, NULL, @stage_name, @by, @role, @created_by, @comments);

                UPDATE dbo.approval_instance SET awaiting_requester = 1, return_to_seq = @cur, current_since = @now, updated_at = @now WHERE instance_id = @inst;
                UPDATE dbo.pr_basic_info SET current_approver_id = @created_by WHERE pr_basic_sno = @pr_sno;
                SET @next_appr = @created_by;
            END
            ELSE
            BEGIN
                IF @target_seq IS NULL OR @target_seq >= @cur
                    THROW 52041, N'Choose the requester or an earlier approver to send this back to.', 1;
                IF NOT EXISTS (SELECT 1 FROM dbo.approval_action_log
                               WHERE instance_id = @inst AND cycle_no = @cycle AND from_seq = @target_seq AND action IN ('APPROVE','FORWARD'))
                    THROW 52042, N'You can send back only to the requester or to an approver who has already acted on this requisition.', 1;

                SET @next_appr = (SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@target_seq AS NVARCHAR(10)));

                INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, to_seq, stage_name, acted_by, acted_as, target_ecno, comments)
                VALUES (@inst, 'PurchaseRequisition', @pr_sno, @cycle, 'SEND_BACK', @cur, @target_seq, @stage_name, @by, @role, @next_appr, @comments);

                UPDATE dbo.approval_instance SET current_seq = @target_seq, return_to_seq = @cur, current_since = @now, updated_at = @now WHERE instance_id = @inst;
                UPDATE dbo.pr_basic_info SET current_approver_id = @next_appr WHERE pr_basic_sno = @pr_sno;
                SET @next = @target_seq;
            END
            SET @result = 'SENT_BACK';
        END

        -- ════════ RESUBMIT (requester, no changes) ════════
        ELSE IF @action = 'resubmit'
        BEGIN
            SET @next = ISNULL(@ret, @cur);
            SET @next_appr = (SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@next AS NVARCHAR(10)));

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, to_seq, stage_name, acted_by, acted_as, target_ecno, comments)
            VALUES (@inst, 'PurchaseRequisition', @pr_sno, @cycle, 'RESUBMIT', NULL, @next, @stage_name, @by, @role, @next_appr, @comments);

            UPDATE dbo.approval_instance SET awaiting_requester = 0, current_seq = @next, return_to_seq = NULL, current_since = @now, updated_at = @now WHERE instance_id = @inst;
            UPDATE dbo.pr_basic_info SET current_approver_id = @next_appr WHERE pr_basic_sno = @pr_sno;
            SET @result = 'RESUBMITTED';
        END

        -- ════════ EDIT VALUES (always restarts the approval) ════════
        ELSE IF @action = 'edit'
        BEGIN
            IF @role <> 'REQUESTER' AND ISNULL(JSON_VALUE(@stage, '$.can_edit_data'), 'N') <> 'Y'
                THROW 52050, N'This stage is not allowed to edit values.', 1;
            IF @mode = 'VENDOR_DRIVEN'
                THROW 52051, N'Editing values is not supported for vendor-driven requisitions yet.', 1;
            IF @edits IS NULL OR ISJSON(@edits) = 0
                THROW 52052, N'No edits were supplied.', 1;

            DECLARE @new_purpose VARCHAR(200) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@edits, '$.purpose'))), ''),
                    @new_req     DATE         = TRY_CAST(JSON_VALUE(@edits, '$.required_date') AS DATE),
                    @new_prio    INT          = TRY_CAST(JSON_VALUE(@edits, '$.priority_sno') AS INT);

            CREATE TABLE #edit_items (pr_item_sno INT PRIMARY KEY, qty DECIMAL(10,3) NULL, est_cost DECIMAL(10,3) NULL);
            INSERT INTO #edit_items (pr_item_sno, qty, est_cost)
            SELECT e.pr_item_sno, e.qty, e.est_cost
            FROM OPENJSON(@edits, '$.items') WITH (pr_item_sno INT '$.pr_item_sno', qty DECIMAL(10,3) '$.qty', est_cost DECIMAL(10,3) '$.est_cost') e
            WHERE e.pr_item_sno IS NOT NULL;

            IF EXISTS (SELECT 1 FROM #edit_items e
                       WHERE NOT EXISTS (SELECT 1 FROM dbo.pr_item_details i
                                         WHERE i.pr_item_sno = e.pr_item_sno AND i.pr_basic_sno = @pr_sno AND i.is_active = 'Y'))
                THROW 52053, N'One of the edited lines does not belong to this requisition.', 1;
            IF EXISTS (SELECT 1 FROM #edit_items WHERE qty <= 0 OR est_cost < 0)
                THROW 52054, N'Quantity must be greater than zero and cost cannot be negative.', 1;
            IF EXISTS (SELECT 1 FROM #edit_items e JOIN dbo.pr_item_details i ON i.pr_item_sno = e.pr_item_sno
                       WHERE ISNULL(e.qty, i.qty) * ISNULL(e.est_cost, i.est_cost) > 9999999)
                THROW 52055, N'A line total exceeds the allowed limit.', 1;
            IF @new_prio IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.priority_master WHERE priority_sno = @new_prio)
                THROW 52056, N'Unknown priority.', 1;

            SET @before = (SELECT
                              (SELECT purpose, required_date, priority_sno FROM dbo.pr_basic_info WHERE pr_basic_sno = @pr_sno FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS header,
                              (SELECT i.pr_item_sno, i.qty, i.est_cost, i.total_cost FROM dbo.pr_item_details i
                               WHERE i.pr_basic_sno = @pr_sno AND i.is_active = 'Y' FOR JSON PATH) AS items,
                              (SELECT amount FROM dbo.fn_pr_approval_context(@pr_sno)) AS amount
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            UPDATE dbo.pr_basic_info
            SET purpose = ISNULL(@new_purpose, purpose), required_date = ISNULL(@new_req, required_date),
                priority_sno = ISNULL(@new_prio, priority_sno), modified_by = @by, modified_date = CAST(@now AS DATE)
            WHERE pr_basic_sno = @pr_sno;

            UPDATE i
            SET qty = ISNULL(e.qty, i.qty), est_cost = ISNULL(e.est_cost, i.est_cost),
                total_cost = ROUND(ISNULL(e.qty, i.qty) * ISNULL(e.est_cost, i.est_cost), 3),
                modified_by = @by, modified_date = CAST(@now AS DATE)
            FROM dbo.pr_item_details i JOIN #edit_items e ON e.pr_item_sno = i.pr_item_sno
            WHERE i.pr_basic_sno = @pr_sno AND i.is_active = 'Y';

            SET @after = (SELECT
                              (SELECT purpose, required_date, priority_sno FROM dbo.pr_basic_info WHERE pr_basic_sno = @pr_sno FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS header,
                              (SELECT i.pr_item_sno, i.qty, i.est_cost, i.total_cost FROM dbo.pr_item_details i
                               WHERE i.pr_basic_sno = @pr_sno AND i.is_active = 'Y' FOR JSON PATH) AS items,
                              (SELECT amount FROM dbo.fn_pr_approval_context(@pr_sno)) AS amount
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            DROP TABLE #edit_items;

            IF @before = @after
                THROW 52057, N'Nothing was changed, so the approval was not restarted.', 1;

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, stage_name, acted_by, acted_as, comments, before_json, after_json)
            VALUES (@inst, 'PurchaseRequisition', @pr_sno, @cycle, 'EDIT', @cur, @stage_name, @by, @role, @comments, @before, @after);

            -- restart: fresh cycle from stage 1 on the current workflow definition
            DECLARE @fresh NVARCHAR(MAX) = (SELECT TOP 1 stage_order_json FROM dbo.workflow_stage
                                            WHERE workflow_types_id = @wf AND is_active = 'Y' AND ISJSON(stage_order_json) = 1 ORDER BY stage_id);
            IF @fresh IS NOT NULL SET @stages = @fresh;
            SET @next_appr = (SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = '0');
            IF @next_appr IS NULL THROW 52011, N'The first approval stage has no approver configured.', 1;
            SET @hist_floor = ISNULL((SELECT MAX(pr_history_sno) FROM dbo.pr_history_data WHERE pr_basic_sno = @pr_sno), 0);

            UPDATE dbo.approval_instance
            SET stages_json = @stages, cycle_no = @cycle + 1, current_seq = 0, return_to_seq = NULL, awaiting_requester = 0,
                status = 'P', current_since = @now, history_floor = @hist_floor, updated_at = @now
            WHERE instance_id = @inst;
            UPDATE dbo.pr_basic_info SET current_approver_id = @next_appr WHERE pr_basic_sno = @pr_sno;

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, to_seq, stage_name, acted_by, acted_as, target_ecno, comments)
            VALUES (@inst, 'PurchaseRequisition', @pr_sno, @cycle + 1, 'RESTART', 0, JSON_VALUE((SELECT s.value FROM OPENJSON(@stages) s WHERE s.[key] = '0'), '$.stage'),
                    @by, 'SYSTEM', @next_appr, N'Approval restarted from the first stage after values were edited');
            SET @next = 0;
            SET @result = 'EDITED';
        END

        IF @own_tran = 1 COMMIT TRAN;

        SELECT @result                                AS result,
               @pr_no                                 AS pr_no,
               @by                                    AS approved_by,
               @now                                   AS approved_on,
               1                                      AS stages_processed,
               CASE WHEN @result = 'REJECTED' THEN NULL
                    ELSE ISNULL(@next_appr, 'FINAL_STAGE') END AS next_approver,
               CAST(NULL AS VARCHAR(200))             AS next_condition,
               CAST(NULL AS CHAR(1))                  AS next_can_forward,
               @pr_sno                                AS pr_basic_sno,
               @mode                                  AS request_mode,
               @next                                  AS next_seq,
               @role                                  AS acted_as;
    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#edit_items') IS NOT NULL DROP TABLE #edit_items;
        IF @own_tran = 1
        BEGIN
            IF XACT_STATE() <> 0 ROLLBACK TRAN;
        END
        ELSE IF XACT_STATE() = 1
        BEGIN
            ROLLBACK TRAN pr_approval_act;      -- undo only our own writes; the caller decides the rest
        END;
        THROW;
    END CATCH
END