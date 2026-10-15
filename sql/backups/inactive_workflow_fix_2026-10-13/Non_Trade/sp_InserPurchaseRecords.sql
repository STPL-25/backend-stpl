  
  
CREATE     PROCEDURE [dbo].[sp_InserPurchaseRecords]  
    @jsonInput   NVARCHAR(MAX)  
    --@po_no       VARCHAR(20) OUTPUT  
AS  
BEGIN  
    SET NOCOUNT ON;  
  
    BEGIN TRY  
        BEGIN TRANSACTION;  
  
        DECLARE  
            @com_sno             INT,  
            @div_sno             INT,  
            @brn_sno             INT,  
            @dept_sno            INT,  
            --@vendor_sno          INT,  
            @pr_basic_sno        INT,  
            --@budget_sno          INT,  
            --@budget_code         VARCHAR(50),  
            @po_date             DATE,  
            @required_date       DATE,  
            @priority_sno        INT,  
            @purpose             NVARCHAR(500),  
            --@terms_conditions    NVARCHAR(MAX),  
            --@delivery_address    NVARCHAR(500),  
            @split_pr_no         VARCHAR(20),  
            @created_by          VARCHAR(20),  
            @current_year        VARCHAR(10),  
            @po_prefix           VARCHAR(20),  
            @sequence_number     INT,  
            @po_basic_sno        INT,  
            @workflow_id         INT,  
            @workflow_types_id   INT,  
            @first_approver      VARCHAR(20),  
            @items_inserted      INT;  
  
        -- ── Generate PO Number ─────────────────────────────────────────────  
        SET @current_year = dbo.fn_GetFinancialYear(GETDATE());  
        SET @po_prefix    = 'PO' + @current_year;  -- e.g. 'PO26-27'  
  
        --SELECT @sequence_number = ISNULL(MAX(  
        --    CASE  
        --        WHEN po_no LIKE @po_prefix + '%'  
        --        THEN TRY_CAST(  
        --                 SUBSTRING(po_no, LEN(@po_prefix) + 1, LEN(po_no))  
        --             AS INT)  
        --        ELSE 0  
        --    END  
        --), 0) + 1  
        --FROM [Non_Trade].[dbo].[po_request_info] WITH (UPDLOCK, HOLDLOCK)  
        --WHERE po_no LIKE @po_prefix + '%';  
  
        --SET @po_no = @po_prefix + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);  
        -- e.g. PO26-270001  
  
        -- ── Parse JSON ─────────────────────────────────────────────────────  
        SELECT  
            @com_sno          = JSON_VALUE(@jsonInput, '$.com_sno'),  
            @div_sno          = JSON_VALUE(@jsonInput, '$.div_sno'),  
            @brn_sno          = JSON_VALUE(@jsonInput, '$.brn_sno'),  
            @dept_sno         = JSON_VALUE(@jsonInput, '$.dept_sno'),  
            --@vendor_sno       = JSON_VALUE(@jsonInput, '$.basicInfo.vendor_sno'),  
            @pr_basic_sno     = JSON_VALUE(@jsonInput, '$.pr_basic_sno'),  
            --@budget_sno       = JSON_VALUE(@jsonInput, '$.basicInfo.budget_sno'),  
            --@budget_code      = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.budget_code'),   ''),  
            @po_date          = JSON_VALUE(@jsonInput, '$.po_date'),  
            @required_date    = JSON_VALUE(@jsonInput, '$.required_date'),  
            @priority_sno     = JSON_VALUE(@jsonInput, '$.priority_sno'),  
            @purpose          = NULLIF(JSON_VALUE(@jsonInput, '$.purpose'),       ''),  
            --@terms_conditions = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.terms_conditions'), ''),  
            --@delivery_address = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.delivery_address'), ''),  
            @split_pr_no      = NULLIF(JSON_VALUE(@jsonInput, '$.split_pr_no'),   ''),  
            @created_by       = JSON_VALUE(@jsonInput, '$.created_by');  
  
        -- ── Field Validations ──────────────────────────────────────────────  
        --IF @com_sno IS NULL  
        --    THROW 50010, 'Company (com_sno) is required.', 1;  
  
        --IF @div_sno IS NULL  
        --    THROW 50011, 'Division (div_sno) is required.', 1;  
  
        --IF @brn_sno IS NULL  
        --    THROW 50001, 'Branch (brn_sno) is required.', 1;  
  
        --IF @dept_sno IS NULL  
        --    THROW 50012, 'Department (dept_sno) is required.', 1;  
  
        --IF @vendor_sno IS NULL  
        --    THROW 50013, 'Vendor (vendor_sno) is required.', 1;  
  
        --IF @po_date IS NULL  
        --    THROW 50002, 'PO date (po_date) is required.', 1;  
  
        --IF @required_date IS NULL  
        --    THROW 50003, 'Required date is required.', 1;  
  
        --IF @created_by IS NULL  
        --    THROW 50004, 'Created by is required.', 1;  
  
        -- Validate items array  
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
        SELECT  
            @workflow_id       = wt.workflow_id,  
            @workflow_types_id = wt.workflow_types_id  
        FROM workflow_types wt  
        INNER JOIN approval_workflow_master awm  
            ON awm.workflow_id = wt.workflow_id  
        WHERE wt.brn_sno      = @brn_sno  
          AND wt.dept_sno     = @dept_sno  
          AND wt.com_sno      = @com_sno  
          AND wt.div_sno      = @div_sno  
          AND awm.entity_type = 'PurchaseOrder';  
  
        --IF @workflow_types_id IS NULL  
        --    THROW 50006, 'No workflow configuration found for this branch and department.', 1;  
        -- Resolve first approver  
        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')  
        FROM vw_workflow_stages AS ws  
        CROSS APPLY OPENJSON(ws.stages_json) AS s  
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2  
        WHERE ws.workflow_types_id = @workflow_types_id  
          AND s.[key]  = '0'  
          AND s2.[key] = '0';  
  
        --IF @first_approver IS NULL  
        --    THROW 50007, 'No approver found for the first stage of the workflow.', 1;  
  
        -- ── Insert PO Basic Info ───────────────────────────────────────────  
        INSERT INTO [Non_Trade].[dbo].[po_request_info]  
        (  
                                [brn_sno],  
            [dept_sno],           [com_sno],              [div_sno],  
               [pr_basic_sno],  
            [po_date],            [required_date],        [priority_sno],  
            [purpose],             
            [is_active],          [workflow_types_id],    [current_approver_id],  
            [status],             [split_pr_no]            
              
        )  
        VALUES  
        (  
                                  @brn_sno,  
            @dept_sno,            @com_sno,               @div_sno,  
             @pr_basic_sno,  
            @po_date,             @required_date,         @priority_sno,  
            @purpose,              
            'Y',                  @workflow_types_id,     @first_approver,  
            'P',                  @split_pr_no             
            
        );  
  
        SET @po_basic_sno = SCOPE_IDENTITY();  
  
        -- ── Insert PO Item Details ─────────────────────────────────────────  
        INSERT INTO [Non_Trade].[dbo].[po_item_details]  
        (  
            [po_basic_sno],       [pr_item_sno],          [prod_sno],  
            [prod_name],                   [specification],  
            [qty],                [unit],                 [unit_name],  
            [agreed_unit_price],  [total_cost],           [discount_pct],  
            [tax_pct],            [net_cost],             [remarks],  
            [split_pr_no],        [is_active],            [created_by],  
            [created_date]  
        )  
        SELECT  
            @po_basic_sno,  
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.pr_item_sno'),        '') AS INT),  
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.prod_sno'),           '') AS INT),  
            NULLIF(JSON_VALUE(value, '$.prod_name'),                   ''),  
             
            NULLIF(JSON_VALUE(value, '$.specification'),               ''),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.qty'),                  ''), 0),  
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.unit'),               '') AS INT),  
            NULLIF(JSON_VALUE(value, '$.unit_name'),                   ''),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.agreed_unit_price'),    ''), 0),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.total_cost'),           ''), 0),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.discount_pct'),         ''), 0),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.tax_pct'),              ''), 0),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.net_cost'),             ''), 0),  
            NULLIF(JSON_VALUE(value, '$.remarks'),                     ''),  
            @split_pr_no,  
            'Y',  
            @created_by,  
            GETDATE()  
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
            --'PO Data Saved Successfully. PO No: ' + @pr_basic_sno AS Message,  
            --@jsonInput AS 'jsonInput',  
            'Success'                                       AS Status,  
            @po_basic_sno                                   AS POBasicSno,  
            @items_inserted                                 AS ItemsInserted;  
  
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