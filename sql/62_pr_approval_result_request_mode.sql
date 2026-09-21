-- ============================================================
-- sp_approve_pr_datas v2
-- Database: Non_trade_Dev (MSSQL)
--
-- Surgical addition only: both result sets (REJECTED and SUCCESS/approve)
-- now also return pr_basic_info.request_mode. The Node approval path
-- (PR.controller.js#approvePr) needs this to know whether a just-approved
-- PR is VENDOR_DRIVEN, so it can auto-issue the child PO
-- (sp_nt_CreateVendorDrivenPOFromPR) right after a final-stage approval —
-- without this, the Node layer would need a second round-trip query just
-- to check request_mode. Every other line of this procedure is byte-for-
-- byte unchanged from the live version.
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_approve_pr_datas
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        -- Validate JSON input
        IF ISJSON(@jsonInput) = 0
        BEGIN
            RAISERROR('Invalid JSON format for @jsonInput', 16, 1);
            RETURN;
        END

        -- Extract scalar fields
        DECLARE @pr_no           VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.pr_no'),
                @comments        VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by     VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action          VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');  -- 'approve' or 'reject'

        -- Validate action
        IF @action IS NULL OR LTRIM(RTRIM(LOWER(@action))) NOT IN ('approve', 'reject')
        BEGIN
            RAISERROR('Invalid action. Must be ''approve'' or ''reject''.', 16, 1);
            RETURN;
        END

        -- Normalize action to lowercase for comparison
        SET @action = LOWER(LTRIM(RTRIM(@action)));

        -- Validate approval_stages
        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
        BEGIN
            RAISERROR('Invalid or missing approval_stages in JSON', 16, 1);
            RETURN;
        END

        -- Validate approver
        IF @approved_by IS NULL OR LTRIM(RTRIM(@approved_by)) = ''
        BEGIN
            RAISERROR('Approver EC number is required.', 16, 1);
            RETURN;
        END

        -- ✅ TEMP TABLE
        CREATE TABLE #approval_stages (
            seq_no               INT,
            approver_ecno        VARCHAR(30),
            stage                VARCHAR(100),
            required_approvals   VARCHAR(10),
            is_mandatory         CHAR(1),
            escalation_hours     VARCHAR(10),
            approver_condition   VARCHAR(200),
            next_approver_ecno   VARCHAR(30),
            can_forward          CHAR(1),
            can_backward         CHAR(1),
            can_edit_data        CHAR(1)
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

        -- Check PR exists
        DECLARE @pr_basic_sno INT;
        DECLARE @request_mode VARCHAR(30);

        SELECT @pr_basic_sno = pr_basic_sno, @request_mode = request_mode
        FROM pr_basic_info
        WHERE pr_no = @pr_no AND is_active = 'Y';

        IF @pr_basic_sno IS NULL
        BEGIN
            RAISERROR('Purchase Request not found or inactive: %s', 16, 1, @pr_no);
            RETURN;
        END

        -- =============================================
        -- ✅ REJECT FLOW
        -- =============================================
        IF @action = 'reject'
        BEGIN
            -- Insert rejection into history with status = 'R'
            INSERT INTO pr_history_data (
                pr_basic_sno, pr_edit_data, workflow_types_id,
                approver_ecno, status, status_by,
                status_date, commends, is_active, pr_no
            )
            SELECT
                @pr_basic_sno,
                NULL,
                NULL,
                s.approver_ecno,
                'R',                -- R = Rejected
                @approved_by,
                GETDATE(),
                @comments,          -- Rejection reason stored as comments
                'Y',
                @pr_no
            FROM #approval_stages s
            WHERE s.approver_ecno = @approved_by;

            -- Update PR basic info: status = 'R', clear current approver
            UPDATE pr_basic_info
            SET status             = 'R',           -- R = Rejected
                current_approver_id = NULL           -- No further approval needed
            WHERE pr_basic_sno = @pr_basic_sno;

            DROP TABLE #approval_stages;

            -- Return rejection result
            SELECT
                'REJECTED'       AS result,
                @pr_no           AS pr_no,
                @approved_by     AS rejected_by,
                GETDATE()        AS rejected_on,
                @comments        AS rejection_reason,
                @request_mode    AS request_mode;

            RETURN;
        END

        -- =============================================
        -- ✅ APPROVE FLOW (original logic)
        -- =============================================

        -- Find next approver using LEAD()
        DECLARE @next_current_approver  VARCHAR(30);
        DECLARE @next_condition         VARCHAR(200);
        DECLARE @next_can_forward       CHAR(1);
        DECLARE @next_can_backward      CHAR(1);
        DECLARE @next_is_mandatory      CHAR(1);

        SELECT
            @next_current_approver = next_stage.approver_ecno,
            @next_condition        = next_stage.approver_condition,
            @next_can_forward      = next_stage.can_forward,
            @next_can_backward     = next_stage.can_backward,
            @next_is_mandatory     = next_stage.is_mandatory
        FROM (
            SELECT
                approver_ecno,
                LEAD(approver_ecno, 1, NULL) OVER (ORDER BY seq_no) AS next_approver_ecno
            FROM #approval_stages
        ) current_stage
        LEFT JOIN #approval_stages next_stage
            ON next_stage.approver_ecno = current_stage.next_approver_ecno
        WHERE current_stage.approver_ecno = @approved_by;

        -- Insert approval history
        INSERT INTO pr_history_data (
            pr_basic_sno, pr_edit_data, workflow_types_id,
            approver_ecno, status, status_by,
            status_date, commends, is_active, pr_no
        )
        SELECT
            @pr_basic_sno,
            NULL,
            NULL,
            s.approver_ecno,
            'A',                -- A = Approved
            @approved_by,
            GETDATE(),
            @comments,
            'Y',
            @pr_no
        FROM #approval_stages s
        WHERE s.approver_ecno = @approved_by;

        DECLARE @stages_processed INT = @@ROWCOUNT;

        -- Update current approver (NULL = final stage reached)
        UPDATE pr_basic_info
        SET current_approver_id = @next_current_approver
        WHERE pr_basic_sno = @pr_basic_sno;

        -- If final stage, mark PR as fully Approved
        IF @next_current_approver IS NULL
        BEGIN
            UPDATE pr_basic_info
            SET status = 'A'
            WHERE pr_basic_sno = @pr_basic_sno;
        END

        DROP TABLE #approval_stages;

        -- Return approval result
        SELECT
            'SUCCESS'                                  AS result,
            @pr_no                                     AS pr_no,
            @approved_by                               AS approved_by,
            GETDATE()                                  AS approved_on,
            @stages_processed                          AS stages_processed,
            ISNULL(@next_current_approver, 'FINAL_STAGE') AS next_approver,
            @next_condition                            AS next_condition,
            @next_can_forward                          AS next_can_forward,
            @pr_basic_sno                               AS pr_basic_sno,
            @request_mode                               AS request_mode;

    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL
            DROP TABLE #approval_stages;

        SELECT
            'ERROR'           AS result,
            ERROR_NUMBER()    AS error_number,
            ERROR_MESSAGE()   AS error_message,
            ERROR_LINE()      AS error_line,
            ERROR_PROCEDURE() AS error_procedure;
    END CATCH

END;
GO
