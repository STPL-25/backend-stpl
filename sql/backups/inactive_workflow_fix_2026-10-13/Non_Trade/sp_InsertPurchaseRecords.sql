CREATE     PROCEDURE [dbo].[sp_InsertPurchaseRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE
            @com_sno           INT,
            @div_sno           INT,
            @brn_sno           INT,
            @dept_sno          INT,
            @pr_basic_sno      INT,
            @po_date           DATE,
            @required_date     DATE,
            @priority_sno      INT,
            @purpose           NVARCHAR(500),
            @split_pr_no       VARCHAR(20),
            @created_by        VARCHAR(20),
            @po_basic_sno      INT,
            @workflow_types_id INT,
            @first_approver    VARCHAR(20),
            @items_inserted    INT;

        -- ── Parse JSON ─────────────────────────────────────────────────────
        SELECT
            @brn_sno       = JSON_VALUE(@jsonInput, '$.brn_sno'),
            @dept_sno      = JSON_VALUE(@jsonInput, '$.dept_sno'),
            @pr_basic_sno  = JSON_VALUE(@jsonInput, '$.pr_basic_sno'),
            @created_by    = JSON_VALUE(@jsonInput, '$.created_by'),
            @com_sno       = JSON_VALUE(@jsonInput, '$.com_sno'),
            @div_sno       = JSON_VALUE(@jsonInput, '$.div_sno'),
            @po_date       = NULLIF(JSON_VALUE(@jsonInput, '$.po_date'),       ''),
            @required_date = NULLIF(JSON_VALUE(@jsonInput, '$.required_date'), ''),
            @priority_sno  = JSON_VALUE(@jsonInput, '$.priority_sno'),
            @purpose       = NULLIF(JSON_VALUE(@jsonInput, '$.purpose'),       ''),
            @split_pr_no   = NULLIF(JSON_VALUE(@jsonInput, '$.split_pr_no'),   '');

            SELECT @brn_sno,@dept_sno,@pr_basic_sno,@created_by,@com_sno,@div_sno
        -- ── Field Validations ──────────────────────────────────────────────
        IF @brn_sno IS NULL
            THROW 50001, 'Branch (brn_sno) is required.', 1;

        IF @dept_sno IS NULL
            THROW 50012, 'Department (dept_sno) is required.', 1;

        IF @pr_basic_sno IS NULL
            THROW 50014, 'PR Basic SNO (pr_basic_sno) is required.', 1;

        IF @created_by IS NULL
            THROW 50004, 'Created by is required.', 1;

        IF NOT EXISTS (
            SELECT 1
            FROM OPENJSON(@jsonInput, '$.items')
            WHERE JSON_VALUE(value, '$.prod_sno') IS NOT NULL
              AND JSON_VALUE(value, '$.prod_sno') != ''
              AND JSON_VALUE(value, '$.unit')      IS NOT NULL
              AND JSON_VALUE(value, '$.unit')      != ''
        )
            THROW 50005, 'At least one valid item with prod_sno and unit is required.', 1;

        -- ── Resolve Workflow ───────────────────────────────────────────────
        SELECT TOP 1
            @workflow_types_id = wt.workflow_types_id
        FROM workflow_types wt
        INNER JOIN approval_workflow_master awm
            ON awm.workflow_id = wt.workflow_id
        WHERE wt.brn_sno      = @brn_sno
          AND wt.dept_sno     = @dept_sno
          AND (wt.com_sno     = @com_sno OR @com_sno IS NULL)
          AND (wt.div_sno     = @div_sno OR @div_sno IS NULL)
          AND awm.entity_type = 'PurchaseOrder'
        ORDER BY wt.workflow_types_id;

        --IF @workflow_types_id IS NULL
        --    THROW 50009, 'No approval workflow found for this branch/department.', 1;

        SELECT TOP 1
            @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key]  = '0'
          AND s2.[key] = '0';

        --IF @first_approver IS NULL
        --    THROW 50010, 'No first approver found for the resolved workflow.', 1;

        -- ── Insert PO Basic Info ───────────────────────────────────────────
        INSERT INTO [Non_Trade].[dbo].[po_request_info]
        (
            [brn_sno],              [dept_sno],             [com_sno],
            [div_sno],              [pr_basic_sno],         [po_date],
            [required_date],        [priority_sno],         [purpose],
            [is_active],            [workflow_types_id],    [current_approver_id],
            [status],               [split_pr_no]       
        )
        VALUES
        (
            @brn_sno,               @dept_sno,              @com_sno,
            @div_sno,               @pr_basic_sno,          @po_date,
            @required_date,         @priority_sno,          @purpose,
            'Y',                    @workflow_types_id,     @first_approver,
            'P',                    @split_pr_no         
        );

        SET @po_basic_sno = SCOPE_IDENTITY();

        -- ── Insert PO Item Details ─────────────────────────────────────────
        INSERT INTO [Non_Trade].[dbo].[po_item_details]
        (
            [po_basic_sno],         [pr_item_sno],          [prod_sno],
            [prod_name],            [specification],        [qty],
            [unit],                 [unit_name],            [agreed_unit_price],
            [total_cost],           [discount_pct],         [tax_pct],
            [net_cost],             [remarks],              [split_pr_no],
            [is_active]
        )
        SELECT
            @po_basic_sno,
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.pr_item_sno'),              '') AS INT),
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.prod_sno'),                 '') AS INT),
            NULLIF(JSON_VALUE(value, '$.prod_name'),                         ''),
            NULLIF(JSON_VALUE(value, '$.specification'),                     ''),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.qty'),              '') AS DECIMAL(18,4)), 0),
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.unit'),                    '') AS INT),
            NULLIF(JSON_VALUE(value, '$.unit_name'),                         ''),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.agreed_unit_price'),'') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.total_cost'),       '') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.discount_pct'),     '') AS DECIMAL(5,2)),  0),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.tax_pct'),          '') AS DECIMAL(5,2)),  0),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.net_cost'),         '') AS DECIMAL(18,4)), 0),
            NULLIF(JSON_VALUE(value, '$.remarks'),                           ''),
            @split_pr_no,
            'Y'
        FROM OPENJSON(@jsonInput, '$.items')
        WHERE JSON_VALUE(value, '$.prod_sno') IS NOT NULL
          AND JSON_VALUE(value, '$.prod_sno') != ''
          AND JSON_VALUE(value, '$.unit')      IS NOT NULL
          AND JSON_VALUE(value, '$.unit')      != '';

        SET @items_inserted = @@ROWCOUNT;

        IF @items_inserted = 0
            THROW 50008, 'No items were inserted. Check that items array is valid and non-empty.', 1;

        COMMIT TRANSACTION;

        SELECT
            'Success'       AS Status,
            @po_basic_sno   AS POBasicSno,
            @items_inserted AS ItemsInserted;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT            = ERROR_SEVERITY();
        DECLARE @ErrorState    INT            = ERROR_STATE();

        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END;