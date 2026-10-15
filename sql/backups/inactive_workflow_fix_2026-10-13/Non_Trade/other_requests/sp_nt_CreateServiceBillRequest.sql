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