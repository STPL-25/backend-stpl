-- ============================================================
-- Service Bill Request — real line items (qty/service/amount per row)
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Why this is needed
-- ------------------
-- service_bill_request was header-only: one invoice_amount DECIMAL(18,2),
-- no breakdown. On approval, sp_nt_ApproveServiceBillRequest built a single
-- SYNTHETIC PO line (qty hardcoded to 1, the whole invoice_amount as
-- unit_price) — the generated PO never carried real items. User explicitly
-- asked for real qty/items/amount entry at bill-submission time, mirroring
-- how Service Entry (grn-service/sql/12_service_entry.sql) and the regular
-- ServicePO items already work.
--
-- New table service_bill_request_item_details mirrors
-- service_entry_item_details's shape. service_bill_request.invoice_amount
-- stays as a header rollup (SUM of items) rather than being removed — every
-- existing read of that column (ceiling-tolerance check, list screens)
-- keeps working unchanged.
--
-- sp_nt_DirectIssueServicePO gets an items-array capability ADDITIVE to its
-- existing single-flat-item shape: when @jsonInput.items is present and
-- non-empty, it inserts one po_item_details row per array entry instead of
-- the old single hardcoded line. sp_nt_IssueRecurringServicePOCycle (the
-- Fixed-Recurring cycle issuer) is UNCHANGED and keeps sending the old flat
-- shape — this is purely additive, not a breaking change to that caller.
-- ============================================================

IF OBJECT_ID('dbo.service_bill_request_item_details', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_bill_request_item_details (
        bill_request_item_sno INT IDENTITY(1,1) PRIMARY KEY,
        bill_request_sno       INT           NOT NULL,
        service_sno              INT           NULL,
        qty                        DECIMAL(18,4) NOT NULL DEFAULT 1,
        uom_sno                     INT           NULL,
        unit_price                   DECIMAL(18,2) NOT NULL DEFAULT 0,
        amount                         DECIMAL(18,2) NOT NULL DEFAULT 0,
        remarks                         VARCHAR(500)  NULL,
        is_active                        CHAR(1)       NOT NULL DEFAULT 'Y',
        created_by                        VARCHAR(20)   NULL,
        created_date                       DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_service_bill_request_item_details_header
            FOREIGN KEY (bill_request_sno) REFERENCES dbo.service_bill_request (bill_request_sno)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_service_bill_request_item_details_header' AND object_id = OBJECT_ID('dbo.service_bill_request_item_details'))
    CREATE INDEX IX_service_bill_request_item_details_header ON dbo.service_bill_request_item_details (bill_request_sno);
GO

-- ============================================================
-- sp_nt_DirectIssueServicePO v2 — additive items-array support
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
        DECLARE @items             NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');
        DECLARE @has_items         BIT           = CASE WHEN @items IS NOT NULL AND EXISTS (SELECT 1 FROM OPENJSON(@items)) THEN 1 ELSE 0 END;

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @vendor_sno IS NULL
            THROW 57001, 'com_sno, div_sno, brn_sno, dept_sno and vendor_sno are required.', 1;

        -- Single-item shape (unchanged callers, e.g. sp_nt_IssueRecurringServicePOCycle)
        -- still needs service_sno/unit_price when no items array is given.
        IF @has_items = 0 AND (@service_sno IS NULL OR @unit_price IS NULL)
            THROW 57001, 'service_sno and unit_price are required when no items array is supplied.', 1;

        IF @pr_basic_sno IS NULL AND @is_retrospective = 0
            THROW 57002, 'pr_basic_sno is required unless is_retrospective is set.', 1;

        BEGIN TRANSACTION;

        DECLARE @po_year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @po_seq  INT;
        SELECT @po_seq = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
        FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
        WHERE po_df_no LIKE 'SVO-' + @po_year + '-%';
        DECLARE @po_no VARCHAR(50) = 'SVO-' + @po_year + '-' + RIGHT('0000' + CAST(@po_seq AS VARCHAR(4)), 4);

        -- service_type_sno: resolved from the first item's service_sno when
        -- an items array is given, else from the single @service_sno —
        -- same "service_type_sno on the PO header" convention as
        -- sp_nt_CreateServicePO already uses.
        DECLARE @header_service_sno INT = @service_sno;
        IF @has_items = 1 AND @header_service_sno IS NULL
            SELECT TOP 1 @header_service_sno = TRY_CAST(JSON_VALUE(value, '$.service_sno') AS INT)
            FROM OPENJSON(@items) ORDER BY [key];

        DECLARE @service_type_sno INT;
        SELECT @service_type_sno = service_type_sno FROM dbo.service_master WHERE service_sno = @header_service_sno AND is_active = 'Y';

        IF @service_type_sno IS NULL
            THROW 57003, 'Unknown or inactive service_sno.', 1;

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

        IF @has_items = 1
        BEGIN
            INSERT INTO dbo.po_item_details (
                po_basic_sno, pr_item_sno, service_sno, prod_name, specification,
                qty, unit, unit_name, agreed_unit_price, total_cost, discount_pct, tax_pct, net_cost,
                remarks, po_section, created_by, created_date, is_active
            )
            SELECT
                @po_basic_sno,
                TRY_CAST(JSON_VALUE(j.value, '$.pr_item_sno') AS INT),
                TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT),
                sm.service_name,
                ISNULL(JSON_VALUE(j.value, '$.specification'), ''),
                ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 1),
                TRY_CAST(JSON_VALUE(j.value, '$.uom_sno') AS INT),
                um.uom_name,
                TRY_CAST(JSON_VALUE(j.value, '$.unit_price') AS DECIMAL(18,4)),
                ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 1) * ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.unit_price') AS DECIMAL(18,4)), 0),
                0, 0,
                ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 1) * ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.unit_price') AS DECIMAL(18,4)), 0),
                JSON_VALUE(j.value, '$.remarks'), 'SERVICE',
                @issued_by, GETDATE(), '1'
            FROM OPENJSON(@items) j
            LEFT JOIN dbo.service_master sm ON sm.service_sno = TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT)
            LEFT JOIN dbo.uom_master um     ON um.uom_sno = TRY_CAST(JSON_VALUE(j.value, '$.uom_sno') AS INT);
        END
        ELSE
        BEGIN
            DECLARE @net_cost DECIMAL(18,4) = @qty * @unit_price;
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
        END

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
-- sp_nt_CreateServiceBillRequest v2 — real items[], invoice_amount becomes
-- a computed rollup of SUM(qty*unit_price) instead of a client-supplied value.
-- @jsonInput: { agreement_sno, billing_period_start, billing_period_end,
--   invoice_no?, invoice_date?, invoice_doc_url, remarks?, created_by,
--   items: [{ service_sno, qty, unit_price, uom_sno?, remarks? }] }
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
        DECLARE @invoice_doc_url      NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.invoice_doc_url');
        DECLARE @remarks              NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @created_by           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
        DECLARE @items                NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');

        IF @agreement_sno IS NULL OR @created_by IS NULL
            THROW 56010, 'agreement_sno and created_by are required.', 1;

        IF @billing_period_start IS NULL OR @billing_period_end IS NULL OR @billing_period_end < @billing_period_start
            THROW 56011, 'billing_period_start and billing_period_end are required, and the period must not end before it starts.', 1;

        IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
            THROW 56012, 'At least one item (service, qty, unit_price) is required.', 1;

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

        DECLARE @lineItems TABLE (service_sno INT, qty DECIMAL(18,4), uom_sno INT, unit_price DECIMAL(18,2), amount DECIMAL(18,2), remarks VARCHAR(500));
        INSERT INTO @lineItems (service_sno, qty, uom_sno, unit_price, amount, remarks)
        SELECT
            TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 1),
            TRY_CAST(JSON_VALUE(j.value, '$.uom_sno') AS INT),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.unit_price') AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 1) * ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.unit_price') AS DECIMAL(18,2)), 0),
            JSON_VALUE(j.value, '$.remarks')
        FROM OPENJSON(@items) j;

        IF EXISTS (SELECT 1 FROM @lineItems WHERE unit_price <= 0 OR qty <= 0)
            THROW 56021, 'Every item requires a positive qty and unit_price.', 1;

        DECLARE @invoice_amount DECIMAL(18,2);
        SELECT @invoice_amount = SUM(amount) FROM @lineItems;

        IF @ceiling_amount IS NOT NULL AND @invoice_amount > @ceiling_amount * (1 + ISNULL(@variance_tolerance_pct, 0) / 100.0)
            THROW 56018, 'Total item amount exceeds the ceiling agreement''s authorized ceiling plus its variance tolerance.', 1;

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

        INSERT INTO dbo.service_bill_request_item_details (bill_request_sno, service_sno, qty, uom_sno, unit_price, amount, remarks, created_by)
        SELECT @bill_request_sno, service_sno, qty, uom_sno, unit_price, amount, remarks, @created_by
        FROM @lineItems;

        INSERT INTO dbo.service_bill_request_history (bill_request_sno, action_type, status_by, comment, is_active)
        VALUES (@bill_request_sno, 'SUBMITTED', @created_by, NULL, 'Y');

        COMMIT TRANSACTION;

        SELECT
            @bill_request_sno AS bill_request_sno,
            @request_no       AS request_no,
            @invoice_amount   AS invoice_amount,
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
-- sp_nt_ApproveServiceBillRequest v2 — auto-issued PO now carries the real
-- items from service_bill_request_item_details instead of one synthetic
-- line. Also returns vendor_sno so the Node layer can trigger the supplier
-- email without an extra query.
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

        DECLARE @auto_po_result VARCHAR(30) = NULL, @auto_po_basic_sno INT = NULL, @auto_po_no VARCHAR(50) = NULL,
                @auto_po_vendor_sno INT = NULL;

        IF @next_current_approver IS NULL
        BEGIN
            UPDATE dbo.service_bill_request SET status = 'A' WHERE bill_request_sno = @bill_request_sno;

            DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @service_sno INT, @vendor_sno INT,
                    @billing_period_start DATE, @billing_period_end DATE,
                    @ceiling_amount DECIMAL(18,2), @variance_tolerance_pct DECIMAL(5,2), @agreement_sno INT;

            SELECT @com_sno = sbr.com_sno, @div_sno = sbr.div_sno, @brn_sno = sbr.brn_sno, @dept_sno = sbr.dept_sno,
                   @service_sno = sbr.service_sno, @vendor_sno = sbr.vendor_sno,
                   @billing_period_start = sbr.billing_period_start, @billing_period_end = sbr.billing_period_end,
                   @agreement_sno = sbr.agreement_sno, @ceiling_amount = sa.ceiling_amount,
                   @variance_tolerance_pct = sa.variance_tolerance_pct
            FROM dbo.service_bill_request sbr
            JOIN dbo.service_agreement sa ON sa.agreement_sno = sbr.agreement_sno
            WHERE sbr.bill_request_sno = @bill_request_sno;

            SET @auto_po_vendor_sno = @vendor_sno;

            DECLARE @itemsJson NVARCHAR(MAX) = (
                SELECT service_sno, qty, uom_sno, unit_price, remarks
                FROM dbo.service_bill_request_item_details
                WHERE bill_request_sno = @bill_request_sno AND is_active = 'Y'
                FOR JSON PATH
            );

            DECLARE @poJson NVARCHAR(MAX) = (
                SELECT @com_sno AS com_sno, @div_sno AS div_sno, @brn_sno AS brn_sno, @dept_sno AS dept_sno,
                       @vendor_sno AS vendor_sno, 1 AS is_retrospective,
                       JSON_QUERY(@itemsJson) AS items, 'RECURRING' AS po_type,
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
                -- Do not fail the approval itself — see file header of the
                -- original sp_nt_ApproveServiceBillRequest (23_..._redesign.sql).
                -- po_basic_sno stays NULL; retryable via
                -- sp_nt_RetryServiceBillRequestPOIssue.
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
            @auto_po_no                                          AS auto_po_no,
            @auto_po_vendor_sno                                   AS auto_po_vendor_sno;

    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL
            DROP TABLE #approval_stages;

        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO

-- ============================================================
-- sp_nt_RetryServiceBillRequestPOIssue v2 — same items-array approach
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
            @billing_period_start DATE, @billing_period_end DATE,
            @ceiling_amount DECIMAL(18,2), @variance_tolerance_pct DECIMAL(5,2), @agreement_sno INT;

    SELECT @com_sno = sbr.com_sno, @div_sno = sbr.div_sno, @brn_sno = sbr.brn_sno, @dept_sno = sbr.dept_sno,
           @service_sno = sbr.service_sno, @vendor_sno = sbr.vendor_sno,
           @billing_period_start = sbr.billing_period_start, @billing_period_end = sbr.billing_period_end,
           @agreement_sno = sbr.agreement_sno, @ceiling_amount = sa.ceiling_amount,
           @variance_tolerance_pct = sa.variance_tolerance_pct
    FROM dbo.service_bill_request sbr
    JOIN dbo.service_agreement sa ON sa.agreement_sno = sbr.agreement_sno
    WHERE sbr.bill_request_sno = @bill_request_sno;

    DECLARE @itemsJson NVARCHAR(MAX) = (
        SELECT service_sno, qty, uom_sno, unit_price, remarks
        FROM dbo.service_bill_request_item_details
        WHERE bill_request_sno = @bill_request_sno AND is_active = 'Y'
        FOR JSON PATH
    );

    DECLARE @poJson NVARCHAR(MAX) = (
        SELECT @com_sno AS com_sno, @div_sno AS div_sno, @brn_sno AS brn_sno, @dept_sno AS dept_sno,
               @vendor_sno AS vendor_sno, 1 AS is_retrospective,
               JSON_QUERY(@itemsJson) AS items, 'RECURRING' AS po_type,
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

    SELECT @out_result AS result, @bill_request_sno AS bill_request_sno, @out_po_basic_sno AS po_basic_sno, @out_po_no AS po_no, @vendor_sno AS vendor_sno;
END;
GO

-- ============================================================
-- sp_nt_GetServiceBillRequests v2 — adds an items[] subselect
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
        sbr.po_basic_sno, po.po_df_no AS po_no, po.po_pdf_url,
        sbr.created_by, sbr.created_at,
        (
            SELECT h.status_by AS approved_by, h.created_date AS approved_at
            FROM dbo.service_bill_request_history h
            WHERE h.bill_request_sno = sbr.bill_request_sno AND h.action_type = 'APPROVED' AND h.is_active = 'Y'
            ORDER BY h.history_sno DESC
            FOR JSON PATH
        ) AS approval_history,
        (
            SELECT bri.bill_request_item_sno, bri.service_sno, sm2.service_name, bri.qty, bri.uom_sno, um.uom_name,
                   bri.unit_price, bri.amount, bri.remarks
            FROM dbo.service_bill_request_item_details bri
            LEFT JOIN dbo.service_master sm2 ON sm2.service_sno = bri.service_sno
            LEFT JOIN dbo.uom_master um       ON um.uom_sno = bri.uom_sno
            WHERE bri.bill_request_sno = sbr.bill_request_sno AND bri.is_active = 'Y'
            FOR JSON PATH
        ) AS items
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
-- sp_nt_GetServiceBillRequestsForApproval v2 — adds items[] + created_by
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
        sbr.created_by, sbr.created_at,
        (
            SELECT ws.stage_order_json
            FROM dbo.workflow_stage ws
            WHERE ws.workflow_types_id = sbr.workflow_types_id AND ws.is_active = 'Y'
        ) AS stage_order_json,
        (
            SELECT bri.bill_request_item_sno, bri.service_sno, sm2.service_name, bri.qty, bri.uom_sno, um.uom_name,
                   bri.unit_price, bri.amount, bri.remarks
            FROM dbo.service_bill_request_item_details bri
            LEFT JOIN dbo.service_master sm2 ON sm2.service_sno = bri.service_sno
            LEFT JOIN dbo.uom_master um       ON um.uom_sno = bri.uom_sno
            WHERE bri.bill_request_sno = sbr.bill_request_sno AND bri.is_active = 'Y'
            FOR JSON PATH
        ) AS items
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
--   SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_bill_request_item_details');
--   SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.sp_nt_DirectIssueServicePO')) LIKE '%has_items%'; -- should be 1
-- ============================================================
