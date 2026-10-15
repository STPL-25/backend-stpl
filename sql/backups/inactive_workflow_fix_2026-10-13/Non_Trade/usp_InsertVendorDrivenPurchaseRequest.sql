-- ── usp_InsertVendorDrivenPurchaseRequest: route Vendor-driven PRs through the mapping ───
CREATE     PROCEDURE dbo.usp_InsertVendorDrivenPurchaseRequest
    @jsonInput NVARCHAR(MAX),
    @pr_no     VARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ------------------------------------------------------------------
    -- 1. Parse input JSON
    -- ------------------------------------------------------------------
    DECLARE
        @com_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.com_sno') AS INT),
        @div_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.div_sno') AS INT),
        @brn_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.brn_sno') AS INT),
        @dept_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.dept_sno') AS INT),
        @reg_date           DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.req_date') AS DATE),
        @required_date      DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.required_date') AS DATE),
        @priority_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.priority_sno') AS INT),
        @purpose            NVARCHAR(500) = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.purpose'), ''),
        @vendor_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.vendor_sno') AS INT),
        @payment_cycle_days INT           = COALESCE(TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.payment_cycle_days') AS INT), 15),
        @attachment         NVARCHAR(500) = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.attachment'), ''),
        @created_by         VARCHAR(20)   = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.created_by'), ''),
        @items              NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items'),

        @workflow_types_id  INT,
        @workflow_id        INT,
        @first_approver     VARCHAR(20),
        @pr_basic_sno       INT,
        @financial_year     VARCHAR(10),
        @sequence_number    INT,
        @items_inserted     INT;

    DECLARE @insertedItems TABLE
    (
        pr_item_sno    INT,
        item_rate      DECIMAL(18,4),
        gst_pct        DECIMAL(5,2),
        discount_pct   DECIMAL(5,2),
        taxable_amount DECIMAL(18,2),
        gst_amount     DECIMAL(18,2)
    );

    -- ------------------------------------------------------------------
    -- 2. Validate input
    -- ------------------------------------------------------------------
    IF ISJSON(@jsonInput) <> 1
        THROW 59001, 'Invalid vendor-driven requisition payload.', 1;

    IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
       OR @reg_date IS NULL OR @required_date IS NULL OR @priority_sno IS NULL
       OR @vendor_sno IS NULL OR @created_by IS NULL
        THROW 59002, 'Company, division, branch, department, dates, priority, supplier and creator are required.', 1;

    IF @payment_cycle_days < 1 OR @payment_cycle_days > 365
        THROW 59003, 'payment_cycle_days must be between 1 and 365.', 1;

    IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
        THROW 59004, 'At least one vendor-driven item is required.', 1;

    IF @attachment IS NULL
        THROW 59009, 'A verification document (bill/receipt) for the requisition is required.', 1;

    IF EXISTS (
        SELECT 1
        FROM OPENJSON(@items)
        WHERE TRY_CAST(JSON_VALUE(value, '$.prod_sno') AS INT) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.unit_sno') AS INT) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)) <= 0
           OR TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)) < 0
           OR (
                JSON_VALUE(value, '$.discount_pct') IS NOT NULL
                AND (
                    TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)) IS NULL
                    OR TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)) < 0
                    OR TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)) > 100
                )
              )
    )
        THROW 59005, 'Every vendor-driven item requires product, unit, positive quantity, rate, and (if present) a discount_pct between 0 and 100.', 1;

    -- ------------------------------------------------------------------
    -- 3. Resolve approval workflow
    -- ------------------------------------------------------------------
    SELECT
        @workflow_id       = wt.workflow_id,
        @workflow_types_id = wt.workflow_types_id
    FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE wt.com_sno  = @com_sno
      AND wt.div_sno  = @div_sno
      AND wt.brn_sno  = @brn_sno
      AND wt.dept_sno = @dept_sno
      AND awm.entity_type = dbo.fn_resolve_approval_entity('PurchaseRequisition', 'VENDOR_DRIVEN');

    IF @workflow_types_id IS NULL
        THROW 59006, 'No VendorDrivenPurchaseRequisition workflow is configured for this organisation scope.', 1;

    SELECT @first_approver = JSON_VALUE(stage_member.value, '$.approver_ecno')
    FROM dbo.vw_workflow_stages ws
    CROSS APPLY OPENJSON(ws.stages_json) stage_group
    CROSS APPLY OPENJSON(JSON_VALUE(stage_group.value, '$.stage_order_json')) stage_member
    WHERE ws.workflow_types_id = @workflow_types_id
      AND stage_group.[key]  = '0'
      AND stage_member.[key] = '0';

    IF @first_approver IS NULL
        THROW 59007, 'The VendorDrivenPurchaseRequisition workflow has no first approver.', 1;

    -- ------------------------------------------------------------------
    -- 4. Create the requisition
    -- ------------------------------------------------------------------
    BEGIN TRANSACTION;
    BEGIN TRY

        SET @financial_year = dbo.fn_GetFinancialYear(GETDATE());

        SELECT @sequence_number = ISNULL(MAX(TRY_CAST(RIGHT(pr_no, 4) AS INT)), 0) + 1
        FROM dbo.pr_basic_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE 'VPR' + @financial_year + '-%';

        SET @pr_no = 'VPR' + @financial_year + '-' + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);

        INSERT INTO dbo.pr_basic_info
        (
            pr_no, com_sno, div_sno, brn_sno, dept_sno, reg_date, required_date,
            priority_sno, purpose, request_mode, vendor_sno, payment_cycle_days,
            is_active, created_by, created_date, workflow_types_id, current_approver_id, status
        )
        VALUES
        (
            @pr_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @reg_date, @required_date,
            @priority_sno, @purpose, 'VENDOR_DRIVEN', @vendor_sno, @payment_cycle_days,
            'Y', @created_by, GETDATE(), @workflow_types_id, @first_approver, 'P'
        );

        SET @pr_basic_sno = SCOPE_IDENTITY();

        INSERT INTO dbo.pr_item_details
        (
            pr_no, pr_basic_sno, prod_sno, qty, unit, est_cost, total_cost,
            remarks, specification, item_type, is_active,
            created_by, created_date, item_description, item_rate, gst_pct,
            discount_pct, taxable_amount, gst_amount
        )
        OUTPUT
            inserted.pr_item_sno, inserted.item_rate, inserted.gst_pct,
            inserted.discount_pct, inserted.taxable_amount, inserted.gst_amount
        INTO @insertedItems
        SELECT
            @pr_no,
            @pr_basic_sno,
            TRY_CAST(JSON_VALUE(value, '$.prod_sno') AS INT),
            TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)),
            TRY_CAST(JSON_VALUE(value, '$.unit_sno') AS INT),
            TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
            t.taxable_amount + g2.gst_amount,
            NULLIF(JSON_VALUE(value, '$.remarks'), ''),
            NULLIF(JSON_VALUE(value, '$.specification'), ''),
            'vendor_driven',
            'Y',
            @created_by,
            GETDATE(),
            NULLIF(JSON_VALUE(value, '$.prod_name'), ''),
            TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
            base.gst_pct_val,
            base.disc_pct,
            t.taxable_amount,
            g2.gst_amount
        FROM OPENJSON(@items)
        CROSS APPLY (
            SELECT
                gross       = TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4))
                              * TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
                disc_pct    = COALESCE(TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)), 0),
                gst_pct_val = COALESCE(TRY_CAST(JSON_VALUE(value, '$.gst_pct') AS DECIMAL(5,2)), 0)
        ) base
        CROSS APPLY (
            SELECT taxable_amount = ROUND(base.gross * (1 - base.disc_pct / 100), 2)
        ) t
        CROSS APPLY (
            SELECT gst_amount = ROUND(t.taxable_amount * base.gst_pct_val / 100, 2)
        ) g2;

        SET @items_inserted = @@ROWCOUNT;
        IF @items_inserted = 0
            THROW 59008, 'No vendor-driven items were inserted.', 1;

        INSERT INTO dbo.pr_vendor_driven_info (pr_basic_sno, vendor_sno, payment_cycle_days, attachment, created_by, created_date)
        VALUES (@pr_basic_sno, @vendor_sno, @payment_cycle_days, @attachment, @created_by, GETDATE());

        INSERT INTO dbo.pr_vendor_driven_item_details (pr_item_sno, item_rate, gst_pct, discount_pct, taxable_amount, gst_amount)
        SELECT pr_item_sno, item_rate, gst_pct, discount_pct, taxable_amount, gst_amount
        FROM @insertedItems;

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    -- ------------------------------------------------------------------
    -- 5. Return result
    -- ------------------------------------------------------------------
    SELECT
        @pr_basic_sno   AS pr_basic_sno,
        @pr_no          AS pr_no,
        @items_inserted AS items_inserted,
        'SUCCESS'       AS result;

END;