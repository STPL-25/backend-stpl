-- ============================================================
-- 157_statutory_due_agreement.sql   (Non_trade_Dev ONLY, re-runnable, NOT APPLIED until the user OKs it)
--
-- Request 2026-11-07: "initially statutory agreement keep it there and after approval show here for payment".
-- A Statutory agreement on the Service Agreement screen now records a recurring government / utility due - PF, ESI,
-- professional tax, property tax, electricity bill ... (the user chose this over bringing bank loans back). It goes through the
-- normal agreement approval; once approved, every due date shows on the Statutory Payments screen (grn-service sql/96) and is
-- paid there. No PR, PO or Service GRN is raised for it.
--
--   service_agreement_statutory_due   one row per Statutory agreement: the Statutory Payments tab it lands on (GST or Others),
--                                     Fixed (same amount each time) or Unfixed (amount typed on Statutory Payments when due),
--                                     the payee (statutory_payee; NULL = the tab's default payee) and a reference number
--   service_agreement.vendor_sno      now NULL-able: a statutory due has no supplier
--   service_type_master STATUTORY     switched back on. The 3 loan services stay off; 5 due services are added (codes STAT-*)
--   sp_nt_SaveServiceAgreementStatutoryDue   checks and saves the block
--   sp_nt_CreateServiceAgreement / sp_nt_UpdateServiceAgreement   Statutory: no supplier, document optional, quantity 1, no ceiling,
--                                     saves the due block instead of the old loan block (Fixed / Unfixed unchanged)
--   sp_nt_SnapshotServiceAgreementVersion   each version also keeps the due block (History, approval "what changed")
--   sp_nt_GetServiceAgreementStatutoryDues  the block for the list / approval screens (merged into the rows in Node)
--   sp_nt_GetAgreementsDueForNotification   + service_type_code / amount_type, so the reminder speaks of a due, not a PO
--
-- The 8 old loan agreements (rows in service_agreement_statutory) are left exactly as they are: still hidden on screen, and they
-- never create a due because they have no service_agreement_statutory_due row.
-- Needs grn-service sql/73 + sql/82 (statutory_payee). Error numbers 58190-58199.
-- Apply: cd backend-stpl && node sql/run_sql.mjs sql/157_statutory_due_agreement.sql      then grn-service sql/96
-- Rollback: sql/backups/statutory_due_agreement_2026-11-07/ROLLBACK.sql
-- ============================================================

IF OBJECT_ID('dbo.statutory_payee', 'U') IS NULL OR COL_LENGTH('dbo.statutory_payee', 'pay_via_portal') IS NULL
    THROW 58190, N'Run grn-service sql/73 and sql/82 first: the Statutory Payments payee list does not exist yet.', 1;
GO

-- ── 1. a statutory due has no supplier ──────────────────────────────────────
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_agreement') AND name = 'vendor_sno' AND is_nullable = 0)
    ALTER TABLE dbo.service_agreement ALTER COLUMN vendor_sno INT NULL;
GO

-- ── 2. the due block ────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.service_agreement_statutory_due', 'U') IS NULL
CREATE TABLE dbo.service_agreement_statutory_due (
    agreement_sno INT           NOT NULL PRIMARY KEY
                                CONSTRAINT FK_sa_statutory_due_agreement REFERENCES dbo.service_agreement (agreement_sno),
    kind          VARCHAR(5)    NOT NULL CONSTRAINT CK_sa_statutory_due_kind CHECK (kind IN ('GST', 'OTHER')),
    amount_type   VARCHAR(7)    NOT NULL CONSTRAINT CK_sa_statutory_due_amount_type CHECK (amount_type IN ('FIXED', 'UNFIXED')),
    payee_sno     INT           NULL,          -- statutory_payee; NULL = the default payee of the tab for the company
    reference_no  NVARCHAR(40)  NULL,          -- PF establishment code, ESI code, assessment / consumer number ... shown on the payment
    is_active     CHAR(1)       NOT NULL DEFAULT 'Y',
    created_at    DATETIME      NOT NULL DEFAULT GETDATE(),
    modified_at   DATETIME      NULL
);
GO

-- ── 3. the type and its services ────────────────────────────────────────────
UPDATE dbo.service_type_master SET is_active = 'Y', service_type_name = 'Statutory', modified_by = 'system', modified_at = GETDATE()
WHERE service_type_code = 'STATUTORY' AND is_active <> 'Y';
GO
DECLARE @stat INT = (SELECT service_type_sno FROM dbo.service_type_master WHERE service_type_code = 'STATUTORY');
IF @stat IS NULL THROW 58191, N'The STATUTORY service type is missing (it comes from sql/88).', 1;
INSERT INTO dbo.service_master (service_name, service_code, service_type_sno, default_uom_sno, description, is_active, created_by)
SELECT v.service_name, v.service_code, @stat, NULL, v.description, 'Y', 'system'
FROM (VALUES
    (N'Provident Fund (PF)',  'STAT-PF',   N'Monthly PF contribution paid to EPFO'),
    (N'ESI',                  'STAT-ESI',  N'Monthly ESI contribution paid to ESIC'),
    (N'Professional Tax',     'STAT-PT',   N'Professional tax paid to the local body'),
    (N'Property Tax',         'STAT-PROP', N'Property tax paid to the corporation / municipality'),
    (N'Electricity Bill',     'STAT-EB',   N'Electricity charges paid to the electricity board')
) v (service_name, service_code, description)
WHERE NOT EXISTS (SELECT 1 FROM dbo.service_master m WHERE m.service_code = v.service_code);
GO

-- ── 4. save the due block ───────────────────────────────────────────────────
-- @due_json: { kind: OTHER|GST, amount_type: FIXED|UNFIXED, payee_sno?, reference_no? }
CREATE OR ALTER PROCEDURE dbo.sp_nt_SaveServiceAgreementStatutoryDue
    @agreement_sno INT,
    @due_json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF @due_json IS NULL OR ISJSON(@due_json) = 0
        THROW 58192, N'A Statutory agreement needs its payment details: the Statutory Payments tab (Others or GST) and whether the amount is Fixed or Unfixed.', 1;

    DECLARE @kind  VARCHAR(10)   = UPPER(NULLIF(LTRIM(RTRIM(JSON_VALUE(@due_json, '$.kind'))), '')),
            @atype VARCHAR(10)   = UPPER(NULLIF(LTRIM(RTRIM(JSON_VALUE(@due_json, '$.amount_type'))), '')),
            @payee INT           = TRY_CAST(JSON_VALUE(@due_json, '$.payee_sno') AS INT),
            @ref   NVARCHAR(200) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@due_json, '$.reference_no'))), ''),
            @com   INT           = (SELECT com_sno FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno);

    IF @kind IS NULL OR @kind NOT IN ('OTHER', 'GST')
        THROW 58193, N'Choose where it is paid on Statutory Payments: Others or GST.', 1;
    IF @atype IS NULL OR @atype NOT IN ('FIXED', 'UNFIXED')
        THROW 58194, N'Choose Fixed (the same amount every time) or Unfixed (the amount is entered on Statutory Payments each time).', 1;
    IF LEN(@ref) > 40
        THROW 58195, N'The reference number can be at most 40 characters.', 1;
    IF @payee IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM dbo.statutory_payee y
        WHERE y.payee_sno = @payee AND y.is_active = 'Y' AND y.kind = @kind AND (y.com_sno IS NULL OR y.com_sno = @com))
        THROW 58196, N'That payee is not set up for this Statutory Payments tab and company. Pick another, or leave it empty to use the default payee.', 1;

    UPDATE dbo.service_agreement_statutory_due
    SET kind = @kind, amount_type = @atype, payee_sno = @payee, reference_no = @ref, is_active = 'Y', modified_at = GETDATE()
    WHERE agreement_sno = @agreement_sno;
    IF @@ROWCOUNT = 0
        INSERT INTO dbo.service_agreement_statutory_due (agreement_sno, kind, amount_type, payee_sno, reference_no)
        VALUES (@agreement_sno, @kind, @atype, @payee, @ref);
END;
GO

-- ── 5. create: Statutory = no supplier, optional document ───────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateServiceAgreement
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
        DECLARE @vendors_json       NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.vendors');
        DECLARE @statutory_json     NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.statutory');
        DECLARE @due_json           NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.statutory_due');

        -- sql/157: the type decides what else is required, so it is read first.
        DECLARE @service_type_code VARCHAR(30);
        SELECT @service_type_code = st.service_type_code
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';
        DECLARE @is_statutory BIT = CASE WHEN @service_type_code = 'STATUTORY' THEN 1 ELSE 0 END;

        IF @is_statutory = 1
        BEGIN
            -- a government / utility due: no supplier, one unit, no ceiling; the document is optional
            SELECT @vendor_sno = NULL, @vendors_json = NULL, @qty = 1, @rate_uom_sno = NULL, @ceiling_amount = NULL,
                   @agreement_doc_url = ISNULL(NULLIF(LTRIM(RTRIM(@agreement_doc_url)), ''), N'');
        END
        ELSE IF @vendors_json IS NOT NULL AND ISJSON(@vendors_json) = 1
            -- The first supplier in the split is the primary (service_agreement.vendor_sno).
            SET @vendor_sno = ISNULL(TRY_CAST(JSON_VALUE(@vendors_json, '$[0].vendor_sno') AS INT), @vendor_sno);

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @service_sno IS NULL OR (@vendor_sno IS NULL AND @is_statutory = 0) OR @created_by IS NULL
            THROW 58101, 'com_sno, div_sno, brn_sno, dept_sno, service_sno, at least one supplier and created_by are required.', 1;

        IF @qty IS NULL OR @qty <= 0
            THROW 58102, 'qty must be a positive quantity.', 1;

        IF @rate_amount IS NULL OR @rate_amount <= 0
            THROW 58103, 'rate_amount must be a positive amount (an approximate value is fine for an Unfixed or Statutory agreement).', 1;

        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 58104, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;

        IF @is_statutory = 0 AND (@agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = '')
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

        IF @service_type_code IS NULL OR @service_type_code NOT IN ('FIXED_RECURRING', 'VARIABLE_RECURRING', 'STATUTORY')
            THROW 58109, 'service_sno must reference an active Fixed, Unfixed or Statutory service.', 1;

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
          AND awm.entity_type = dbo.fn_resolve_approval_entity('ServiceAgreement', @service_type_code)
          AND wt.is_active = 'Y' AND awm.is_active = 'Y'
          AND EXISTS (SELECT 1 FROM dbo.workflow_stage act_ws WHERE act_ws.workflow_types_id = wt.workflow_types_id AND act_ws.is_active = 'Y');

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

        IF @is_statutory = 1
            EXEC dbo.sp_nt_SaveServiceAgreementStatutoryDue @agreement_sno = @agreement_sno, @due_json = @due_json;
        ELSE
        BEGIN
            DECLARE @total_per_cycle DECIMAL(18,2) = ROUND(@rate_amount * @qty, 2), @primary_vendor INT;
            EXEC dbo.sp_nt_SaveServiceAgreementSuppliers
                @agreement_sno = @agreement_sno, @vendors_json = @vendors_json, @fallback_vendor_sno = @vendor_sno,
                @total_amount = @total_per_cycle, @out_primary_vendor_sno = @primary_vendor OUTPUT;
            IF @primary_vendor IS NOT NULL AND @primary_vendor <> @vendor_sno
                UPDATE dbo.service_agreement SET vendor_sno = @primary_vendor WHERE agreement_sno = @agreement_sno;

            EXEC dbo.sp_nt_SaveServiceAgreementStatutory
                @agreement_sno = @agreement_sno, @service_type_code = @service_type_code, @statutory_json = @statutory_json;
        END

        DECLARE @version_no INT;
        EXEC dbo.sp_nt_SnapshotServiceAgreementVersion
            @agreement_sno = @agreement_sno, @action_type = 'SUBMITTED', @submitted_by = @created_by,
            @out_version_no = @version_no OUTPUT;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
        VALUES (@agreement_sno, 'SUBMITTED', @created_by, NULL, @version_no);

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

-- ── 6. edit / renew: same rules ─────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateServiceAgreement
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
        DECLARE @vendors_json       NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.vendors');
        DECLARE @statutory_json     NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.statutory');
        DECLARE @due_json           NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.statutory_due');

        IF @agreement_sno IS NULL OR @edited_by IS NULL
            THROW 58120, 'agreement_sno and edited_by are required.', 1;

        DECLARE @current_status CHAR(1), @old_period_end DATE;
        SELECT @current_status = status, @old_period_end = period_end_date
        FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno AND is_active = 'Y';
        IF @current_status IS NULL
            THROW 58121, 'Service agreement not found or inactive.', 1;
        IF @current_status NOT IN ('A', 'R', 'X')
            THROW 58122, 'Only an Approved, Rejected or Expired agreement can be edited or renewed (it is currently Pending approval).', 1;

        DECLARE @is_renewal BIT = CASE WHEN @current_status = 'X' THEN 1 ELSE 0 END;

        -- sql/157: the type decides what else is required, so it is read first.
        DECLARE @service_type_code VARCHAR(30);
        SELECT @service_type_code = st.service_type_code
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';
        DECLARE @is_statutory BIT = CASE WHEN @service_type_code = 'STATUTORY' THEN 1 ELSE 0 END;

        IF @is_statutory = 1
            SELECT @vendor_sno = NULL, @vendors_json = NULL, @qty = 1, @rate_uom_sno = NULL, @ceiling_amount = NULL,
                   @agreement_doc_url = ISNULL(NULLIF(LTRIM(RTRIM(@agreement_doc_url)), ''), N'');
        ELSE IF @vendors_json IS NOT NULL AND ISJSON(@vendors_json) = 1
            SET @vendor_sno = ISNULL(TRY_CAST(JSON_VALUE(@vendors_json, '$[0].vendor_sno') AS INT), @vendor_sno);

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @service_sno IS NULL
           OR (@vendor_sno IS NULL AND @is_statutory = 0)
            THROW 58123, 'com_sno, div_sno, brn_sno, dept_sno, service_sno and at least one supplier are required.', 1;
        IF @qty IS NULL OR @qty <= 0
            THROW 58124, 'qty must be a positive quantity.', 1;
        IF @rate_amount IS NULL OR @rate_amount <= 0
            THROW 58125, 'rate_amount must be a positive amount.', 1;
        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 58126, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;
        IF @is_statutory = 0 AND (@agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = '')
            THROW 58127, 'agreement_doc_url is required.', 1;

        IF @is_renewal = 1
        BEGIN
            IF @period_start_date <= @old_period_end
            BEGIN
                DECLARE @renew_msg NVARCHAR(300) = N'A renewal must start after the expired term ended (' + CONVERT(NVARCHAR(10), @old_period_end, 23) + N').';
                THROW 58133, @renew_msg, 1;
            END
            IF @period_end_date < CAST(GETDATE() AS DATE)
                THROW 58134, 'The renewed period has already ended — choose a term that runs beyond today.', 1;
        END

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

        IF @service_type_code IS NULL OR @service_type_code NOT IN ('FIXED_RECURRING', 'VARIABLE_RECURRING', 'STATUTORY')
            THROW 58135, 'service_sno must reference an active Fixed, Unfixed or Statutory service.', 1;
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
          AND awm.entity_type = dbo.fn_resolve_approval_entity('ServiceAgreement', @service_type_code)
          AND wt.is_active = 'Y' AND awm.is_active = 'Y'
          AND EXISTS (SELECT 1 FROM dbo.workflow_stage act_ws WHERE act_ws.workflow_types_id = wt.workflow_types_id AND act_ws.is_active = 'Y');
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

        IF @is_statutory = 1
            EXEC dbo.sp_nt_SaveServiceAgreementStatutoryDue @agreement_sno = @agreement_sno, @due_json = @due_json;
        ELSE
        BEGIN
            DECLARE @total_per_cycle DECIMAL(18,2) = ROUND(@rate_amount * @qty, 2), @primary_vendor INT;
            EXEC dbo.sp_nt_SaveServiceAgreementSuppliers
                @agreement_sno = @agreement_sno, @vendors_json = @vendors_json, @fallback_vendor_sno = @vendor_sno,
                @total_amount = @total_per_cycle, @out_primary_vendor_sno = @primary_vendor OUTPUT;
            IF @primary_vendor IS NOT NULL AND @primary_vendor <> @vendor_sno
                UPDATE dbo.service_agreement SET vendor_sno = @primary_vendor WHERE agreement_sno = @agreement_sno;

            EXEC dbo.sp_nt_SaveServiceAgreementStatutory
                @agreement_sno = @agreement_sno, @service_type_code = @service_type_code, @statutory_json = @statutory_json;
        END

        DECLARE @edit_action VARCHAR(20) = CASE WHEN @is_renewal = 1 THEN 'RENEWED' ELSE 'RESUBMITTED' END;
        DECLARE @version_no INT;
        EXEC dbo.sp_nt_SnapshotServiceAgreementVersion
            @agreement_sno = @agreement_sno, @action_type = @edit_action, @submitted_by = @edited_by,
            @out_version_no = @version_no OUTPUT;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
        VALUES (@agreement_sno, @edit_action, @edited_by, NULL, @version_no);

        COMMIT TRANSACTION;

        SELECT @agreement_sno AS agreement_sno, @version_no AS version_no, 'SUCCESS' AS result,
               CASE WHEN @is_renewal = 1 THEN N'Service agreement renewed and submitted for approval.'
                    ELSE N'Service agreement updated and resubmitted for approval.' END AS message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── 7. every version keeps the due block too ────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_SnapshotServiceAgreementVersion
    @agreement_sno INT,
    @action_type VARCHAR(20),
    @submitted_by VARCHAR(30),
    @submitted_at DATETIME = NULL,
    @outcome VARCHAR(10) = 'PENDING',
    @note NVARCHAR(300) = NULL,
    @out_version_no INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @terms NVARCHAR(MAX) = (
        SELECT sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
               sa.service_sno, sm.service_name, st.service_type_code, st.service_type_name,
               sa.qty, sa.rate_amount, sa.rate_uom_sno, um.uom_name AS rate_uom_name,
               sa.recurrence_cadence_sno, rc.cadence_name, sa.po_generation_day, sa.notify_days_before,
               sa.period_start_date, sa.period_end_date, sa.agreement_doc_url,
               sa.remarks, sa.terms_conditions, sa.ceiling_amount,
               (
                   SELECT v.vendor_sno, kv.company_name AS vendor_name, v.share_amount, v.share_pct
                   FROM dbo.service_agreement_vendor v
                   LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = v.vendor_sno
                   WHERE v.agreement_sno = sa.agreement_sno
                   ORDER BY v.sort_order, v.agreement_vendor_sno
                   FOR JSON PATH
               ) AS suppliers,
               JSON_QUERY((SELECT s.facility_type, s.facility_ref_no, s.sanctioned_amount, s.drawing_power,
                          s.rate_type, s.benchmark_rate_pct, s.spread_pct, s.interest_rate_pct,
                          s.benchmark_name, s.disbursed_amount, s.disbursement_date, s.interest_payment_day, s.day_count_basis
                   FROM dbo.service_agreement_statutory s
                   WHERE s.agreement_sno = sa.agreement_sno
                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS statutory,
               -- sql/157
               JSON_QUERY((SELECT d.kind, d.amount_type, d.payee_sno, y.payee_name, d.reference_no
                   FROM dbo.service_agreement_statutory_due d
                   LEFT JOIN dbo.statutory_payee y ON y.payee_sno = d.payee_sno
                   WHERE d.agreement_sno = sa.agreement_sno AND d.is_active = 'Y'
                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS statutory_due
        FROM dbo.service_agreement sa
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        LEFT JOIN dbo.uom_master um ON um.uom_sno = sa.rate_uom_sno
        LEFT JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
        WHERE sa.agreement_sno = @agreement_sno
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    IF @terms IS NULL
        THROW 58180, 'Cannot snapshot: agreement not found.', 1;

    DECLARE @version_no INT =
        ISNULL((SELECT MAX(version_no) FROM dbo.service_agreement_version WITH (UPDLOCK, HOLDLOCK) WHERE agreement_sno = @agreement_sno), 0) + 1;

    UPDATE dbo.service_agreement_version
    SET superseded_at = GETDATE()
    WHERE agreement_sno = @agreement_sno AND superseded_at IS NULL;

    INSERT INTO dbo.service_agreement_version (
        agreement_sno, version_no, action_type, outcome, period_start_date, period_end_date,
        terms_json, note, submitted_by, submitted_at
    )
    SELECT @agreement_sno, @version_no, @action_type, @outcome, sa.period_start_date, sa.period_end_date,
           @terms, @note, @submitted_by, ISNULL(@submitted_at, GETDATE())
    FROM dbo.service_agreement sa
    WHERE sa.agreement_sno = @agreement_sno;

    SET @out_version_no = @version_no;
END;
GO

-- ── 8. the due block for the list / approval screens ────────────────────────
-- Merged into the agreement rows in Node (like the signed copies), so the big list procedures stay as they are.
-- waiting_count (dues still waiting for an amount) / last_due_date come from grn-service sql/96 once it is applied (0 / NULL before).
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetServiceAgreementStatutoryDues
AS
BEGIN
    SET NOCOUNT ON;
    IF OBJECT_ID('dbo.statutory_agreement_cycle', 'U') IS NULL
        SELECT d.agreement_sno, d.kind, d.amount_type, d.payee_sno, y.payee_name, y.pay_via_portal AS payee_online, d.reference_no,
               CAST(0 AS INT) AS waiting_count, CAST(NULL AS DATE) AS last_due_date
        FROM dbo.service_agreement_statutory_due d
        LEFT JOIN dbo.statutory_payee y ON y.payee_sno = d.payee_sno
        WHERE d.is_active = 'Y';
    ELSE
        EXEC (N'SELECT d.agreement_sno, d.kind, d.amount_type, d.payee_sno, y.payee_name, y.pay_via_portal AS payee_online, d.reference_no,
                       (SELECT COUNT(*) FROM dbo.statutory_agreement_cycle c WHERE c.agreement_sno = d.agreement_sno AND c.status = ''Waiting'') AS waiting_count,
                       (SELECT MAX(c.due_date) FROM dbo.statutory_agreement_cycle c WHERE c.agreement_sno = d.agreement_sno) AS last_due_date
                FROM dbo.service_agreement_statutory_due d
                LEFT JOIN dbo.statutory_payee y ON y.payee_sno = d.payee_sno
                WHERE d.is_active = ''Y'';');
END;
GO

-- ── 9. the reminder knows a Statutory due from a PO ─────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetAgreementsDueForNotification
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @due TABLE (agreement_sno INT, due_date DATE);

    INSERT INTO @due (agreement_sno, due_date)
    SELECT sa.agreement_sno, DATEADD(DAY, sa.notify_days_before, @today)
    FROM dbo.service_agreement sa
    JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    WHERE sa.status = 'A' AND sa.is_active = 'Y' AND sa.notify_days_before > 0
      AND DATEADD(DAY, sa.notify_days_before, @today) BETWEEN sa.period_start_date AND sa.period_end_date
      AND (
            (rc.interval_unit = 'DAY' AND DATEDIFF(DAY, sa.period_start_date, DATEADD(DAY, sa.notify_days_before, @today)) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NOT NULL
             AND DAY(DATEADD(DAY, sa.notify_days_before, @today)) = CASE WHEN sa.po_generation_day > DAY(EOMONTH(DATEADD(DAY, sa.notify_days_before, @today))) THEN DAY(EOMONTH(DATEADD(DAY, sa.notify_days_before, @today))) ELSE sa.po_generation_day END
             AND DATEDIFF(MONTH, sa.period_start_date, DATEADD(DAY, sa.notify_days_before, @today)) % rc.interval_value = 0)
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NULL
             AND DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, DATEADD(DAY, sa.notify_days_before, @today)) / rc.interval_value) * rc.interval_value, sa.period_start_date) = DATEADD(DAY, sa.notify_days_before, @today))
          )
      -- sql/157: the old loan agreements are not reminded about (they have no due block)
      AND NOT EXISTS (SELECT 1 FROM dbo.service_agreement_statutory l WHERE l.agreement_sno = sa.agreement_sno)
      AND NOT EXISTS (SELECT 1 FROM dbo.service_agreement_notification_log l WHERE l.agreement_sno = sa.agreement_sno AND l.billing_period_start = DATEADD(DAY, sa.notify_days_before, @today));

    DECLARE @claimed TABLE (agreement_sno INT, due_date DATE);
    DECLARE @a_sno INT, @d_date DATE;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT agreement_sno, due_date FROM @due;
    OPEN cur;
    FETCH NEXT FROM cur INTO @a_sno, @d_date;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.service_agreement_notification_log (agreement_sno, billing_period_start, status)
            VALUES (@a_sno, @d_date, 'PENDING');
            INSERT INTO @claimed (agreement_sno, due_date) VALUES (@a_sno, @d_date);
        END TRY
        BEGIN CATCH
            -- Unique-key collision: another sweep already claimed this row. Skip it.
        END CATCH
        FETCH NEXT FROM cur INTO @a_sno, @d_date;
    END
    CLOSE cur;
    DEALLOCATE cur;

    SELECT sa.agreement_sno, sa.agreement_no, sa.created_by AS notify_ecno, sm.service_name,
           sa.rate_amount, sa.po_generation_day, sa.notify_days_before, c.due_date,
           st.service_type_code, d.amount_type AS statutory_amount_type
    FROM @claimed c
    JOIN dbo.service_agreement sa ON sa.agreement_sno = c.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.service_agreement_statutory_due d ON d.agreement_sno = sa.agreement_sno;
END;
GO
