-- ============================================================
-- service_agreement — the Fixed-Recurring service agreement entity
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : new backend-stpl/src/ServiceAgreement module
--
-- Why this is needed
-- ------------------
-- service_master (05_service_masters.sql) models the billing *pattern* for a
-- service (e.g. Rent is FIXED_RECURRING, cadence MONTHLY) but not what it
-- actually costs, for how long, for which company/division/branch/department,
-- or the contract backing it. service_agreement is that record: "for HO /
-- Finance / Chennai Branch / Admin dept, Rent is ₹100,000/month from
-- 2026-01-01 to 2026-12-31, per this uploaded PDF." See
-- backend-stpl/docs/service-agreement-approval-po-spec.md §3 for the full
-- design (agreement → approval → PR auto-fill → recurring PR → PO branch).
--
-- Shape follows sp_nt_CreateServicePO / sp_nt_ApproveServicePO
-- (07_po_service_extensions.sql) almost exactly — same workflow-resolution
-- block against workflow_types/approval_workflow_master/vw_workflow_stages,
-- same single-stage-progression approve/reject procedure — because
-- ServiceAgreement is a new entity_type on the same generic WorkFlowApproval
-- engine, not a new approval mechanism. Unlike ServicePO (which the approval
-- spec's §7 will teach to skip approval when no workflow is configured),
-- an Agreement always requires one: a rent figure that then auto-fills a
-- year of PR lines should always be reviewed by someone.
--
-- po_request_info/po_history_data has no approved_by/approved_on columns —
-- that detail lives only in the history table. service_agreement follows the
-- same convention, hence the paired service_agreement_history table below
-- (po_history_data itself predates this repo's SQL-migration convention and
-- isn't checked in anywhere, so it can't be reused directly here).
--
-- Scope of this file: the entity itself only (table, history table, entity
-- type, CRUD + approval procs). Wiring PR line auto-fill (pr_item_details.
-- agreement_sno) and the ServicePO workflow/direct branch are separate,
-- covered by the spec's §4 and §7 respectively — not yet built here.
-- ============================================================

-- ── service_agreement ───────────────────────────────────────────────────────

IF OBJECT_ID('dbo.service_agreement', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_agreement (
        agreement_sno            INT IDENTITY(1,1) PRIMARY KEY,
        agreement_no              VARCHAR(30)    NOT NULL,
        com_sno                    INT           NOT NULL,
        div_sno                    INT           NOT NULL,
        brn_sno                    INT           NOT NULL,
        dept_sno                   INT           NOT NULL,
        service_sno                INT           NOT NULL,
        vendor_sno                  INT          NULL,
        rate_amount                 DECIMAL(18,2) NOT NULL,
        rate_uom_sno                 INT          NULL,
        -- copied from service_master.recurrence_cadence at creation time; an
        -- agreement can specify its own cadence if it differs from the
        -- catalogue default (e.g. a service usually monthly but this one
        -- particular contract bills quarterly)
        recurrence_cadence            VARCHAR(20) NOT NULL,
        period_start_date              DATE       NOT NULL,
        period_end_date                 DATE      NOT NULL,
        agreement_doc_url                NVARCHAR(500) NOT NULL,
        remarks                           NVARCHAR(500) NULL,
        -- resolved at submit time against entity_type='ServiceAgreement'
        workflow_types_id                 INT      NULL,
        current_approver_id                VARCHAR(30) NULL,
        -- P=Pending, A=Approved, R=Rejected, X=Expired.
        -- 'D' (Draft) is reserved for a possible future persisted-draft path —
        -- sp_nt_CreateServiceAgreement below never inserts one; like PR
        -- (PR.repository.js#saveDraft), drafts are expected to live client-side
        -- / in Redis until submit, not as a DB row.
        status                              CHAR(1)  NOT NULL,
        is_active                            CHAR(1) NOT NULL DEFAULT 'Y',
        created_by                            VARCHAR(20) NULL,
        created_at                            DATETIME NOT NULL DEFAULT GETDATE(),
        modified_by                           VARCHAR(20) NULL,
        modified_at                           DATETIME NULL,
        CONSTRAINT UQ_service_agreement_no UNIQUE (agreement_no),
        CONSTRAINT CK_service_agreement_status CHECK (status IN ('D','P','A','R','X')),
        CONSTRAINT CK_service_agreement_period CHECK (period_end_date > period_start_date),
        CONSTRAINT FK_service_agreement_service FOREIGN KEY (service_sno)
            REFERENCES dbo.service_master (service_sno),
        CONSTRAINT FK_service_agreement_uom FOREIGN KEY (rate_uom_sno)
            REFERENCES dbo.uom_master (uom_sno),
        CONSTRAINT FK_service_agreement_vendor FOREIGN KEY (vendor_sno)
            REFERENCES dbo.kyc_basic_info (kyc_basic_info_sno)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_service_agreement_scope' AND object_id = OBJECT_ID('dbo.service_agreement'))
    CREATE INDEX IX_service_agreement_scope
        ON dbo.service_agreement (com_sno, div_sno, brn_sno, dept_sno, service_sno, status);
GO

-- ── service_agreement_history — approve/reject audit trail ─────────────────
-- Mirrors po_history_data's (action_type, status_by, comment) shape, used the
-- same way by sp_approve_service_agreement below as sp_nt_ApproveServicePO
-- uses po_history_data.

IF OBJECT_ID('dbo.service_agreement_history', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_agreement_history (
        history_sno    INT IDENTITY(1,1) PRIMARY KEY,
        agreement_sno  INT           NOT NULL,
        action_type    VARCHAR(20)   NOT NULL, -- SUBMITTED | APPROVED | REJECTED
        status_by      VARCHAR(30)   NULL,
        comment        VARCHAR(200)  NULL,
        is_active      CHAR(1)       NOT NULL DEFAULT 'Y',
        created_date   DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_service_agreement_history_agreement FOREIGN KEY (agreement_sno)
            REFERENCES dbo.service_agreement (agreement_sno)
    );
END;
GO

-- ── entity_master: register ServiceAgreement as a workflow entity_type ─────

IF NOT EXISTS (SELECT 1 FROM dbo.entity_master WHERE entity_code = 'ServiceAgreement')
    INSERT INTO dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by)
    VALUES (N'Service Agreement', N'ServiceAgreement', N'Fixed-recurring service agreement (rate, period, document) approval', 'Y', N'system');
GO

-- ============================================================
-- sp_nt_CreateServiceAgreement
-- @jsonInput: { com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno?,
--   rate_amount, rate_uom_sno?, recurrence_cadence?, period_start_date,
--   period_end_date, agreement_doc_url, remarks?, created_by }
--
-- service_sno must reference an active service whose service_type is
-- FIXED_RECURRING (this entity exists specifically for that billing pattern —
-- Variable Recurring/Vendor-Bill services aren't agreement-and-period shaped
-- the same way). recurrence_cadence defaults from service_master when omitted.
-- Always resolves and requires a workflow — see file header.
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
        DECLARE @recurrence_cadence   VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.recurrence_cadence');
        DECLARE @period_start_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date      DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url    NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks              NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @created_by           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @service_sno IS NULL OR @created_by IS NULL
            THROW 53001, 'com_sno, div_sno, brn_sno, dept_sno, service_sno and created_by are required.', 1;

        IF @rate_amount IS NULL OR @rate_amount <= 0
            THROW 53002, 'rate_amount must be a positive amount.', 1;

        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 53003, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;

        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 53004, 'agreement_doc_url is required — upload the agreement document before submitting.', 1;

        DECLARE @service_type_code VARCHAR(30), @is_recurring BIT, @default_cadence VARCHAR(20);
        SELECT @service_type_code = st.service_type_code,
               @is_recurring      = sm.is_recurring,
               @default_cadence   = sm.recurrence_cadence
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';

        IF @service_type_code IS NULL
            THROW 53005, 'Unknown or inactive service_sno.', 1;

        IF @service_type_code <> 'FIXED_RECURRING' OR ISNULL(@is_recurring, 0) = 0
            THROW 53006, 'service_sno must reference an active Fixed Recurring, recurring service.', 1;

        IF @recurrence_cadence IS NULL
            SET @recurrence_cadence = @default_cadence;

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
            rate_amount, rate_uom_sno, recurrence_cadence, period_start_date, period_end_date,
            agreement_doc_url, remarks, workflow_types_id, current_approver_id, status,
            is_active, created_by
        )
        VALUES (
            @agreement_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @service_sno, @vendor_sno,
            @rate_amount, @rate_uom_sno, @recurrence_cadence, @period_start_date, @period_end_date,
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

-- ============================================================
-- sp_nt_GetServiceAgreements — list/filter, for admin/browse screens
-- @jsonInput optional: { com_sno?, div_sno?, brn_sno?, dept_sno?, service_sno?,
--   status?, vendor_sno? }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServiceAgreements', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetServiceAgreements;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceAgreements
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL,
            @service_sno INT = NULL, @status VARCHAR(1) = NULL, @vendor_sno INT = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @com_sno     = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno     = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno     = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno    = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        SET @service_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        SET @status      = JSON_VALUE(@jsonInput, '$.status');
        SET @vendor_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    END

    SELECT
        sa.agreement_sno,
        sa.agreement_no,
        sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
        sa.service_sno,
        sm.service_name,
        st.service_type_code,
        sa.vendor_sno,
        k.company_name        AS vendor_name,
        sa.rate_amount,
        sa.rate_uom_sno,
        um.uom_name            AS rate_uom_name,
        sa.recurrence_cadence,
        sa.period_start_date,
        sa.period_end_date,
        sa.agreement_doc_url,
        sa.remarks,
        sa.workflow_types_id,
        sa.current_approver_id,
        sa.status,
        sa.created_by,
        sa.created_at
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm      ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.uom_master um      ON um.uom_sno = sa.rate_uom_sno
    LEFT JOIN dbo.kyc_basic_info k   ON k.kyc_basic_info_sno = sa.vendor_sno
    WHERE sa.is_active = 'Y'
      AND (@com_sno IS NULL OR sa.com_sno = @com_sno)
      AND (@div_sno IS NULL OR sa.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR sa.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR sa.dept_sno = @dept_sno)
      AND (@service_sno IS NULL OR sa.service_sno = @service_sno)
      AND (@status IS NULL OR sa.status = @status)
      AND (@vendor_sno IS NULL OR sa.vendor_sno = @vendor_sno)
    ORDER BY sa.agreement_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetActiveServiceAgreement — the PR-line auto-fill lookup (spec §5):
-- the single Approved, in-period agreement for an exact org scope + service.
-- @jsonInput: { com_sno, div_sno, brn_sno, dept_sno, service_sno }
--
-- If more than one Approved agreement's period happens to cover today for the
-- same scope+service (not prevented by a DB constraint — see spec's open
-- questions), the most recently created one wins. Returns zero rows when
-- there's no match; the caller (PR line auto-fill) treats that as "no active
-- agreement — block the line" per spec §5.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetActiveServiceAgreement', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetActiveServiceAgreement;
GO
CREATE PROCEDURE dbo.sp_nt_GetActiveServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno     INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
    DECLARE @div_sno     INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
    DECLARE @brn_sno     INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
    DECLARE @dept_sno    INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
    DECLARE @service_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);

    IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @service_sno IS NULL
        THROW 53009, 'com_sno, div_sno, brn_sno, dept_sno and service_sno are required.', 1;

    SELECT TOP 1
        sa.agreement_sno,
        sa.agreement_no,
        sa.rate_amount,
        sa.rate_uom_sno,
        um.uom_name AS rate_uom_name,
        sa.recurrence_cadence,
        sa.period_start_date,
        sa.period_end_date,
        sa.vendor_sno
    FROM dbo.service_agreement sa
    LEFT JOIN dbo.uom_master um ON um.uom_sno = sa.rate_uom_sno
    WHERE sa.com_sno = @com_sno AND sa.div_sno = @div_sno
      AND sa.brn_sno = @brn_sno AND sa.dept_sno = @dept_sno
      AND sa.service_sno = @service_sno
      AND sa.status = 'A' AND sa.is_active = 'Y'
      AND CAST(GETDATE() AS DATE) BETWEEN sa.period_start_date AND sa.period_end_date
    ORDER BY sa.agreement_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetServiceAgreementsForApproval — pending agreements for the logged-in
-- approver. Mirrors sp_nt_GetServicePOsForApproval's shape, including
-- stage_order_json so the frontend can round-trip approval_stages back into
-- sp_approve_service_agreement below.
-- @Ecno VARCHAR(50)
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServiceAgreementsForApproval', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetServiceAgreementsForApproval;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceAgreementsForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        sa.agreement_sno,
        sa.agreement_no,
        sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
        sa.service_sno,
        sm.service_name,
        sa.vendor_sno,
        k.company_name     AS vendor_name,
        sa.rate_amount,
        sa.rate_uom_sno,
        um.uom_name          AS rate_uom_name,
        sa.recurrence_cadence,
        sa.period_start_date,
        sa.period_end_date,
        sa.agreement_doc_url,
        sa.remarks,
        sa.workflow_types_id,
        sa.current_approver_id,
        sa.status,
        (
            SELECT ws.stage_order_json
            FROM dbo.workflow_stage ws
            WHERE ws.workflow_types_id = sa.workflow_types_id AND ws.is_active = 'Y'
        ) AS stage_order_json
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm     ON sm.service_sno = sa.service_sno
    LEFT JOIN dbo.uom_master um     ON um.uom_sno = sa.rate_uom_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = sa.vendor_sno
    WHERE sa.current_approver_id = @Ecno
      AND sa.status = 'P'
      AND sa.is_active = 'Y'
    ORDER BY sa.agreement_sno DESC;
END;
GO

-- ============================================================
-- sp_approve_service_agreement — single-stage progression, mirrors
-- sp_nt_ApproveServicePO exactly (see 07_po_service_extensions.sql).
-- @jsonInput: { agreement_sno, approved_by, comments, approval_stages, action }
-- action: 'approve' | 'reject'
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

        IF @next_current_approver IS NULL
        BEGIN
            UPDATE dbo.service_agreement SET status = 'A' WHERE agreement_sno = @agreement_sno;
        END

        DROP TABLE #approval_stages;

        SELECT
            'SUCCESS'                                      AS result,
            @agreement_sno                                 AS agreement_sno,
            @approved_by                                    AS approved_by,
            GETDATE()                                        AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE')     AS next_approver;

    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL
            DROP TABLE #approval_stages;

        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO

-- ============================================================
-- sp_nt_ExpireServiceAgreements — daily-job target (spec §3.2 / §5). Flips
-- Approved agreements past their period_end_date to Expired, so PR auto-fill
-- (sp_nt_GetActiveServiceAgreement) and the future recurring-PR job both stop
-- picking them up. No @jsonInput — scheduler calls it with no parameters.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ExpireServiceAgreements', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_ExpireServiceAgreements;
GO
CREATE PROCEDURE dbo.sp_nt_ExpireServiceAgreements
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.service_agreement
    SET status = 'X'
    WHERE status = 'A' AND period_end_date < CAST(GETDATE() AS DATE);

    SELECT @@ROWCOUNT AS expired_count;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_agreement') ORDER BY column_id;
--   SELECT name FROM sys.procedures WHERE name LIKE '%ServiceAgreement%' OR name = 'sp_approve_service_agreement';
--   SELECT * FROM dbo.entity_master WHERE entity_code = 'ServiceAgreement';
--
-- NOTE before using in anger: same setup burden as ServicePO
-- (07_po_service_extensions.sql's closing note) — sp_nt_CreateServiceAgreement
-- will THROW 53007 until an actual approval_workflow_master/workflow_types row
-- is configured with entity_type='ServiceAgreement' for each
-- (com_sno,div_sno,brn_sno,dept_sno) that needs to raise one.
--
-- Not yet built (see backend-stpl/docs/service-agreement-approval-po-spec.md):
--   - pr_item_details.agreement_sno + usp_InsertPurchaseRequest validation (§4)
--   - the ServicePO no-workflow-configured -> direct-issue branch (§7)
--   - the Node.js ServiceAgreement module (repository/service/routes/controller)
--     and document-upload endpoint wiring these procedures up
--   - the recurring-PR-generation scheduled job
-- ============================================================
