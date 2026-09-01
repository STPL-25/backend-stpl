-- ============================================================
-- Service recurring flow redesign — cadence master, auto-PO on agreement
-- approval (Fixed Recurring), and per-cycle invoice-first approval
-- (Variable Recurring)
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/ServiceAgreement (existing), a new
--            ServiceBillRequest module (not yet built — SQL only this pass)
--
-- Why this is needed
-- ------------------
-- User-requested change to the flow in service-agreement-approval-po-spec.md:
-- once a Service Agreement is approved, the PO should be raised automatically
-- (not left for a person to trigger sp_nt_CreateServicePO by hand), and the
-- billing recurrence (every 15 days / monthly / quarterly / annual) should be
-- driven by data, not hardcoded proc logic. Decided via clarifying questions:
--   1. Keep the PR step, but auto-approve it — a system-generated PR from an
--      already-approved agreement doesn't need a second human gate.
--   2. Recurrence cadence becomes a proper master table (recurrence_cadence_master)
--      instead of a hardcoded CASE list, so new cadences are addable later
--      without a code change.
--   3. Auto-raise a NEW PO at every cadence boundary for the agreement's life
--      (not one Standing PO reused forever).
--   4. Variable Recurring keeps its existing ceiling-authorization Service
--      Agreement (service_agreement, VARIABLE_RECURRING branch) as-is; this
--      file ADDS a new per-cycle step on top — service_bill_request — where
--      the actual invoice value + details are submitted and approved BEFORE
--      that cycle's PO is raised, still capped by the agreement's ceiling.
--
-- End-to-end result:
--   FIXED_RECURRING:    Agreement approved -> PR auto-created+auto-approved ->
--                        PO auto-issued (direct, no separate PO approval) ->
--                        [existing] user uploads invoice -> [existing]
--                        Service Entry (Service GRN) -> [existing] Payment.
--                        Repeats every recurrence_cadence_master boundary
--                        until period_end_date.
--   VARIABLE_RECURRING:  Ceiling Agreement approved (unchanged) -> each cycle:
--                        user submits actual invoice value+doc
--                        (service_bill_request) -> approved -> PO auto-issued
--                        (direct, matching the invoice) -> [existing] Service
--                        Entry (Service GRN) -> [existing] Payment. No PR —
--                        Variable Recurring never had a PR-autofill step.
--
-- Design notes carried through the procs below:
--   - "Direct issue" (status='A', workflow_types_id=NULL) for every
--     auto-raised PO in this file mirrors the existing call-off-PO precedent
--     (sp_nt_CreateCallOffPO) and the "no workflow configured" branch already
--     in sp_nt_CreateServicePO — an already-authorized spend doesn't need a
--     second procurement approval.
--   - sp_nt_DirectIssueServicePO is a new shared helper (generic: takes org +
--     vendor + service + amount, no workflow resolution) used by BOTH the
--     Fixed-Recurring cycle issuer and the Variable bill-request approver, so
--     the PO-insert shape only exists in one place.
--   - Every helper that can be nested inside another proc's transaction takes
--     a @silent BIT + OUTPUT params: when @silent=1 it skips its own SELECT
--     and only sets OUTPUT params, so a caller like sp_approve_service_agreement
--     gets exactly one result set back (its own), not an extra recordset from
--     the nested EXEC ahead of it that would silently become recordset[0] for
--     any Node caller still doing result.recordset[0].
--   - sp_nt_GetAgreementsDueForRecurringPR (13_recurring_pr_job.sql) and the
--     Node RecurringPrJob.js that polls it are now SUPERSEDED by
--     sp_nt_ProcessDueRecurringServiceAgreements below, which does the whole
--     PR+PO cycle server-side instead of leaving PR-creation to the Node job.
--     Deliberately NOT dropped here — Node still calls the old proc hourly
--     until it's updated to call the new one instead; dropping it now would
--     break that live job before the Node-side change ships. Retire both
--     together in a follow-up.
--   - A PO-issuance failure that happens AFTER an approval already committed
--     (agreement final-approve, or bill-request final-approve) does not fail
--     the approval itself — the approval stands, the failure is recorded
--     (service_agreement_recurring_pr_log for Fixed; service_bill_request
--     stays with po_basic_sno NULL for Variable, retryable via
--     sp_nt_RetryServiceBillRequestPOIssue below). An approval silently
--     succeeding but leaving no PO would be a worse failure mode than a
--     visible, retryable gap.
-- ============================================================

-- ── recurrence_cadence_master ───────────────────────────────────────────────

IF OBJECT_ID('dbo.recurrence_cadence_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.recurrence_cadence_master (
        recurrence_cadence_sno INT IDENTITY(1,1) PRIMARY KEY,
        cadence_code           VARCHAR(30)   NOT NULL,
        cadence_name           NVARCHAR(100) NOT NULL,
        -- the recurring-PO engine reads these two directly — no cadence math
        -- is hardcoded in a proc any more, it's all derived from this row
        interval_unit           VARCHAR(10)  NOT NULL, -- DAY | MONTH
        interval_value            INT        NOT NULL, -- e.g. 15 for DAY, 1/3/12 for MONTH
        description                NVARCHAR(200) NULL,
        is_active                   CHAR(1)   NOT NULL DEFAULT 'Y',
        created_by                   VARCHAR(20) NULL,
        created_at                    DATETIME  NOT NULL DEFAULT GETDATE(),
        modified_by                    VARCHAR(20) NULL,
        modified_at                     DATETIME NULL,
        CONSTRAINT UQ_recurrence_cadence_master_code UNIQUE (cadence_code),
        CONSTRAINT CK_recurrence_cadence_master_unit CHECK (interval_unit IN ('DAY','MONTH')),
        CONSTRAINT CK_recurrence_cadence_master_value CHECK (interval_value > 0)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.recurrence_cadence_master)
BEGIN
    INSERT INTO dbo.recurrence_cadence_master (cadence_code, cadence_name, interval_unit, interval_value, description, is_active, created_by)
    VALUES
        (N'FIFTEEN_DAYS', N'Every 15 Days', 'DAY',   15, N'Bills every 15 days from the agreement period start date', 'Y', N'system'),
        (N'MONTHLY',      N'Monthly',       'MONTH',  1, N'Bills every month, on the anniversary of the period start date', 'Y', N'system'),
        (N'QUARTERLY',    N'Quarterly',     'MONTH',  3, N'Bills every 3 months, on the anniversary of the period start date', 'Y', N'system'),
        (N'ANNUAL',       N'Annual',        'MONTH', 12, N'Bills once a year, on the anniversary of the period start date', 'Y', N'system');
END;
GO

-- ============================================================
-- sp_nt_GetRecurrenceCadenceRecords — Get+Create only, same pattern as
-- BankAccountTypeMaster/ServiceTypeMaster (no Update/Delete).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetRecurrenceCadenceRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetRecurrenceCadenceRecords;
GO
CREATE PROCEDURE dbo.sp_nt_GetRecurrenceCadenceRecords
AS
BEGIN
    SET NOCOUNT ON;

    SELECT recurrence_cadence_sno, cadence_code, cadence_name, interval_unit, interval_value, description, is_active
    FROM dbo.recurrence_cadence_master
    WHERE is_active = 'Y'
    ORDER BY recurrence_cadence_sno;
END;
GO

-- ============================================================
-- sp_nt_CreateRecurrenceCadenceRecords
-- @jsonInput: { cadence_code, cadence_name, interval_unit, interval_value,
--   description?, created_by }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateRecurrenceCadenceRecords', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateRecurrenceCadenceRecords;
GO
CREATE PROCEDURE dbo.sp_nt_CreateRecurrenceCadenceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
        THROW 54001, N'Invalid JSON payload provided.', 1;

    DECLARE @cadence_code    VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.cadence_code'),
            @cadence_name    NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.cadence_name'),
            @interval_unit   VARCHAR(10)   = UPPER(JSON_VALUE(@jsonInput, '$.interval_unit')),
            @interval_value  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.interval_value') AS INT),
            @description     NVARCHAR(200) = JSON_VALUE(@jsonInput, '$.description'),
            @created_by      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @cadence_code IS NULL OR @cadence_name IS NULL OR @interval_unit IS NULL OR @interval_value IS NULL
        THROW 54002, N'cadence_code, cadence_name, interval_unit and interval_value are required.', 1;

    IF @interval_unit NOT IN ('DAY','MONTH')
        THROW 54003, N'interval_unit must be DAY or MONTH.', 1;

    IF @interval_value <= 0
        THROW 54004, N'interval_value must be positive.', 1;

    IF EXISTS (SELECT 1 FROM dbo.recurrence_cadence_master WHERE cadence_code = @cadence_code)
        THROW 54005, N'A recurrence cadence with this code already exists.', 1;

    INSERT INTO dbo.recurrence_cadence_master (cadence_code, cadence_name, interval_unit, interval_value, description, is_active, created_by)
    VALUES (@cadence_code, @cadence_name, @interval_unit, @interval_value, @description, 'Y', @created_by);

    SELECT SCOPE_IDENTITY() AS recurrence_cadence_sno, @cadence_code AS cadence_code, N'SUCCESS' AS status;
END;
GO

-- ── service_agreement: wire recurrence_cadence to the new master ───────────
-- The existing recurrence_cadence VARCHAR(20) column is kept (still holds the
-- resolved cadence_code, for anything already reading it as text — including
-- the soon-to-be-superseded sp_nt_GetAgreementsDueForRecurringPR) but is no
-- longer the source of truth: recurrence_cadence_sno is, and it's now
-- mandatory (see sp_nt_CreateServiceAgreement v4 below) rather than silently
-- defaulted from service_master.

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_agreement') AND name = 'recurrence_cadence_sno')
    ALTER TABLE dbo.service_agreement ADD recurrence_cadence_sno INT NULL
        CONSTRAINT FK_service_agreement_recurrence_cadence FOREIGN KEY REFERENCES dbo.recurrence_cadence_master (recurrence_cadence_sno);
GO

-- ============================================================
-- sp_nt_CreateServiceAgreement v4 — recurrence_cadence now resolved against
-- recurrence_cadence_master instead of defaulted from service_master.
-- @jsonInput: same shape as v3 (21_service_agreement_variable_recurring.sql)
-- PLUS recurrence_cadence_sno (INT, preferred) and/or recurrence_cadence
-- (VARCHAR cadence_code, accepted for a not-yet-updated client) — one of the
-- two must resolve to an active recurrence_cadence_master row.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateServiceAgreement', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateServiceAgreement;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

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
        DECLARE @period_start_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date      DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url    NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks              NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @created_by           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @service_sno IS NULL OR @created_by IS NULL
            THROW 53001, 'com_sno, div_sno, brn_sno, dept_sno, service_sno and created_by are required.', 1;

        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 53003, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;

        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 53004, 'agreement_doc_url is required — upload the agreement document before submitting.', 1;

        -- ── Resolve recurrence cadence against the master (mandatory) ──────
        IF @recurrence_cadence_sno IS NULL AND @recurrence_cadence IS NOT NULL
            SELECT @recurrence_cadence_sno = recurrence_cadence_sno
            FROM dbo.recurrence_cadence_master
            WHERE cadence_code = @recurrence_cadence AND is_active = 'Y';

        IF @recurrence_cadence_sno IS NULL
            THROW 53020, 'recurrence_cadence_sno (or a matching recurrence_cadence code) is required — see sp_nt_GetRecurrenceCadenceRecords for valid options.', 1;

        SELECT @recurrence_cadence = cadence_code
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

        -- Branch by billing pattern: Fixed Recurring authorizes a rate,
        -- Variable Recurring authorizes a ceiling + tolerance.
        IF @service_type_code = 'FIXED_RECURRING'
        BEGIN
            IF @rate_amount IS NULL OR @rate_amount <= 0
                THROW 53002, 'rate_amount must be a positive amount.', 1;
        END
        ELSE -- VARIABLE_RECURRING
        BEGIN
            IF @ceiling_amount IS NULL OR @ceiling_amount <= 0
                THROW 53010, 'ceiling_amount must be a positive amount for a Variable Recurring agreement.', 1;
            IF @variance_tolerance_pct IS NULL
                THROW 53011, 'variance_tolerance_pct is required for a Variable Recurring agreement.', 1;
        END

        -- ── Resolve the ServiceAgreement workflow for this org scope ───────
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

        -- ── Number: AGR-YYYY-NNNN, same scheme as ServicePO's SVO-YYYY-NNNN ─
        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(agreement_no, 4) AS INT)), 0) + 1
        FROM dbo.service_agreement WITH (UPDLOCK, HOLDLOCK)
        WHERE agreement_no LIKE 'AGR-' + @year + '-%';
        DECLARE @agreement_no VARCHAR(30) = 'AGR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.service_agreement (
            agreement_no, com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
            rate_amount, rate_uom_sno, ceiling_amount, variance_tolerance_pct,
            recurrence_cadence, recurrence_cadence_sno, period_start_date, period_end_date,
            agreement_doc_url, remarks, workflow_types_id, current_approver_id, status,
            is_active, created_by
        )
        VALUES (
            @agreement_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @service_sno, @vendor_sno,
            @rate_amount, @rate_uom_sno, @ceiling_amount, @variance_tolerance_pct,
            @recurrence_cadence, @recurrence_cadence_sno, @period_start_date, @period_end_date,
            @agreement_doc_url, @remarks, @workflow_types_id, @first_approver, 'P',
            'Y', @created_by
        );

        DECLARE @agreement_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, is_active)
        VALUES (@agreement_sno, 'SUBMITTED', @created_by, NULL, 'Y');

        COMMIT TRANSACTION;

        SELECT
            @agreement_sno AS agreement_sno,
            @agreement_no  AS agreement_no,
            'SUCCESS'      AS result,
            N'Service agreement submitted for approval.' AS message;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── service_agreement_recurring_pr_log: extend with PO linkage ─────────────

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_agreement_recurring_pr_log') AND name = 'po_basic_sno')
    ALTER TABLE dbo.service_agreement_recurring_pr_log ADD po_basic_sno INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_agreement_recurring_pr_log') AND name = 'po_no')
    ALTER TABLE dbo.service_agreement_recurring_pr_log ADD po_no VARCHAR(50) NULL;
GO

-- ============================================================
-- sp_nt_DirectIssueServicePO — generic direct-issue Service PO creator
-- (status='A' immediately, no workflow/approval). Shared by the
-- Fixed-Recurring cycle issuer and the Variable bill-request approver below.
-- @jsonInput: { com_sno, div_sno, brn_sno, dept_sno, vendor_sno,
--   pr_basic_sno? (required unless is_retrospective), is_retrospective?,
--   pr_item_sno?, service_sno, qty?, uom_sno?, unit_price, po_type?,
--   validity_from?, validity_to?, ceiling_amount?, variance_tolerance_pct?,
--   purpose?, source_note?, issued_by }
-- @silent: 1 = only set OUTPUT params, no SELECT (for nested calls).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_DirectIssueServicePO', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_DirectIssueServicePO;
GO
CREATE PROCEDURE dbo.sp_nt_DirectIssueServicePO
    @jsonInput NVARCHAR(MAX),
    @silent BIT = 0,
    @out_result VARCHAR(30) = NULL OUTPUT,
    @out_po_basic_sno INT = NULL OUTPUT,
    @out_po_no VARCHAR(50) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @com_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno          INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @vendor_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @pr_basic_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT);
        DECLARE @pr_item_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_item_sno') AS INT);
        DECLARE @is_retrospective  BIT           = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.is_retrospective') AS BIT), 0);
        DECLARE @service_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @qty               DECIMAL(18,4) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4)), 1);
        DECLARE @uom_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.uom_sno') AS INT);
        DECLARE @unit_price        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.unit_price') AS DECIMAL(18,2));
        DECLARE @po_type           VARCHAR(20)   = ISNULL(JSON_VALUE(@jsonInput, '$.po_type'), 'RECURRING');
        DECLARE @validity_from     DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.validity_from') AS DATE);
        DECLARE @validity_to       DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.validity_to') AS DATE);
        DECLARE @ceiling_amount    DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @variance_tolerance_pct DECIMAL(5,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.variance_tolerance_pct') AS DECIMAL(5,2));
        DECLARE @purpose           VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.purpose');
        DECLARE @source_note       NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.source_note');
        DECLARE @issued_by         VARCHAR(20)   = ISNULL(JSON_VALUE(@jsonInput, '$.issued_by'), 'SYSTEM');

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @vendor_sno IS NULL OR @service_sno IS NULL OR @unit_price IS NULL
            THROW 57001, 'com_sno, div_sno, brn_sno, dept_sno, vendor_sno, service_sno and unit_price are required.', 1;

        IF @pr_basic_sno IS NULL AND @is_retrospective = 0
            THROW 57002, 'pr_basic_sno is required unless is_retrospective is set.', 1;

        DECLARE @service_type_sno INT;
        SELECT @service_type_sno = service_type_sno FROM dbo.service_master WHERE service_sno = @service_sno AND is_active = 'Y';

        IF @service_type_sno IS NULL
            THROW 57003, 'Unknown or inactive service_sno.', 1;

        DECLARE @net_cost DECIMAL(18,4) = @qty * @unit_price;

        BEGIN TRANSACTION;

        DECLARE @po_year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @po_seq  INT;
        SELECT @po_seq = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
        FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
        WHERE po_df_no LIKE 'SVO-' + @po_year + '-%';
        DECLARE @po_no VARCHAR(50) = 'SVO-' + @po_year + '-' + RIGHT('0000' + CAST(@po_seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.po_request_info (
            vendor_sno, brn_sno, dept_sno, com_sno, div_sno, budget_sno, budget_code, pr_basic_sno,
            po_date, required_date, purpose, terms_conditions, delivery_address,
            is_active, workflow_types_id, current_approver_id, status, po_df_no,
            po_type, validity_from, validity_to, ceiling_amount, variance_tolerance_pct,
            consumed_amount, service_type_sno, is_retrospective, parent_blanket_po_sno
        )
        VALUES (
            @vendor_sno, @brn_sno, @dept_sno, @com_sno, @div_sno, NULL, NULL, @pr_basic_sno,
            CAST(GETDATE() AS DATE), ISNULL(@validity_to, CAST(GETDATE() AS DATE)), @purpose, NULL, NULL,
            'Y', NULL, NULL, 'A', @po_no,
            @po_type, @validity_from, @validity_to, @ceiling_amount, @variance_tolerance_pct,
            0, @service_type_sno, @is_retrospective, NULL
        );
        DECLARE @po_basic_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.po_item_details (
            po_basic_sno, pr_item_sno, service_sno, prod_name, specification,
            qty, unit, unit_name, agreed_unit_price, total_cost, discount_pct, tax_pct, net_cost,
            remarks, po_section, created_by, created_date, is_active
        )
        SELECT
            @po_basic_sno, @pr_item_sno, @service_sno, sm.service_name, '',
            @qty, @uom_sno, um.uom_name, @unit_price, @net_cost, 0, 0, @net_cost,
            @source_note, 'SERVICE', @issued_by, GETDATE(), '1'
        FROM dbo.service_master sm
        LEFT JOIN dbo.uom_master um ON um.uom_sno = @uom_sno
        WHERE sm.service_sno = @service_sno;

        INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
        VALUES (@po_basic_sno, 'AUTO_ISSUED', @issued_by, ISNULL(@source_note, N'Direct-issued, no separate PO approval required.'), 'Y');

        COMMIT TRANSACTION;

        SET @out_result = 'SUCCESS';
        SET @out_po_basic_sno = @po_basic_sno;
        SET @out_po_no = @po_no;

        IF @silent = 0
            SELECT 'SUCCESS' AS result, @po_basic_sno AS po_basic_sno, @po_no AS po_no;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @out_result = 'ERROR';
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- sp_nt_IssueRecurringServicePOCycle — one Fixed-Recurring billing cycle:
-- auto-creates+auto-approves a PR line from the agreement, then calls
-- sp_nt_DirectIssueServicePO to raise the PO from it. Idempotent per
-- (agreement_sno, billing_period_start) via service_agreement_recurring_pr_log.
-- Called both from sp_approve_service_agreement (the first cycle, immediately
-- on final approval) and from sp_nt_ProcessDueRecurringServiceAgreements (the
-- sweep, for every later cadence boundary).
-- @jsonInput: { agreement_sno, billing_period_start, issued_by? }
-- @silent: 1 = only set OUTPUT params, no SELECT (for nested calls).
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

        -- Auto-approved PR: status='A', no workflow — the human decision
        -- already happened at agreement-approval time (see file header).
        INSERT INTO dbo.pr_basic_info (
            pr_no, com_sno, div_sno, brn_sno, dept_sno, reg_date, required_date, priority_sno, purpose,
            is_active, created_by, created_date, workflow_types_id, current_approver_id, status
        )
        VALUES (
            @pr_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @billing_period_start, @billing_period_start, NULL,
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
-- sp_nt_ProcessDueRecurringServiceAgreements — the scheduler entry point.
-- No @jsonInput; call on every sweep (e.g. hourly, same cadence the old
-- RecurringPrJob.js used). Cadence-boundary math is now driven entirely by
-- recurrence_cadence_master (interval_unit/interval_value) instead of a
-- hardcoded CASE list. Supersedes sp_nt_GetAgreementsDueForRecurringPR — see
-- file header for why that old proc is left in place, not dropped, for now.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ProcessDueRecurringServiceAgreements', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_ProcessDueRecurringServiceAgreements;
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
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    WHERE sa.status = 'A' AND sa.is_active = 'Y' AND st.service_type_code = 'FIXED_RECURRING'
      AND @today BETWEEN sa.period_start_date AND sa.period_end_date
      AND (
            (rc.interval_unit = 'DAY'   AND DATEDIFF(DAY, sa.period_start_date, @today) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, @today) / rc.interval_value) * rc.interval_value, sa.period_start_date) = @today)
          )
      AND NOT EXISTS (
          SELECT 1 FROM dbo.service_agreement_recurring_pr_log l
          WHERE l.agreement_sno = sa.agreement_sno AND l.billing_period_start = @today
      );

    DECLARE @agreement_sno INT, @billing_period_start DATE;
    DECLARE @success_count INT = 0, @skipped_count INT = 0, @failed_count INT = 0;
    DECLARE @row_result VARCHAR(30), @row_po INT, @row_po_no VARCHAR(50), @row_pr INT, @row_pr_no VARCHAR(20), @rowJson NVARCHAR(MAX);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT agreement_sno, billing_period_start FROM @due;
    OPEN cur;
    FETCH NEXT FROM cur INTO @agreement_sno, @billing_period_start;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @rowJson = (
            SELECT @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start, 'SYSTEM' AS issued_by
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC dbo.sp_nt_IssueRecurringServicePOCycle
            @jsonInput = @rowJson, @silent = 1,
            @out_result = @row_result OUTPUT, @out_po_basic_sno = @row_po OUTPUT, @out_po_no = @row_po_no OUTPUT,
            @out_pr_basic_sno = @row_pr OUTPUT, @out_pr_no = @row_pr_no OUTPUT;

        IF @row_result = 'SUCCESS'
            SET @success_count = @success_count + 1;
        ELSE IF @row_result LIKE 'SKIPPED%'
            SET @skipped_count = @skipped_count + 1;
        ELSE
            SET @failed_count = @failed_count + 1;

        FETCH NEXT FROM cur INTO @agreement_sno, @billing_period_start;
    END
    CLOSE cur;
    DEALLOCATE cur;

    SELECT
        (SELECT COUNT(*) FROM @due) AS due_count,
        @success_count AS success_count,
        @skipped_count AS skipped_count,
        @failed_count  AS failed_count;
END;
GO

-- ============================================================
-- sp_approve_service_agreement v2 — same single-stage progression as before,
-- PLUS: on the final approval of a FIXED_RECURRING agreement, immediately
-- issues the first billing cycle's PR+PO (sp_nt_IssueRecurringServicePOCycle)
-- rather than waiting for the next scheduler sweep. billing_period_start is
-- today if the agreement's own period_start_date has already passed (the
-- normal case — approval usually lands after submission), else
-- period_start_date itself. A failure here does NOT fail the approval — see
-- file header. VARIABLE_RECURRING agreements are unaffected: approving the
-- ceiling authorization never raises a PO by itself (see service_bill_request
-- below for that).
-- @jsonInput: { agreement_sno, approved_by, comments, approval_stages, action }
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
            -- issue the first billing cycle rather than waiting on the sweep.
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
                    -- service_agreement_recurring_pr_log already has a
                    -- FAILED row (written by the helper's own CATCH) for
                    -- ops to find and retry via a fresh sweep call.
                    SET @auto_po_result = 'ERROR: ' + ERROR_MESSAGE();
                END CATCH
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

-- ── service_bill_request — Variable Recurring's per-cycle invoice-first ────
-- approval. Sits ON TOP of the existing ceiling service_agreement (unchanged);
-- each cycle's actual bill amount + invoice document is submitted here and
-- approved BEFORE that cycle's PO is raised. See file header for why.

IF OBJECT_ID('dbo.service_bill_request', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_bill_request (
        bill_request_sno     INT IDENTITY(1,1) PRIMARY KEY,
        request_no            VARCHAR(30)    NOT NULL,
        agreement_sno           INT          NOT NULL,
        com_sno                  INT         NOT NULL,
        div_sno                  INT         NOT NULL,
        brn_sno                  INT         NOT NULL,
        dept_sno                 INT         NOT NULL,
        service_sno               INT        NOT NULL,
        vendor_sno                 INT       NULL,
        billing_period_start         DATE    NOT NULL,
        billing_period_end            DATE   NOT NULL,
        invoice_no                     VARCHAR(50)  NULL,
        invoice_date                    DATE        NULL,
        invoice_amount                   DECIMAL(18,2) NOT NULL,
        invoice_doc_url                   NVARCHAR(500) NOT NULL,
        remarks                            NVARCHAR(500) NULL,
        workflow_types_id                  INT NULL,
        current_approver_id                 VARCHAR(30) NULL,
        -- P=Pending, A=Approved, R=Rejected
        status                               CHAR(1) NOT NULL,
        po_basic_sno                          INT NULL,
        is_active                              CHAR(1) NOT NULL DEFAULT 'Y',
        created_by                              VARCHAR(20) NULL,
        created_at                               DATETIME NOT NULL DEFAULT GETDATE(),
        modified_by                               VARCHAR(20) NULL,
        modified_at                                DATETIME NULL,
        CONSTRAINT UQ_service_bill_request_no UNIQUE (request_no),
        CONSTRAINT CK_service_bill_request_status CHECK (status IN ('P','A','R')),
        CONSTRAINT CK_service_bill_request_period CHECK (billing_period_end >= billing_period_start),
        CONSTRAINT CK_service_bill_request_amount CHECK (invoice_amount > 0),
        CONSTRAINT FK_service_bill_request_agreement FOREIGN KEY (agreement_sno) REFERENCES dbo.service_agreement (agreement_sno),
        CONSTRAINT FK_service_bill_request_po FOREIGN KEY (po_basic_sno) REFERENCES dbo.po_request_info (po_basic_sno)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_service_bill_request_agreement' AND object_id = OBJECT_ID('dbo.service_bill_request'))
    CREATE INDEX IX_service_bill_request_agreement ON dbo.service_bill_request (agreement_sno, status);
GO

IF OBJECT_ID('dbo.service_bill_request_history', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_bill_request_history (
        history_sno       INT IDENTITY(1,1) PRIMARY KEY,
        bill_request_sno  INT           NOT NULL,
        action_type       VARCHAR(20)   NOT NULL, -- SUBMITTED | APPROVED | REJECTED
        status_by         VARCHAR(30)   NULL,
        comment           VARCHAR(200)  NULL,
        is_active         CHAR(1)       NOT NULL DEFAULT 'Y',
        created_date      DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_service_bill_request_history_request FOREIGN KEY (bill_request_sno)
            REFERENCES dbo.service_bill_request (bill_request_sno)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.entity_master WHERE entity_code = 'ServiceBillRequest')
    INSERT INTO dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by)
    VALUES (N'Service Bill Request', N'ServiceBillRequest', N'Variable Recurring per-cycle actual invoice value + document approval, ahead of PO issuance', 'Y', N'system');
GO

-- ============================================================
-- sp_nt_GetActiveCeilingAgreementsForBilling — Approved, in-period
-- VARIABLE_RECURRING agreements for an org scope, feeding the bill-request
-- entry screen's agreement picker.
-- @jsonInput: { com_sno, div_sno, brn_sno, dept_sno, service_sno? }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetActiveCeilingAgreementsForBilling', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetActiveCeilingAgreementsForBilling;
GO
CREATE PROCEDURE dbo.sp_nt_GetActiveCeilingAgreementsForBilling
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno     INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
    DECLARE @div_sno     INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
    DECLARE @brn_sno     INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
    DECLARE @dept_sno    INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
    DECLARE @service_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);

    IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
        THROW 56001, 'com_sno, div_sno, brn_sno and dept_sno are required.', 1;

    SELECT
        sa.agreement_sno, sa.agreement_no, sa.service_sno, sm.service_name,
        sa.vendor_sno, k.company_name AS vendor_name,
        sa.ceiling_amount, sa.variance_tolerance_pct,
        sa.recurrence_cadence, sa.recurrence_cadence_sno, rc.cadence_name,
        sa.period_start_date, sa.period_end_date
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    WHERE sa.com_sno = @com_sno AND sa.div_sno = @div_sno
      AND sa.brn_sno = @brn_sno AND sa.dept_sno = @dept_sno
      AND sa.status = 'A' AND sa.is_active = 'Y'
      AND CAST(GETDATE() AS DATE) BETWEEN sa.period_start_date AND sa.period_end_date
      AND (@service_sno IS NULL OR sa.service_sno = @service_sno)
    ORDER BY sa.agreement_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_CreateServiceBillRequest
-- @jsonInput: { agreement_sno, billing_period_start, billing_period_end,
--   invoice_no?, invoice_date?, invoice_amount, invoice_doc_url, remarks?,
--   created_by }
-- invoice_amount is capped at the agreement's ceiling_amount inflated by its
-- variance_tolerance_pct — the same headroom sp_nt_CreateServicePO already
-- allows a Variable Recurring PO's ceiling to carry.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateServiceBillRequest', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateServiceBillRequest;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceBillRequest
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @agreement_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
        DECLARE @billing_period_start DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.billing_period_start') AS DATE);
        DECLARE @billing_period_end   DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.billing_period_end') AS DATE);
        DECLARE @invoice_no           VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.invoice_no');
        DECLARE @invoice_date         DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_date') AS DATE);
        DECLARE @invoice_amount       DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_amount') AS DECIMAL(18,2));
        DECLARE @invoice_doc_url      NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.invoice_doc_url');
        DECLARE @remarks              NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @created_by           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

        IF @agreement_sno IS NULL OR @created_by IS NULL
            THROW 56010, 'agreement_sno and created_by are required.', 1;

        IF @billing_period_start IS NULL OR @billing_period_end IS NULL OR @billing_period_end < @billing_period_start
            THROW 56011, 'billing_period_start and billing_period_end are required, and the period must not end before it starts.', 1;

        IF @invoice_amount IS NULL OR @invoice_amount <= 0
            THROW 56012, 'invoice_amount must be a positive amount.', 1;

        IF @invoice_doc_url IS NULL OR LTRIM(RTRIM(@invoice_doc_url)) = ''
            THROW 56013, 'invoice_doc_url is required — upload the invoice document before submitting.', 1;

        DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @service_sno INT, @vendor_sno INT,
                @ceiling_amount DECIMAL(18,2), @variance_tolerance_pct DECIMAL(5,2), @agr_status CHAR(1),
                @period_end DATE, @service_type_code VARCHAR(30);

        SELECT @com_sno = sa.com_sno, @div_sno = sa.div_sno, @brn_sno = sa.brn_sno, @dept_sno = sa.dept_sno,
               @service_sno = sa.service_sno, @vendor_sno = sa.vendor_sno,
               @ceiling_amount = sa.ceiling_amount, @variance_tolerance_pct = sa.variance_tolerance_pct,
               @agr_status = sa.status, @period_end = sa.period_end_date, @service_type_code = st.service_type_code
        FROM dbo.service_agreement sa
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sa.agreement_sno = @agreement_sno;

        IF @agr_status IS NULL
            THROW 56014, 'Unknown agreement_sno.', 1;
        IF @service_type_code <> 'VARIABLE_RECURRING'
            THROW 56015, 'agreement_sno must reference a Variable Recurring ceiling agreement.', 1;
        IF @agr_status <> 'A'
            THROW 56016, 'The ceiling Service Agreement must be Approved before a bill can be submitted against it.', 1;
        IF CAST(GETDATE() AS DATE) > @period_end
            THROW 56017, 'The ceiling Service Agreement has expired.', 1;

        IF @ceiling_amount IS NOT NULL AND @invoice_amount > @ceiling_amount * (1 + ISNULL(@variance_tolerance_pct, 0) / 100.0)
            THROW 56018, 'invoice_amount exceeds the ceiling agreement''s authorized ceiling plus its variance tolerance.', 1;

        -- ── Resolve the ServiceBillRequest workflow for this org scope ─────
        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);

        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceBillRequest';

        IF @workflow_types_id IS NULL
            THROW 56019, 'No ServiceBillRequest workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key] = '0' AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 56020, 'No approver found for the first stage of the ServiceBillRequest workflow.', 1;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(request_no, 4) AS INT)), 0) + 1
        FROM dbo.service_bill_request WITH (UPDLOCK, HOLDLOCK)
        WHERE request_no LIKE 'SBR-' + @year + '-%';
        DECLARE @request_no VARCHAR(30) = 'SBR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.service_bill_request (
            request_no, agreement_sno, com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
            billing_period_start, billing_period_end, invoice_no, invoice_date, invoice_amount, invoice_doc_url,
            remarks, workflow_types_id, current_approver_id, status, is_active, created_by
        )
        VALUES (
            @request_no, @agreement_sno, @com_sno, @div_sno, @brn_sno, @dept_sno, @service_sno, @vendor_sno,
            @billing_period_start, @billing_period_end, @invoice_no, @invoice_date, @invoice_amount, @invoice_doc_url,
            @remarks, @workflow_types_id, @first_approver, 'P', 'Y', @created_by
        );

        DECLARE @bill_request_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.service_bill_request_history (bill_request_sno, action_type, status_by, comment, is_active)
        VALUES (@bill_request_sno, 'SUBMITTED', @created_by, NULL, 'Y');

        COMMIT TRANSACTION;

        SELECT
            @bill_request_sno AS bill_request_sno,
            @request_no       AS request_no,
            'SUCCESS'         AS result,
            N'Service bill request submitted for approval.' AS message;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- sp_nt_ApproveServiceBillRequest — single-stage progression, mirrors
-- sp_approve_service_agreement. On final approval, auto-issues the Service
-- PO to match the approved invoice amount (direct — no separate PO approval,
-- same reasoning as the Fixed-Recurring cycle issuer). No PR — Variable
-- Recurring has never had a PR-autofill step (is_retrospective=1).
-- @jsonInput: { bill_request_sno, approved_by, comments, approval_stages, action }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ApproveServiceBillRequest', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_ApproveServiceBillRequest;
GO
CREATE PROCEDURE dbo.sp_nt_ApproveServiceBillRequest
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

        DECLARE @bill_request_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.bill_request_sno') AS INT),
                @comments         VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages  NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by      VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action           VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');

        IF @bill_request_sno IS NULL
        BEGIN
            RAISERROR('bill_request_sno is required.', 16, 1);
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

        IF NOT EXISTS (SELECT 1 FROM dbo.service_bill_request WHERE bill_request_sno = @bill_request_sno AND is_active = 'Y')
        BEGIN
            RAISERROR('Service bill request not found or inactive.', 16, 1);
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
            INSERT INTO dbo.service_bill_request_history (bill_request_sno, action_type, status_by, comment, is_active)
            VALUES (@bill_request_sno, 'REJECTED', @approved_by, @comments, 'Y');

            UPDATE dbo.service_bill_request
            SET status = 'R', current_approver_id = NULL
            WHERE bill_request_sno = @bill_request_sno;

            DROP TABLE #approval_stages;

            SELECT 'REJECTED' AS result, @bill_request_sno AS bill_request_sno, @approved_by AS rejected_by, GETDATE() AS rejected_on;
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

        INSERT INTO dbo.service_bill_request_history (bill_request_sno, action_type, status_by, comment, is_active)
        VALUES (@bill_request_sno, 'APPROVED', @approved_by, @comments, 'Y');

        UPDATE dbo.service_bill_request
        SET current_approver_id = @next_current_approver
        WHERE bill_request_sno = @bill_request_sno;

        DECLARE @auto_po_result VARCHAR(30) = NULL, @auto_po_basic_sno INT = NULL, @auto_po_no VARCHAR(50) = NULL;

        IF @next_current_approver IS NULL
        BEGIN
            UPDATE dbo.service_bill_request SET status = 'A' WHERE bill_request_sno = @bill_request_sno;

            DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @service_sno INT, @vendor_sno INT,
                    @invoice_amount DECIMAL(18,2), @billing_period_start DATE, @billing_period_end DATE,
                    @ceiling_amount DECIMAL(18,2), @variance_tolerance_pct DECIMAL(5,2), @rate_uom_sno INT, @agreement_sno INT;

            SELECT @com_sno = sbr.com_sno, @div_sno = sbr.div_sno, @brn_sno = sbr.brn_sno, @dept_sno = sbr.dept_sno,
                   @service_sno = sbr.service_sno, @vendor_sno = sbr.vendor_sno, @invoice_amount = sbr.invoice_amount,
                   @billing_period_start = sbr.billing_period_start, @billing_period_end = sbr.billing_period_end,
                   @agreement_sno = sbr.agreement_sno, @ceiling_amount = sa.ceiling_amount,
                   @variance_tolerance_pct = sa.variance_tolerance_pct, @rate_uom_sno = sa.rate_uom_sno
            FROM dbo.service_bill_request sbr
            JOIN dbo.service_agreement sa ON sa.agreement_sno = sbr.agreement_sno
            WHERE sbr.bill_request_sno = @bill_request_sno;

            DECLARE @poJson NVARCHAR(MAX) = (
                SELECT @com_sno AS com_sno, @div_sno AS div_sno, @brn_sno AS brn_sno, @dept_sno AS dept_sno,
                       @vendor_sno AS vendor_sno, 1 AS is_retrospective,
                       @service_sno AS service_sno, 1 AS qty, @rate_uom_sno AS uom_sno,
                       @invoice_amount AS unit_price, 'RECURRING' AS po_type,
                       @billing_period_start AS validity_from, @billing_period_end AS validity_to,
                       @ceiling_amount AS ceiling_amount, @variance_tolerance_pct AS variance_tolerance_pct,
                       @approved_by AS issued_by,
                       (N'Auto-issued Service PO — Service Bill Request ' + CAST(@bill_request_sno AS VARCHAR(10))
                        + N', against ceiling Service Agreement ' + CAST(@agreement_sno AS VARCHAR(10))) AS source_note,
                       (N'Variable Recurring service PO — Bill Request ' + CAST(@bill_request_sno AS VARCHAR(10))) AS purpose
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
            );

            BEGIN TRY
                EXEC dbo.sp_nt_DirectIssueServicePO
                    @jsonInput = @poJson, @silent = 1,
                    @out_result = @auto_po_result OUTPUT, @out_po_basic_sno = @auto_po_basic_sno OUTPUT, @out_po_no = @auto_po_no OUTPUT;

                IF @auto_po_basic_sno IS NOT NULL
                    UPDATE dbo.service_bill_request SET po_basic_sno = @auto_po_basic_sno WHERE bill_request_sno = @bill_request_sno;
            END TRY
            BEGIN CATCH
                -- Do not fail the approval itself — see file header.
                -- po_basic_sno stays NULL; retryable via
                -- sp_nt_RetryServiceBillRequestPOIssue below.
                SET @auto_po_result = 'ERROR: ' + ERROR_MESSAGE();
            END CATCH
        END

        DROP TABLE #approval_stages;

        SELECT
            'SUCCESS'                                      AS result,
            @bill_request_sno                              AS bill_request_sno,
            @approved_by                                    AS approved_by,
            GETDATE()                                        AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE')     AS next_approver,
            @auto_po_result                                    AS auto_po_result,
            @auto_po_basic_sno                                  AS auto_po_basic_sno,
            @auto_po_no                                          AS auto_po_no;

    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL
            DROP TABLE #approval_stages;

        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO

-- ============================================================
-- sp_nt_RetryServiceBillRequestPOIssue — closes the gap where an approved
-- bill request's PO auto-issuance failed (network blip, transient lock,
-- etc.) and was swallowed to keep the approval standing. Safe to call
-- repeatedly: a no-op once po_basic_sno is already set.
-- @jsonInput: { bill_request_sno, issued_by }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_RetryServiceBillRequestPOIssue', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_RetryServiceBillRequestPOIssue;
GO
CREATE PROCEDURE dbo.sp_nt_RetryServiceBillRequestPOIssue
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @bill_request_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.bill_request_sno') AS INT);
    DECLARE @issued_by VARCHAR(20) = ISNULL(JSON_VALUE(@jsonInput, '$.issued_by'), 'SYSTEM');

    IF @bill_request_sno IS NULL
        THROW 56030, 'bill_request_sno is required.', 1;

    DECLARE @status CHAR(1), @po_basic_sno INT;
    SELECT @status = status, @po_basic_sno = po_basic_sno FROM dbo.service_bill_request WHERE bill_request_sno = @bill_request_sno;

    IF @status IS NULL
        THROW 56031, 'Service bill request not found.', 1;
    IF @status <> 'A'
        THROW 56032, 'Only an Approved Service bill request can have its PO (re)issued.', 1;
    IF @po_basic_sno IS NOT NULL
    BEGIN
        SELECT 'ALREADY_ISSUED' AS result, @bill_request_sno AS bill_request_sno, @po_basic_sno AS po_basic_sno;
        RETURN;
    END

    DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @service_sno INT, @vendor_sno INT,
            @invoice_amount DECIMAL(18,2), @billing_period_start DATE, @billing_period_end DATE,
            @ceiling_amount DECIMAL(18,2), @variance_tolerance_pct DECIMAL(5,2), @rate_uom_sno INT, @agreement_sno INT;

    SELECT @com_sno = sbr.com_sno, @div_sno = sbr.div_sno, @brn_sno = sbr.brn_sno, @dept_sno = sbr.dept_sno,
           @service_sno = sbr.service_sno, @vendor_sno = sbr.vendor_sno, @invoice_amount = sbr.invoice_amount,
           @billing_period_start = sbr.billing_period_start, @billing_period_end = sbr.billing_period_end,
           @agreement_sno = sbr.agreement_sno, @ceiling_amount = sa.ceiling_amount,
           @variance_tolerance_pct = sa.variance_tolerance_pct, @rate_uom_sno = sa.rate_uom_sno
    FROM dbo.service_bill_request sbr
    JOIN dbo.service_agreement sa ON sa.agreement_sno = sbr.agreement_sno
    WHERE sbr.bill_request_sno = @bill_request_sno;

    DECLARE @poJson NVARCHAR(MAX) = (
        SELECT @com_sno AS com_sno, @div_sno AS div_sno, @brn_sno AS brn_sno, @dept_sno AS dept_sno,
               @vendor_sno AS vendor_sno, 1 AS is_retrospective,
               @service_sno AS service_sno, 1 AS qty, @rate_uom_sno AS uom_sno,
               @invoice_amount AS unit_price, 'RECURRING' AS po_type,
               @billing_period_start AS validity_from, @billing_period_end AS validity_to,
               @ceiling_amount AS ceiling_amount, @variance_tolerance_pct AS variance_tolerance_pct,
               @issued_by AS issued_by,
               (N'Auto-issued Service PO (retry) — Service Bill Request ' + CAST(@bill_request_sno AS VARCHAR(10))) AS source_note,
               (N'Variable Recurring service PO — Bill Request ' + CAST(@bill_request_sno AS VARCHAR(10))) AS purpose
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    DECLARE @out_result VARCHAR(30), @out_po_basic_sno INT, @out_po_no VARCHAR(50);
    EXEC dbo.sp_nt_DirectIssueServicePO
        @jsonInput = @poJson, @silent = 1,
        @out_result = @out_result OUTPUT, @out_po_basic_sno = @out_po_basic_sno OUTPUT, @out_po_no = @out_po_no OUTPUT;

    IF @out_po_basic_sno IS NOT NULL
        UPDATE dbo.service_bill_request SET po_basic_sno = @out_po_basic_sno WHERE bill_request_sno = @bill_request_sno;

    SELECT @out_result AS result, @bill_request_sno AS bill_request_sno, @out_po_basic_sno AS po_basic_sno, @out_po_no AS po_no;
END;
GO

-- ============================================================
-- sp_nt_GetServiceBillRequests — list/filter, for admin/browse screens
-- @jsonInput optional: { com_sno?, div_sno?, brn_sno?, dept_sno?,
--   agreement_sno?, status? }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServiceBillRequests', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetServiceBillRequests;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceBillRequests
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL,
            @agreement_sno INT = NULL, @status VARCHAR(1) = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @com_sno       = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno       = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno       = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno      = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        SET @agreement_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
        SET @status        = JSON_VALUE(@jsonInput, '$.status');
    END

    SELECT
        sbr.bill_request_sno, sbr.request_no, sbr.agreement_sno, sa.agreement_no,
        sbr.com_sno, sbr.div_sno, sbr.brn_sno, sbr.dept_sno,
        sbr.service_sno, sm.service_name,
        sbr.vendor_sno, k.company_name AS vendor_name,
        sbr.billing_period_start, sbr.billing_period_end,
        sbr.invoice_no, sbr.invoice_date, sbr.invoice_amount, sbr.invoice_doc_url,
        sbr.remarks, sbr.workflow_types_id, sbr.current_approver_id, sbr.status,
        sbr.po_basic_sno, po.po_df_no AS po_no,
        sbr.created_by, sbr.created_at
    FROM dbo.service_bill_request sbr
    JOIN dbo.service_agreement sa   ON sa.agreement_sno = sbr.agreement_sno
    JOIN dbo.service_master sm      ON sm.service_sno = sbr.service_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = sbr.vendor_sno
    LEFT JOIN dbo.po_request_info po ON po.po_basic_sno = sbr.po_basic_sno
    WHERE sbr.is_active = 'Y'
      AND (@com_sno IS NULL OR sbr.com_sno = @com_sno)
      AND (@div_sno IS NULL OR sbr.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR sbr.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR sbr.dept_sno = @dept_sno)
      AND (@agreement_sno IS NULL OR sbr.agreement_sno = @agreement_sno)
      AND (@status IS NULL OR sbr.status = @status)
    ORDER BY sbr.bill_request_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetServiceBillRequestsForApproval — pending bill requests for the
-- logged-in approver, mirrors sp_nt_GetServiceAgreementsForApproval's shape.
-- @Ecno VARCHAR(50)
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServiceBillRequestsForApproval', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetServiceBillRequestsForApproval;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceBillRequestsForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        sbr.bill_request_sno, sbr.request_no, sbr.agreement_sno, sa.agreement_no,
        sbr.com_sno, sbr.div_sno, sbr.brn_sno, sbr.dept_sno,
        sbr.service_sno, sm.service_name,
        sbr.vendor_sno, k.company_name AS vendor_name,
        sbr.billing_period_start, sbr.billing_period_end,
        sbr.invoice_no, sbr.invoice_date, sbr.invoice_amount, sbr.invoice_doc_url,
        sa.ceiling_amount, sa.variance_tolerance_pct,
        sbr.remarks, sbr.workflow_types_id, sbr.current_approver_id, sbr.status,
        (
            SELECT ws.stage_order_json
            FROM dbo.workflow_stage ws
            WHERE ws.workflow_types_id = sbr.workflow_types_id AND ws.is_active = 'Y'
        ) AS stage_order_json
    FROM dbo.service_bill_request sbr
    JOIN dbo.service_agreement sa   ON sa.agreement_sno = sbr.agreement_sno
    JOIN dbo.service_master sm      ON sm.service_sno = sbr.service_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = sbr.vendor_sno
    WHERE sbr.current_approver_id = @Ecno
      AND sbr.status = 'P'
      AND sbr.is_active = 'Y'
    ORDER BY sbr.bill_request_sno DESC;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.recurrence_cadence_master ORDER BY recurrence_cadence_sno;
--   SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_agreement') AND name = 'recurrence_cadence_sno';
--   SELECT name FROM sys.procedures WHERE name IN (
--     'sp_nt_GetRecurrenceCadenceRecords','sp_nt_CreateRecurrenceCadenceRecords',
--     'sp_nt_CreateServiceAgreement','sp_approve_service_agreement',
--     'sp_nt_DirectIssueServicePO','sp_nt_IssueRecurringServicePOCycle',
--     'sp_nt_ProcessDueRecurringServiceAgreements',
--     'sp_nt_CreateServiceBillRequest','sp_nt_ApproveServiceBillRequest',
--     'sp_nt_GetServiceBillRequests','sp_nt_GetServiceBillRequestsForApproval',
--     'sp_nt_GetActiveCeilingAgreementsForBilling','sp_nt_RetryServiceBillRequestPOIssue'
--   );
--
-- NOTE before using in anger:
--   - A ServiceBillRequest workflow (approval_workflow_master/workflow_types,
--     entity_type='ServiceBillRequest') must be configured per org scope
--     before sp_nt_CreateServiceBillRequest will succeed — same setup burden
--     as every other document type in this codebase (THROW 56019 otherwise).
--   - sp_nt_ProcessDueRecurringServiceAgreements needs a scheduler to call it
--     (SQL Agent job, or a Node cron replacing RecurringPrJob.js) — this file
--     only adds the procedure, not a live schedule.
--   - Still not built (Node.js/frontend, deliberately out of scope this pass
--     per "write everything in procedure"): a ServiceBillRequest module
--     (repository/service/routes/controller) mirroring ServiceAgreement's
--     shape, an entry+approval screen pair, and updating RecurringPrJob.js
--     (or replacing it with a call to sp_nt_ProcessDueRecurringServiceAgreements)
--     so the sweep actually runs on a schedule.
--   - "Upload invoice" (Fixed) and Service GRN / Payment (both flows)
--     deliberately reuse the EXISTING Invoice (grn-service/sql/13_invoice.sql),
--     Service Entry (grn-service/sql/12_service_entry.sql), and Payment
--     (grn-service/sql/14_payment.sql) modules — nothing new needed there,
--     they already work against any po_basic_sno with po_section='SERVICE'
--     items, which every PO this file issues has.
-- ============================================================
