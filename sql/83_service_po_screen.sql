-- ============================================================
-- 83_service_po_screen.sql
--
-- New Service PO screen. Today, every recurring PO cycle (Fixed AND
-- Unfixed) issues silently into po_request_info/po_item_details the moment
-- it's due — no screen, no human step beyond the agreement's own approval.
-- This file changes that: sp_nt_IssueRecurringServicePOCycle now stops at a
-- new service_po_cycle row instead of issuing directly.
--   - Fixed: nothing to enter (rate/qty were already locked in at agreement
--     approval) — goes straight to Pending Approval.
--   - Unfixed: Pending Entry first — a human enters rate/discount/GST for
--     this cycle (capped by a new ceiling_amount on the agreement), which
--     moves it to Pending Approval.
-- Both then converge on the same new 'ServicePO' approval workflow
-- (mirrors sp_approve_service_agreement's stage-advance mechanics from
-- sql/82). On final approval the PO is raised for real, same
-- po_request_info/po_item_details shape sp_nt_DirectIssueServicePO already
-- used, but with the cycle's real entered values instead of zeros.
--
-- Operational consequence: today Fixed auto-issues with zero admin setup.
-- After this file, NEITHER type issues a PO until an admin configures the
-- ServicePO workflow via the existing UserRoleApprovalScreen.tsx.
--
-- Depends on sql/73_service_agreement_rebuild.sql and sql/82's
-- sp_approve_service_agreement already being live (both confirmed live
-- 2026-09-17). Does NOT depend on sql/81_service_agreement_dispatch_grn.sql
-- (confirmed NOT live) — untouched here: no dispatch_type, incharge_ecno,
-- or service_grn changes.
--
-- Explicitly not reusing the dormant po_request_info.ceiling_amount /
-- consumed_amount / parent_blanket_po_sno columns (leftover from the old
-- pre-2026-09-11 system — zero live usage, zero application code
-- references, and they model shared consumption against one blanket PO,
-- not an independent per-cycle cap). ceiling_amount here lives on
-- service_agreement instead, a fresh column.
--
-- Idempotent throughout — safe to re-run, same convention as every prior
-- file in this chain.
-- ============================================================

-- ============================================================
-- 1) entity_master seed — 'ServicePO', so an admin can configure its
--    approval workflow via the existing UserRoleApprovalScreen.tsx /
--    approval_workflow_master mechanism. Re-adds the exact row
--    71_remove_service_feature.sql deleted (schema unchanged since —
--    verified live).
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.entity_master WHERE entity_code = 'ServicePO')
    INSERT INTO dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by)
    VALUES (N'Service Purchase Order', N'ServicePO', N'Per-cycle approval for a recurring Service Agreement''s PO — Fixed: amount pre-filled from the agreement; Unfixed: rate/GST entered manually, capped by the agreement''s ceiling amount', 'Y', N'system');
GO

-- ============================================================
-- 2) service_agreement.ceiling_amount — Unfixed-only cap, enforced at
--    entry-submission time (sp_nt_SubmitServicePoEntry). NULL means no cap
--    enforced (covers agreements created before this column existed, e.g.
--    the live AGR-2026-0002) — not a hard block by default. Unused for
--    Fixed.
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_agreement') AND name = 'ceiling_amount')
    ALTER TABLE dbo.service_agreement ADD ceiling_amount DECIMAL(18,2) NULL;
GO

-- ============================================================
-- 3) service_po_cycle — one row per PO cycle, pending until approved.
-- ============================================================
IF OBJECT_ID('dbo.service_po_cycle', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_po_cycle (
        cycle_sno             INT IDENTITY(1,1) PRIMARY KEY,
        agreement_sno         INT           NOT NULL,
        com_sno                INT           NOT NULL,
        div_sno                INT           NOT NULL,
        brn_sno                INT           NOT NULL,
        dept_sno               INT           NOT NULL,
        billing_period_start  DATE          NOT NULL,
        pr_basic_sno           INT           NOT NULL,
        pr_no                   VARCHAR(20)   NOT NULL,
        qty                     DECIMAL(18,4) NOT NULL,
        rate_amount             DECIMAL(18,2) NULL,
        discount_pct            DECIMAL(5,2)  NULL,
        gst_pct                 DECIMAL(5,2)  NULL,
        net_cost                DECIMAL(18,2) NULL,
        remarks                 NVARCHAR(500) NULL,
        status                  VARCHAR(20)   NOT NULL DEFAULT 'PENDING_ENTRY', -- PENDING_ENTRY|PENDING_APPROVAL|GENERATED|REJECTED
        workflow_types_id       INT           NULL,
        current_approver_id     VARCHAR(30)   NULL,
        entered_by               VARCHAR(20)   NULL,
        entered_at                DATETIME      NULL,
        po_basic_sno               INT           NULL,
        created_at                  DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_service_po_cycle_agreement FOREIGN KEY (agreement_sno)
            REFERENCES dbo.service_agreement (agreement_sno),
        CONSTRAINT FK_service_po_cycle_po FOREIGN KEY (po_basic_sno)
            REFERENCES dbo.po_request_info (po_basic_sno),
        CONSTRAINT UQ_service_po_cycle_period UNIQUE (agreement_sno, billing_period_start),
        CONSTRAINT CK_service_po_cycle_status CHECK (status IN ('PENDING_ENTRY','PENDING_APPROVAL','GENERATED','REJECTED'))
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_service_po_cycle_approver' AND object_id = OBJECT_ID('dbo.service_po_cycle'))
    CREATE INDEX IX_service_po_cycle_approver ON dbo.service_po_cycle (current_approver_id, status);
GO

-- ============================================================
-- 4) service_po_cycle_history — audit trail, same shape as
--    service_agreement_history.
-- ============================================================
IF OBJECT_ID('dbo.service_po_cycle_history', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_po_cycle_history (
        history_sno  INT IDENTITY(1,1) PRIMARY KEY,
        cycle_sno    INT           NOT NULL,
        action_type  VARCHAR(30)   NOT NULL,
        status_by    VARCHAR(20)   NOT NULL,
        comment      VARCHAR(500)  NULL,
        created_at   DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_service_po_cycle_history_cycle FOREIGN KEY (cycle_sno)
            REFERENCES dbo.service_po_cycle (cycle_sno)
    );
END;
GO

-- ============================================================
-- 5) sp_nt_ResolveServicePoWorkflow — shared workflow lookup for the
--    ServicePO entity_type, same join shape sp_nt_CreateServiceAgreement
--    already uses for 'ServiceAgreement'. Used both when a Fixed cycle is
--    auto-queued (workflow resolved immediately) and when an Unfixed entry
--    is submitted (workflow resolved then).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ResolveServicePoWorkflow', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ResolveServicePoWorkflow;
GO
CREATE PROCEDURE dbo.sp_nt_ResolveServicePoWorkflow
    @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT,
    @workflow_types_id INT OUTPUT,
    @first_approver VARCHAR(30) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @workflow_types_id = wt.workflow_types_id
    FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
      AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
      AND awm.entity_type = 'ServicePO';

    IF @workflow_types_id IS NULL
        THROW 58310, 'No ServicePO workflow configuration found for this company/division/branch/department.', 1;

    SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
    FROM dbo.vw_workflow_stages AS ws
    CROSS APPLY OPENJSON(ws.stages_json) AS s
    CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
    WHERE ws.workflow_types_id = @workflow_types_id
      AND s.[key] = '0' AND s2.[key] = '0';

    IF @first_approver IS NULL
        THROW 58311, 'No approver found for the first stage of the ServicePO workflow.', 1;
END;
GO

-- ============================================================
-- 6) sp_nt_CreateServiceAgreement — redefined only to accept an optional
--    ceiling_amount (meaningful for Unfixed; ignored/NULL for Fixed).
--    Everything else byte-identical to sql/73's version.
-- ============================================================
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
            period_start_date, period_end_date, agreement_doc_url, remarks, ceiling_amount,
            workflow_types_id, current_approver_id, status, is_active, created_by
        )
        VALUES (
            @agreement_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @service_sno, @vendor_sno,
            @qty, @rate_amount, @rate_uom_sno, @recurrence_cadence_sno, @po_generation_day, @notify_days_before,
            @period_start_date, @period_end_date, @agreement_doc_url, @remarks, @ceiling_amount,
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

-- ============================================================
-- 7) sp_nt_UpdateServiceAgreement — same ceiling_amount addition as create.
-- ============================================================
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
            agreement_doc_url = @agreement_doc_url, remarks = @remarks, ceiling_amount = @ceiling_amount,
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

-- ============================================================
-- 8) sp_nt_IssueRecurringServicePOCycle — redefined. Idempotency claim and
--    internal audit-trail PR creation are byte-identical to sql/73;
--    only the final section changes: instead of calling
--    sp_nt_DirectIssueServicePO, it queues a service_po_cycle row.
--    @out_po_basic_sno/@out_po_no are KEPT (existing callers —
--    sp_approve_service_agreement in sql/82, and
--    sp_nt_ProcessDueRecurringServiceAgreements's cursor — pass them by
--    name) but now always come back NULL, since no PO is issued
--    synchronously any more; both callers already handle a NULL
--    po_basic_sno gracefully (verified by reading both). New
--    @out_cycle_sno/@out_cycle_status are additive.
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

        BEGIN TRANSACTION;

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
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        UPDATE dbo.service_agreement_recurring_pr_log
        SET status = 'FAILED', error_message = ERROR_MESSAGE(), modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start AND status = 'PENDING';

        SET @out_result = 'ERROR';
        IF @silent = 0 THROW;
    END CATCH
END;
GO

-- ============================================================
-- 9) sp_nt_SubmitServicePoEntry — Unfixed only: rate/GST/discount entry for
--    a Pending Entry cycle, capped by the agreement's ceiling_amount (NULL
--    ceiling = no cap enforced), then resolves the ServicePO workflow and
--    moves to Pending Approval.
-- @jsonInput: { cycle_sno, rate_amount, discount_pct?, gst_pct?, remarks?,
--   submitted_by }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_SubmitServicePoEntry', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_SubmitServicePoEntry;
GO
CREATE PROCEDURE dbo.sp_nt_SubmitServicePoEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @cycle_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.cycle_sno') AS INT);
        DECLARE @rate_amount  DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @discount_pct DECIMAL(5,2)  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.discount_pct') AS DECIMAL(5,2)), 0);
        DECLARE @gst_pct      DECIMAL(5,2)  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.gst_pct') AS DECIMAL(5,2)), 0);
        DECLARE @remarks      NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @submitted_by VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.submitted_by');

        IF @cycle_sno IS NULL OR @rate_amount IS NULL OR @rate_amount <= 0 OR @submitted_by IS NULL
            THROW 58320, 'cycle_sno, rate_amount and submitted_by are required.', 1;
        IF @discount_pct < 0 OR @discount_pct > 100 OR @gst_pct < 0 OR @gst_pct > 100
            THROW 58324, 'discount_pct and gst_pct must be between 0 and 100.', 1;

        DECLARE @agreement_sno INT, @qty DECIMAL(18,4), @status VARCHAR(20),
                @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @ceiling_amount DECIMAL(18,2);
        SELECT @agreement_sno = spc.agreement_sno, @qty = spc.qty, @status = spc.status,
               @com_sno = spc.com_sno, @div_sno = spc.div_sno, @brn_sno = spc.brn_sno, @dept_sno = spc.dept_sno,
               @ceiling_amount = sa.ceiling_amount
        FROM dbo.service_po_cycle spc
        JOIN dbo.service_agreement sa ON sa.agreement_sno = spc.agreement_sno
        WHERE spc.cycle_sno = @cycle_sno;

        IF @agreement_sno IS NULL THROW 58321, 'Service PO cycle not found.', 1;
        IF @status <> 'PENDING_ENTRY' THROW 58322, 'This cycle is not awaiting entry.', 1;

        DECLARE @net_cost DECIMAL(18,2) = (@rate_amount * @qty) * (1 - @discount_pct / 100.0) * (1 + @gst_pct / 100.0);

        IF @ceiling_amount IS NOT NULL AND @net_cost > @ceiling_amount
            THROW 58323, 'Entered amount exceeds the agreement''s ceiling amount.', 1;

        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        EXEC dbo.sp_nt_ResolveServicePoWorkflow
            @com_sno = @com_sno, @div_sno = @div_sno, @brn_sno = @brn_sno, @dept_sno = @dept_sno,
            @workflow_types_id = @workflow_types_id OUTPUT, @first_approver = @first_approver OUTPUT;

        UPDATE dbo.service_po_cycle
        SET rate_amount = @rate_amount, discount_pct = @discount_pct, gst_pct = @gst_pct, net_cost = @net_cost,
            remarks = @remarks, status = 'PENDING_APPROVAL',
            workflow_types_id = @workflow_types_id, current_approver_id = @first_approver,
            entered_by = @submitted_by, entered_at = GETDATE()
        WHERE cycle_sno = @cycle_sno;

        INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
        VALUES (@cycle_sno, 'ENTRY_SUBMITTED', @submitted_by,
                N'Rate ' + CAST(@rate_amount AS VARCHAR(30)) + N', GST ' + CAST(@gst_pct AS VARCHAR(10)) + N'%, Net ' + CAST(@net_cost AS VARCHAR(30)));

        SELECT 'SUCCESS' AS result, @cycle_sno AS cycle_sno, @net_cost AS net_cost;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- 10) sp_nt_ApproveServicePoCycle — stage-advance mechanics mirror sql/82's
--     sp_approve_service_agreement exactly (posted approval_stages,
--     LEAD/self-join for the next approver, wrapped in a transaction). On
--     the final stage, raises the actual PO — same po_request_info/
--     po_item_details shape sp_nt_DirectIssueServicePO already used, but
--     with the cycle's real rate/discount/GST instead of zeros.
-- @jsonInput: { cycle_sno, approved_by, action, comments, approval_stages }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ApproveServicePoCycle', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ApproveServicePoCycle;
GO
CREATE PROCEDURE dbo.sp_nt_ApproveServicePoCycle
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

        DECLARE @cycle_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.cycle_sno') AS INT),
                @comments        VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by     VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action          VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');

        IF @cycle_sno IS NULL
        BEGIN
            RAISERROR('cycle_sno is required.', 16, 1);
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

        IF NOT EXISTS (SELECT 1 FROM dbo.service_po_cycle WHERE cycle_sno = @cycle_sno AND status = 'PENDING_APPROVAL')
        BEGIN
            RAISERROR('Service PO cycle not found or not awaiting approval.', 16, 1);
            RETURN;
        END

        BEGIN TRANSACTION;

        CREATE TABLE #po_approval_stages (
            seq_no INT, approver_ecno VARCHAR(30), stage VARCHAR(100),
            required_approvals VARCHAR(10), is_mandatory CHAR(1), escalation_hours VARCHAR(10),
            approver_condition VARCHAR(200), next_approver_ecno VARCHAR(30),
            can_forward CHAR(1), can_backward CHAR(1), can_edit_data CHAR(1)
        );

        INSERT INTO #po_approval_stages (
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
            INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
            VALUES (@cycle_sno, 'REJECTED', @approved_by, @comments);

            UPDATE dbo.service_po_cycle SET status = 'REJECTED', current_approver_id = NULL WHERE cycle_sno = @cycle_sno;

            DROP TABLE #po_approval_stages;
            COMMIT TRANSACTION;
            SELECT 'REJECTED' AS result, @cycle_sno AS cycle_sno, @approved_by AS rejected_by, GETDATE() AS rejected_on;
            RETURN;
        END

        DECLARE @next_current_approver VARCHAR(30);
        SELECT @next_current_approver = next_stage.approver_ecno
        FROM (
            SELECT approver_ecno, LEAD(approver_ecno, 1, NULL) OVER (ORDER BY seq_no) AS next_approver_ecno
            FROM #po_approval_stages
        ) current_stage
        LEFT JOIN #po_approval_stages next_stage ON next_stage.approver_ecno = current_stage.next_approver_ecno
        WHERE current_stage.approver_ecno = @approved_by;

        INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
        VALUES (@cycle_sno, 'APPROVED', @approved_by, @comments);

        UPDATE dbo.service_po_cycle SET current_approver_id = @next_current_approver WHERE cycle_sno = @cycle_sno;

        DECLARE @out_po_basic_sno INT = NULL, @out_po_no VARCHAR(50) = NULL;

        IF @next_current_approver IS NULL
        BEGIN
            -- ── Final stage: raise the actual PO ────────────────────────
            DECLARE @agreement_sno INT, @pr_basic_sno INT, @qty DECIMAL(18,4), @rate_amount DECIMAL(18,2),
                    @discount_pct DECIMAL(5,2), @gst_pct DECIMAL(5,2), @net_cost DECIMAL(18,2),
                    @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @vendor_sno INT,
                    @service_sno INT, @service_name NVARCHAR(150), @rate_uom_sno INT, @agreement_no VARCHAR(30),
                    @service_type_sno INT, @period_end DATE;

            SELECT @agreement_sno = spc.agreement_sno, @pr_basic_sno = spc.pr_basic_sno, @qty = spc.qty,
                   @rate_amount = spc.rate_amount, @discount_pct = ISNULL(spc.discount_pct, 0),
                   @gst_pct = ISNULL(spc.gst_pct, 0), @net_cost = spc.net_cost,
                   @com_sno = spc.com_sno, @div_sno = spc.div_sno, @brn_sno = spc.brn_sno, @dept_sno = spc.dept_sno
            FROM dbo.service_po_cycle spc
            WHERE spc.cycle_sno = @cycle_sno;

            SELECT @vendor_sno = sa.vendor_sno, @service_sno = sa.service_sno, @rate_uom_sno = sa.rate_uom_sno,
                   @agreement_no = sa.agreement_no, @period_end = sa.period_end_date,
                   @service_name = sm.service_name, @service_type_sno = sm.service_type_sno
            FROM dbo.service_agreement sa
            JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
            WHERE sa.agreement_sno = @agreement_sno;

            DECLARE @po_year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
            DECLARE @po_seq  INT;
            SELECT @po_seq = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
            FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
            WHERE po_df_no LIKE 'SVO-' + @po_year + '-%';
            SET @out_po_no = 'SVO-' + @po_year + '-' + RIGHT('0000' + CAST(@po_seq AS VARCHAR(4)), 4);

            INSERT INTO dbo.po_request_info (
                vendor_sno, brn_sno, dept_sno, com_sno, div_sno, budget_sno, budget_code, pr_basic_sno,
                po_date, required_date, purpose, terms_conditions, delivery_address,
                is_active, workflow_types_id, current_approver_id, status, po_df_no, service_type_sno
            )
            VALUES (
                @vendor_sno, @brn_sno, @dept_sno, @com_sno, @div_sno, NULL, NULL, @pr_basic_sno,
                CAST(GETDATE() AS DATE), @period_end,
                N'Recurring service PO — Agreement ' + @agreement_no + N' (' + @service_name + N')', NULL, NULL,
                'Y', NULL, NULL, 'A', @out_po_no, @service_type_sno
            );
            SET @out_po_basic_sno = SCOPE_IDENTITY();

            INSERT INTO dbo.po_item_details (
                po_basic_sno, pr_item_sno, service_sno, prod_name, specification,
                qty, unit, unit_name, agreed_unit_price, total_cost, discount_pct, tax_pct, net_cost,
                remarks, po_section, created_by, created_date, is_active
            )
            SELECT
                @out_po_basic_sno, NULL, @service_sno, sm.service_name, '',
                @qty, @rate_uom_sno, um.uom_name, @rate_amount, @rate_amount * @qty, @discount_pct, @gst_pct, @net_cost,
                NULL, 'SERVICE', @approved_by, GETDATE(), '1'
            FROM dbo.service_master sm
            LEFT JOIN dbo.uom_master um ON um.uom_sno = @rate_uom_sno
            WHERE sm.service_sno = @service_sno;

            INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
            VALUES (@out_po_basic_sno, 'APPROVED_ISSUED', @approved_by, N'Issued after Service PO cycle approval (Agreement ' + @agreement_no + N').', 'Y');

            UPDATE dbo.service_po_cycle SET status = 'GENERATED', po_basic_sno = @out_po_basic_sno WHERE cycle_sno = @cycle_sno;

            UPDATE dbo.service_agreement_recurring_pr_log
            SET po_basic_sno = @out_po_basic_sno, po_no = @out_po_no
            WHERE agreement_sno = @agreement_sno AND pr_basic_sno = @pr_basic_sno;
        END

        DROP TABLE #po_approval_stages;
        COMMIT TRANSACTION;

        SELECT
            'SUCCESS' AS result, @cycle_sno AS cycle_sno, @approved_by AS approved_by, GETDATE() AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE') AS next_approver,
            @out_po_basic_sno AS po_basic_sno, @out_po_no AS po_no;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF OBJECT_ID('tempdb..#po_approval_stages') IS NOT NULL DROP TABLE #po_approval_stages;
        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO

-- ============================================================
-- 11) sp_nt_GetServicePoCycles — list for the Service PO screen. Both
--     Fixed and Unfixed rows come from the same table now; the frontend
--     splits them into tabs client-side by service_type_code, same pattern
--     ServiceAgreementPage.tsx already uses for agreements.
-- @jsonInput optional: { com_sno?, div_sno?, brn_sno?, dept_sno? }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServicePoCycles', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServicePoCycles;
GO
CREATE PROCEDURE dbo.sp_nt_GetServicePoCycles
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

    SELECT spc.cycle_sno, spc.agreement_sno, sa.agreement_no,
           spc.com_sno, spc.div_sno, spc.brn_sno, spc.dept_sno,
           sm.service_name, st.service_type_code, st.service_type_name,
           k.company_name AS vendor_name,
           spc.billing_period_start, spc.qty, spc.rate_amount, spc.discount_pct, spc.gst_pct, spc.net_cost,
           sa.ceiling_amount, spc.status, spc.current_approver_id,
           spc.po_basic_sno, po.po_df_no AS po_no, po.po_date,
           spc.entered_by, spc.entered_at, spc.created_at
    FROM dbo.service_po_cycle spc
    JOIN dbo.service_agreement sa ON sa.agreement_sno = spc.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.po_request_info po ON po.po_basic_sno = spc.po_basic_sno
    WHERE (@com_sno IS NULL OR spc.com_sno = @com_sno)
      AND (@div_sno IS NULL OR spc.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR spc.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR spc.dept_sno = @dept_sno)
    ORDER BY spc.cycle_sno DESC;
END;
GO

-- ============================================================
-- 12) sp_nt_GetServicePoCyclesForApproval — logged-in approver's inbox.
--     Uses the flat scalar-subquery stage_order_json shape sql/82 already
--     fixed for the agreement approval screen (NOT sql/73's original
--     vw_workflow_stages-wrapped version, which double-wraps the JSON).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServicePoCyclesForApproval', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServicePoCyclesForApproval;
GO
CREATE PROCEDURE dbo.sp_nt_GetServicePoCyclesForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT spc.cycle_sno, spc.agreement_sno, sa.agreement_no,
           sm.service_name, st.service_type_code, st.service_type_name,
           k.company_name AS vendor_name,
           spc.billing_period_start, spc.qty, spc.rate_amount, spc.discount_pct, spc.gst_pct, spc.net_cost,
           sa.ceiling_amount, spc.status, spc.current_approver_id, spc.entered_by, spc.entered_at,
           (
               SELECT ws.stage_order_json
               FROM dbo.workflow_stage ws
               WHERE ws.workflow_types_id = spc.workflow_types_id AND ws.is_active = 'Y'
           ) AS stage_order_json
    FROM dbo.service_po_cycle spc
    JOIN dbo.service_agreement sa ON sa.agreement_sno = spc.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    WHERE spc.status = 'PENDING_APPROVAL' AND spc.current_approver_id = @Ecno
    ORDER BY spc.cycle_sno DESC;
END;
GO

-- ============================================================
-- 13) Sidebar registration — screens rows for the two new pages (next free
--     display_order/codes after sql/73's S17 pair; sql/81's S18 isn't live
--     but reserved in case it lands later, so this skips ahead to S19).
-- ============================================================
DECLARE @po_group_id       INT           = 2;
DECLARE @po_screen_code    VARCHAR(10)   = N'S19';
DECLARE @po_comp_img_value NVARCHAR(100) = N'ReceiptText';

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServicePoPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service Purchase Orders', @po_screen_code, 'ServicePoPage', @po_comp_img_value, @po_group_id, 27, 'Y');

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServicePoApprovalScreen')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service PO Approvals', @po_screen_code, 'ServicePoApprovalScreen', @po_comp_img_value, @po_group_id, 28, 'Y');
GO
