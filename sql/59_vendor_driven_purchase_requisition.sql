-- ============================================================
-- Vendor-driven Purchase Requisition
-- Database: Non_Trade (MSSQL)
--
-- Adds a supplier-first purchase flow without changing usp_InsertPurchaseRequest
-- or the normal PurchaseRequisition workflow. Vendor-driven requests have a
-- dedicated workflow entity, mandatory proof per line, agreed rate, GST, and
-- a direct PO path after their final approval.
-- ============================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.pr_basic_info') AND name = 'request_mode'
)
    ALTER TABLE dbo.pr_basic_info
        ADD request_mode VARCHAR(30) NOT NULL
            CONSTRAINT DF_pr_basic_info_request_mode DEFAULT 'NORMAL';
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.pr_basic_info') AND name = 'vendor_sno'
)
    ALTER TABLE dbo.pr_basic_info ADD vendor_sno INT NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.pr_basic_info') AND name = 'payment_cycle_days'
)
    ALTER TABLE dbo.pr_basic_info ADD payment_cycle_days INT NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.pr_item_details') AND name = 'item_description'
)
    ALTER TABLE dbo.pr_item_details ADD item_description NVARCHAR(500) NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.pr_item_details') AND name = 'item_rate'
)
    ALTER TABLE dbo.pr_item_details ADD item_rate DECIMAL(18,4) NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.pr_item_details') AND name = 'gst_pct'
)
    ALTER TABLE dbo.pr_item_details ADD gst_pct DECIMAL(5,2) NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.pr_item_details') AND name = 'taxable_amount'
)
    ALTER TABLE dbo.pr_item_details ADD taxable_amount DECIMAL(18,2) NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.pr_item_details') AND name = 'gst_amount'
)
    ALTER TABLE dbo.pr_item_details ADD gst_amount DECIMAL(18,2) NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.pr_basic_info') AND name = 'IX_pr_basic_info_vendor_mode'
)
    CREATE INDEX IX_pr_basic_info_vendor_mode
        ON dbo.pr_basic_info (request_mode, vendor_sno, status);
GO

IF NOT EXISTS (
    SELECT 1 FROM dbo.entity_master WHERE entity_code = 'VendorDrivenPurchaseRequisition'
)
    INSERT INTO dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by)
    VALUES (
        N'Vendor Driven Purchase Requisition',
        N'VendorDrivenPurchaseRequisition',
        N'Supplier-first requisitions with commercial values and verification documents.',
        'Y',
        N'system'
    );
GO

-- ============================================================
-- usp_InsertVendorDrivenPurchaseRequest
-- @jsonInput:
-- {
--   basicInfo: { com_sno, div_sno, brn_sno, dept_sno, req_date,
--     required_date, priority_sno, purpose, vendor_sno, payment_cycle_days,
--     created_by },
--   items: [{ prod_sno, qty, unit_sno, rate, gst_pct, remarks,
--     item_attachment }]
-- }
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_InsertVendorDrivenPurchaseRequest
    @jsonInput NVARCHAR(MAX),
    @pr_no VARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @com_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.com_sno') AS INT),
        @div_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.div_sno') AS INT),
        @brn_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.brn_sno') AS INT),
        @dept_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.dept_sno') AS INT),
        @reg_date DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.req_date') AS DATE),
        @required_date DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.required_date') AS DATE),
        @priority_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.priority_sno') AS INT),
        @purpose NVARCHAR(500) = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.purpose'), ''),
        @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.vendor_sno') AS INT),
        @payment_cycle_days INT = COALESCE(TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.payment_cycle_days') AS INT), 15),
        @created_by VARCHAR(20) = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.created_by'), ''),
        @items NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items'),
        @workflow_types_id INT,
        @workflow_id INT,
        @first_approver VARCHAR(20),
        @pr_basic_sno INT,
        @financial_year VARCHAR(10),
        @sequence_number INT,
        @items_inserted INT;

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

    IF EXISTS (
        SELECT 1
        FROM OPENJSON(@items)
        WHERE TRY_CAST(JSON_VALUE(value, '$.prod_sno') AS INT) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.unit_sno') AS INT) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)) <= 0
           OR TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)) < 0
           OR NULLIF(JSON_VALUE(value, '$.item_attachment'), '') IS NULL
    )
        THROW 59005, 'Every vendor-driven item requires product, unit, positive quantity, rate and verification document.', 1;

    SELECT
        @workflow_id = wt.workflow_id,
        @workflow_types_id = wt.workflow_types_id
    FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE wt.com_sno = @com_sno
      AND wt.div_sno = @div_sno
      AND wt.brn_sno = @brn_sno
      AND wt.dept_sno = @dept_sno
      AND awm.entity_type = 'VendorDrivenPurchaseRequisition';

    IF @workflow_types_id IS NULL
        THROW 59006, 'No VendorDrivenPurchaseRequisition workflow is configured for this organisation scope.', 1;

    SELECT @first_approver = JSON_VALUE(stage_member.value, '$.approver_ecno')
    FROM dbo.vw_workflow_stages ws
    CROSS APPLY OPENJSON(ws.stages_json) stage_group
    CROSS APPLY OPENJSON(JSON_VALUE(stage_group.value, '$.stage_order_json')) stage_member
    WHERE ws.workflow_types_id = @workflow_types_id
      AND stage_group.[key] = '0'
      AND stage_member.[key] = '0';

    IF @first_approver IS NULL
        THROW 59007, 'The VendorDrivenPurchaseRequisition workflow has no first approver.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        SET @financial_year = dbo.fn_GetFinancialYear(GETDATE());

        SELECT @sequence_number = ISNULL(MAX(TRY_CAST(RIGHT(pr_no, 4) AS INT)), 0) + 1
        FROM dbo.pr_basic_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE 'VPR' + @financial_year + '-%';

        SET @pr_no = 'VPR' + @financial_year + '-' + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);

        INSERT INTO dbo.pr_basic_info (
            pr_no, com_sno, div_sno, brn_sno, dept_sno, reg_date, required_date,
            priority_sno, purpose, request_mode, vendor_sno, payment_cycle_days,
            is_active, created_by, created_date, workflow_types_id, current_approver_id, status
        )
        VALUES (
            @pr_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @reg_date, @required_date,
            @priority_sno, @purpose, 'VENDOR_DRIVEN', @vendor_sno, @payment_cycle_days,
            'Y', @created_by, GETDATE(), @workflow_types_id, @first_approver, 'P'
        );

        SET @pr_basic_sno = SCOPE_IDENTITY();

        INSERT INTO dbo.pr_item_details (
            pr_no, pr_basic_sno, prod_sno, qty, unit, est_cost, total_cost,
            remarks, specification, pr_prod_file, item_type, is_active,
            created_by, created_date, item_description, item_rate, gst_pct,
            taxable_amount, gst_amount
        )
        SELECT
            @pr_no,
            @pr_basic_sno,
            TRY_CAST(JSON_VALUE(value, '$.prod_sno') AS INT),
            TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)),
            TRY_CAST(JSON_VALUE(value, '$.unit_sno') AS INT),
            TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
            ROUND(
                TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4))
                * TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4))
                * (1 + COALESCE(TRY_CAST(JSON_VALUE(value, '$.gst_pct') AS DECIMAL(5,2)), 0) / 100),
                2
            ),
            NULLIF(JSON_VALUE(value, '$.remarks'), ''),
            NULLIF(JSON_VALUE(value, '$.specification'), ''),
            NULLIF(JSON_VALUE(value, '$.item_attachment'), ''),
            'vendor_driven',
            'Y',
            @created_by,
            GETDATE(),
            NULLIF(JSON_VALUE(value, '$.prod_name'), ''),
            TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
            COALESCE(TRY_CAST(JSON_VALUE(value, '$.gst_pct') AS DECIMAL(5,2)), 0),
            ROUND(
                TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4))
                * TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
                2
            ),
            ROUND(
                TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4))
                * TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4))
                * COALESCE(TRY_CAST(JSON_VALUE(value, '$.gst_pct') AS DECIMAL(5,2)), 0) / 100,
                2
            )
        FROM OPENJSON(@items);

        SET @items_inserted = @@ROWCOUNT;
        IF @items_inserted = 0
            THROW 59008, 'No vendor-driven items were inserted.', 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT
        @pr_basic_sno AS pr_basic_sno,
        @pr_no AS pr_no,
        @items_inserted AS items_inserted,
        'SUCCESS' AS result;
END;
GO

-- Approved vendor-driven PRs are deliberately separate from the regular
-- quotation queue. They retain the exact shape expected by the purchase-team
-- sidebar, but have one preselected supplier and no quotation step.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetVendorDrivenApprovedPRs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.pr_basic_sno,
        p.pr_no,
        p.com_sno,
        c.com_name,
        p.div_sno,
        dv.div_name,
        p.brn_sno,
        br.brn_name,
        p.dept_sno,
        dp.dept_name,
        CONVERT(VARCHAR(10), p.reg_date, 120) AS reg_date,
        CONVERT(VARCHAR(10), p.required_date, 120) AS required_date,
        p.priority_sno,
        pm.priority_name,
        p.purpose,
        p.request_mode,
        p.vendor_sno,
        k.company_name AS vendor_name,
        p.payment_cycle_days,
        p.created_by,
        p.created_date,
        p.status,
        (
            SELECT
                pid.pr_item_sno,
                pid.prod_sno,
                COALESCE(pid.item_description, product.prod_name) AS prod_name,
                pid.qty,
                pid.unit,
                uom.uom_name AS unit_name,
                pid.item_rate AS rate,
                pid.gst_pct,
                pid.taxable_amount,
                pid.gst_amount,
                pid.total_cost,
                pid.remarks,
                pid.pr_prod_file AS item_attachment
            FROM dbo.pr_item_details pid
            LEFT JOIN dbo.product_master product ON product.prod_sno = pid.prod_sno
            LEFT JOIN dbo.uom_master uom ON uom.uom_sno = pid.unit
            WHERE pid.pr_basic_sno = p.pr_basic_sno
              AND pid.is_active = 'Y'
            FOR JSON PATH
        ) AS pr_item_details
    FROM dbo.pr_basic_info p
    LEFT JOIN dbo.company_master c ON c.com_sno = p.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = p.div_sno
    LEFT JOIN dbo.branch_master br ON br.brn_sno = p.brn_sno
    LEFT JOIN dbo.dept_master dp ON dp.dept_sno = p.dept_sno
    LEFT JOIN dbo.priority_master pm ON pm.priority_sno = p.priority_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = p.vendor_sno
    WHERE p.is_active = 'Y'
      AND p.request_mode = 'VENDOR_DRIVEN'
      AND p.status = 'A'
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.po_request_info po
          WHERE po.pr_basic_sno = p.pr_basic_sno
            AND po.is_active = 'Y'
      )
    ORDER BY p.pr_basic_sno DESC;
END;
GO

-- Create the direct PO only after the vendor-driven PR's final approval.
-- No quotation or supplier-selection rows are created: the approved PR is
-- the commercial record and already owns the selected supplier and rate.
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateVendorDrivenPOFromPR
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @pr_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT),
        @created_by VARCHAR(20) = NULLIF(JSON_VALUE(@jsonInput, '$.created_by'), ''),
        @vendor_sno INT,
        @com_sno INT,
        @div_sno INT,
        @brn_sno INT,
        @dept_sno INT,
        @required_date DATE,
        @purpose NVARCHAR(500),
        @workflow_types_id INT,
        @po_basic_sno INT,
        @po_no VARCHAR(50),
        @sequence_number INT;

    IF @pr_basic_sno IS NULL OR @created_by IS NULL
        THROW 59020, 'pr_basic_sno and created_by are required.', 1;

    SELECT
        @vendor_sno = p.vendor_sno,
        @com_sno = p.com_sno,
        @div_sno = p.div_sno,
        @brn_sno = p.brn_sno,
        @dept_sno = p.dept_sno,
        @required_date = p.required_date,
        @purpose = p.purpose,
        @workflow_types_id = p.workflow_types_id
    FROM dbo.pr_basic_info p WITH (UPDLOCK, HOLDLOCK)
    WHERE p.pr_basic_sno = @pr_basic_sno
      AND p.request_mode = 'VENDOR_DRIVEN'
      AND p.status = 'A'
      AND p.is_active = 'Y';

    IF @vendor_sno IS NULL
        THROW 59021, 'Vendor-driven PR not found or not finally approved.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        SELECT @po_basic_sno = po_basic_sno, @po_no = po_df_no
        FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_basic_sno = @pr_basic_sno
          AND vendor_sno = @vendor_sno
          AND is_active = 'Y';

        IF @po_basic_sno IS NULL
        BEGIN
            SELECT @sequence_number = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
            FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
            WHERE po_df_no LIKE 'VPO-' + CAST(YEAR(GETDATE()) AS VARCHAR(4)) + '-%';

            SET @po_no = 'VPO-' + CAST(YEAR(GETDATE()) AS VARCHAR(4)) + '-'
                + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);

            INSERT INTO dbo.po_request_info (
                vendor_sno, brn_sno, dept_sno, com_sno, div_sno, pr_basic_sno,
                po_date, required_date, purpose, is_active, workflow_types_id,
                current_approver_id, status, po_df_no
            )
            VALUES (
                @vendor_sno, @brn_sno, @dept_sno, @com_sno, @div_sno, @pr_basic_sno,
                CAST(GETDATE() AS DATE), @required_date, @purpose, 'Y', @workflow_types_id,
                NULL, 'A', @po_no
            );

            SET @po_basic_sno = SCOPE_IDENTITY();

            INSERT INTO dbo.po_item_details (
                po_basic_sno, pr_item_sno, prod_sno, prod_name, specification,
                qty, unit, unit_name, agreed_unit_price, total_cost, discount_pct,
                tax_pct, net_cost, remarks, po_section, created_by, created_date, is_active
            )
            SELECT
                @po_basic_sno,
                pid.pr_item_sno,
                pid.prod_sno,
                COALESCE(pid.item_description, product.prod_name),
                pid.specification,
                pid.qty,
                pid.unit,
                uom.uom_name,
                pid.item_rate,
                pid.taxable_amount,
                0,
                pid.gst_pct,
                pid.total_cost,
                pid.remarks,
                'MATERIAL',
                @created_by,
                GETDATE(),
                '1'
            FROM dbo.pr_item_details pid
            LEFT JOIN dbo.product_master product ON product.prod_sno = pid.prod_sno
            LEFT JOIN dbo.uom_master uom ON uom.uom_sno = pid.unit
            WHERE pid.pr_basic_sno = @pr_basic_sno
              AND pid.is_active = 'Y';

            IF @@ROWCOUNT = 0
                THROW 59022, 'Vendor-driven PR has no active item lines.', 1;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT @po_basic_sno AS po_basic_sno, @po_no AS po_no, 'SUCCESS' AS result;
END;
GO

-- Configure the dedicated VendorDrivenPurchaseRequisition workflow in the
-- existing Workflow Approval screen for each company/division/branch/dept.
