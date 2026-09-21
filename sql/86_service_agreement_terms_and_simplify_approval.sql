-- ============================================================
-- 86_service_agreement_terms_and_simplify_approval.sql
--
-- Two changes requested after browser-testing the live Unfixed flow
-- (AGR-2026-0003, service_sno=2 "SKTM-MTP Housekeeping (Variable)",
-- single-stage workflow_types_id=30/KTM1148):
--
-- 1) "Approve Agreement" was blocked for Unfixed (VARIABLE_RECURRING)
--    agreements — sp_approve_service_agreement's final stage required
--    final_rate_amount/final_qty in the approve payload, RAISERROR'ing
--    otherwise (see sql/73 + sql/82). Product decision: rate/qty are fully
--    entered at agreement CREATION time, not re-entered/"finalized" at
--    approval — that dual-entry step is removed. This is consistent with
--    the sql/83 ServicePO redesign, which already moved *per-cycle* actual
--    rate/GST entry to its own Pending Entry step
--    (sp_nt_SubmitServicePoEntry / ServicePoPage.tsx) — requiring a second
--    "final" rate at the agreement level was redundant with that. Approving
--    an Unfixed agreement's final stage now behaves exactly like Fixed:
--    straight to status='A', using whatever rate_amount/qty was entered at
--    creation. Wrapped in the same BEGIN TRANSACTION/COMMIT sql/82 added,
--    unchanged.
--
-- 2) service_agreement.terms_conditions — new optional free-text field,
--    entered at creation (and editable on resubmit), nothing else depends
--    on it. Plumbed through Create/Update/Get(+ForApproval) the same way
--    `remarks` already is.
--
-- Idempotent throughout — safe to re-run, same convention as every prior
-- file in this chain.
-- ============================================================

-- ── 1) service_agreement.terms_conditions ──────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_agreement') AND name = 'terms_conditions')
    ALTER TABLE dbo.service_agreement ADD terms_conditions NVARCHAR(MAX) NULL;
GO

-- ── 2) sp_nt_CreateServiceAgreement — + optional terms_conditions ──────────
IF OBJECT_ID('dbo.sp_nt_CreateServiceAgreement', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateServiceAgreement;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @com_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @service_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @vendor_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @qty                DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4));
        DECLARE @rate_amount        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @rate_uom_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_uom_sno') AS INT);
        DECLARE @recurrence_cadence_sno INT       = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_cadence_sno') AS INT);
        DECLARE @po_generation_day  SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_generation_day') AS SMALLINT);
        DECLARE @notify_days_before SMALLINT      = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.notify_days_before') AS SMALLINT), 0);
        DECLARE @period_start_date  DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url  NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @terms_conditions   NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.terms_conditions');
        DECLARE @ceiling_amount     DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @created_by         VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @service_sno IS NULL OR @vendor_sno IS NULL OR @created_by IS NULL
            THROW 58101, 'com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno and created_by are required.', 1;

        IF @qty IS NULL OR @qty <= 0
            THROW 58102, 'qty must be a positive quantity.', 1;

        IF @rate_amount IS NULL OR @rate_amount <= 0
            THROW 58103, 'rate_amount must be a positive amount (an approximate value is fine for an Unfixed agreement).', 1;

        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 58104, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;

        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 58105, 'agreement_doc_url is required — upload the agreement document before submitting.', 1;

        IF @recurrence_cadence_sno IS NULL
            THROW 58106, 'recurrence_cadence_sno is required — see sp_nt_GetRecurrenceCadenceRecords for valid options.', 1;

        DECLARE @interval_unit VARCHAR(10);
        SELECT @interval_unit = interval_unit FROM dbo.recurrence_cadence_master WHERE recurrence_cadence_sno = @recurrence_cadence_sno AND is_active = 'Y';
        IF @interval_unit IS NULL
            THROW 58107, 'recurrence_cadence_sno does not reference an active recurrence cadence.', 1;

        IF @interval_unit = 'MONTH'
        BEGIN
            IF @po_generation_day IS NULL OR @po_generation_day NOT BETWEEN 1 AND 31
                THROW 58108, 'po_generation_day (1-31) is required for a month-based recurrence cadence.', 1;
        END
        ELSE
            SET @po_generation_day = NULL;

        DECLARE @service_type_code VARCHAR(30);
        SELECT @service_type_code = st.service_type_code
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';

        IF @service_type_code IS NULL OR @service_type_code NOT IN ('FIXED_RECURRING', 'VARIABLE_RECURRING')
            THROW 58109, 'service_sno must reference an active Fixed or Unfixed service.', 1;

        IF @service_type_code = 'FIXED_RECURRING'
            SET @ceiling_amount = NULL;
        ELSE IF @ceiling_amount IS NOT NULL AND @ceiling_amount <= 0
            THROW 58112, 'ceiling_amount must be a positive amount when provided.', 1;

        -- ── Resolve the ServiceAgreement workflow for this org scope ───────
        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceAgreement';

        IF @workflow_types_id IS NULL
            THROW 58110, 'No ServiceAgreement workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key] = '0' AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 58111, 'No approver found for the first stage of the ServiceAgreement workflow.', 1;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(agreement_no, 4) AS INT)), 0) + 1
        FROM dbo.service_agreement WITH (UPDLOCK, HOLDLOCK)
        WHERE agreement_no LIKE 'AGR-' + @year + '-%';
        DECLARE @agreement_no VARCHAR(30) = 'AGR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.service_agreement (
            agreement_no, com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
            qty, rate_amount, rate_uom_sno, recurrence_cadence_sno, po_generation_day, notify_days_before,
            period_start_date, period_end_date, agreement_doc_url, remarks, terms_conditions, ceiling_amount,
            workflow_types_id, current_approver_id, status, is_active, created_by
        )
        VALUES (
            @agreement_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @service_sno, @vendor_sno,
            @qty, @rate_amount, @rate_uom_sno, @recurrence_cadence_sno, @po_generation_day, @notify_days_before,
            @period_start_date, @period_end_date, @agreement_doc_url, @remarks, @terms_conditions, @ceiling_amount,
            @workflow_types_id, @first_approver, 'P', 'Y', @created_by
        );

        DECLARE @agreement_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment)
        VALUES (@agreement_sno, 'SUBMITTED', @created_by, NULL);

        COMMIT TRANSACTION;

        SELECT @agreement_sno AS agreement_sno, @agreement_no AS agreement_no, 'SUCCESS' AS result,
               N'Service agreement submitted for approval.' AS message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── 3) sp_nt_UpdateServiceAgreement — + optional terms_conditions ──────────
IF OBJECT_ID('dbo.sp_nt_UpdateServiceAgreement', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_UpdateServiceAgreement;
GO
CREATE PROCEDURE dbo.sp_nt_UpdateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @agreement_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
        DECLARE @com_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @service_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @vendor_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @qty                DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4));
        DECLARE @rate_amount        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @rate_uom_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_uom_sno') AS INT);
        DECLARE @recurrence_cadence_sno INT       = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_cadence_sno') AS INT);
        DECLARE @po_generation_day  SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_generation_day') AS SMALLINT);
        DECLARE @notify_days_before SMALLINT      = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.notify_days_before') AS SMALLINT), 0);
        DECLARE @period_start_date  DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url  NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @terms_conditions   NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.terms_conditions');
        DECLARE @ceiling_amount     DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @edited_by          VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.edited_by');

        IF @agreement_sno IS NULL OR @edited_by IS NULL
            THROW 58120, 'agreement_sno and edited_by are required.', 1;

        DECLARE @current_status CHAR(1);
        SELECT @current_status = status FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno AND is_active = 'Y';
        IF @current_status IS NULL
            THROW 58121, 'Service agreement not found or inactive.', 1;
        IF @current_status NOT IN ('A', 'R')
            THROW 58122, 'Only an Approved or Rejected agreement can be edited (it is currently Pending approval).', 1;

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @service_sno IS NULL OR @vendor_sno IS NULL
            THROW 58123, 'com_sno, div_sno, brn_sno, dept_sno, service_sno and vendor_sno are required.', 1;
        IF @qty IS NULL OR @qty <= 0
            THROW 58124, 'qty must be a positive quantity.', 1;
        IF @rate_amount IS NULL OR @rate_amount <= 0
            THROW 58125, 'rate_amount must be a positive amount.', 1;
        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 58126, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;
        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 58127, 'agreement_doc_url is required.', 1;

        DECLARE @interval_unit VARCHAR(10);
        SELECT @interval_unit = interval_unit FROM dbo.recurrence_cadence_master WHERE recurrence_cadence_sno = @recurrence_cadence_sno AND is_active = 'Y';
        IF @interval_unit IS NULL
            THROW 58128, 'recurrence_cadence_sno does not reference an active recurrence cadence.', 1;
        IF @interval_unit = 'MONTH'
        BEGIN
            IF @po_generation_day IS NULL OR @po_generation_day NOT BETWEEN 1 AND 31
                THROW 58129, 'po_generation_day (1-31) is required for a month-based recurrence cadence.', 1;
        END
        ELSE
            SET @po_generation_day = NULL;

        DECLARE @service_type_code VARCHAR(30);
        SELECT @service_type_code = st.service_type_code
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno;
        IF @service_type_code = 'FIXED_RECURRING'
            SET @ceiling_amount = NULL;
        ELSE IF @ceiling_amount IS NOT NULL AND @ceiling_amount <= 0
            THROW 58132, 'ceiling_amount must be a positive amount when provided.', 1;

        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceAgreement';
        IF @workflow_types_id IS NULL
            THROW 58130, 'No ServiceAgreement workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id AND s.[key] = '0' AND s2.[key] = '0';
        IF @first_approver IS NULL
            THROW 58131, 'No approver found for the first stage of the ServiceAgreement workflow.', 1;

        UPDATE dbo.service_agreement
        SET com_sno = @com_sno, div_sno = @div_sno, brn_sno = @brn_sno, dept_sno = @dept_sno,
            service_sno = @service_sno, vendor_sno = @vendor_sno, qty = @qty, rate_amount = @rate_amount,
            rate_uom_sno = @rate_uom_sno, recurrence_cadence_sno = @recurrence_cadence_sno,
            po_generation_day = @po_generation_day, notify_days_before = @notify_days_before,
            period_start_date = @period_start_date, period_end_date = @period_end_date,
            agreement_doc_url = @agreement_doc_url, remarks = @remarks, terms_conditions = @terms_conditions,
            ceiling_amount = @ceiling_amount,
            workflow_types_id = @workflow_types_id, current_approver_id = @first_approver,
            status = 'P', modified_by = @edited_by, modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment)
        VALUES (@agreement_sno, 'RESUBMITTED', @edited_by, NULL);

        COMMIT TRANSACTION;

        SELECT @agreement_sno AS agreement_sno, 'SUCCESS' AS result, N'Service agreement updated and resubmitted for approval.' AS message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── 4) sp_nt_GetServiceAgreements — + terms_conditions ─────────────────────
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
           sa.period_start_date, sa.period_end_date, sa.agreement_doc_url, sa.remarks, sa.terms_conditions,
           sa.current_approver_id, sa.status, sa.created_by, sa.created_at
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

-- ── 5) sp_nt_GetServiceAgreementsForApproval — + terms_conditions ──────────
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
           sa.period_start_date, sa.period_end_date, sa.agreement_doc_url, sa.remarks, sa.terms_conditions,
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

-- ── 6) sp_approve_service_agreement — drop the final_rate_amount/final_qty
--      requirement entirely. Unfixed now approves through its final stage
--      exactly like Fixed: straight to status='A' with whatever rate_amount
--      /qty was set at creation. Everything else (transaction wrap from
--      sql/82, the auto first-cycle issue) is unchanged.
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
                @action           VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');

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
            -- ── Final stage: Fixed and Unfixed both go straight to Approved
            --    now — rate/qty stay whatever was entered at creation, no
            --    re-entry/finalization step here any more. ──────────────
            DECLARE @period_start DATE;
            SELECT @period_start = sa.period_start_date FROM dbo.service_agreement sa WHERE sa.agreement_sno = @agreement_sno;

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
