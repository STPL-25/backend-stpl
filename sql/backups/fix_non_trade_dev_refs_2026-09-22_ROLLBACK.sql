-- sp_approve_pr_datas
-- ============================================================
-- sp_approve_pr_datas v2
-- Database: Non_trade_Dev (MSSQL)
--
-- Surgical addition only: both result sets (REJECTED and SUCCESS/approve)
-- now also return pr_basic_info.request_mode. The Node approval path
-- (PR.controller.js#approvePr) needs this to know whether a just-approved
-- PR is VENDOR_DRIVEN, so it can auto-issue the child PO
-- (sp_nt_CreateVendorDrivenPOFromPR) right after a final-stage approval —
-- without this, the Node layer would need a second round-trip query just
-- to check request_mode. Every other line of this procedure is byte-for-
-- byte unchanged from the live version.
-- ============================================================

CREATE OR ALTER   PROCEDURE dbo.sp_approve_pr_datas
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        -- Validate JSON input
        IF ISJSON(@jsonInput) = 0
        BEGIN
            RAISERROR('Invalid JSON format for @jsonInput', 16, 1);
            RETURN;
        END

        -- Extract scalar fields
        DECLARE @pr_no           VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.pr_no'),
                @comments        VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by     VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action          VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');  -- 'approve' or 'reject'

        -- Validate action
        IF @action IS NULL OR LTRIM(RTRIM(LOWER(@action))) NOT IN ('approve', 'reject')
        BEGIN
            RAISERROR('Invalid action. Must be ''approve'' or ''reject''.', 16, 1);
            RETURN;
        END

        -- Normalize action to lowercase for comparison
        SET @action = LOWER(LTRIM(RTRIM(@action)));

        -- Validate approval_stages
        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
        BEGIN
            RAISERROR('Invalid or missing approval_stages in JSON', 16, 1);
            RETURN;
        END

        -- Validate approver
        IF @approved_by IS NULL OR LTRIM(RTRIM(@approved_by)) = ''
        BEGIN
            RAISERROR('Approver EC number is required.', 16, 1);
            RETURN;
        END

        -- ✅ TEMP TABLE
        CREATE TABLE #approval_stages (
            seq_no               INT,
            approver_ecno        VARCHAR(30),
            stage                VARCHAR(100),
            required_approvals   VARCHAR(10),
            is_mandatory         CHAR(1),
            escalation_hours     VARCHAR(10),
            approver_condition   VARCHAR(200),
            next_approver_ecno   VARCHAR(30),
            can_forward          CHAR(1),
            can_backward         CHAR(1),
            can_edit_data        CHAR(1)
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

        -- Check PR exists
        DECLARE @pr_basic_sno INT;
        DECLARE @request_mode VARCHAR(30);

        SELECT @pr_basic_sno = pr_basic_sno, @request_mode = request_mode
        FROM pr_basic_info
        WHERE pr_no = @pr_no AND is_active = 'Y';

        IF @pr_basic_sno IS NULL
        BEGIN
            RAISERROR('Purchase Request not found or inactive: %s', 16, 1, @pr_no);
            RETURN;
        END

        -- =============================================
        -- ✅ REJECT FLOW
        -- =============================================
        IF @action = 'reject'
        BEGIN
            -- Insert rejection into history with status = 'R'
            INSERT INTO pr_history_data (
                pr_basic_sno, pr_edit_data, workflow_types_id,
                approver_ecno, status, status_by,
                status_date, commends, is_active, pr_no
            )
            SELECT
                @pr_basic_sno,
                NULL,
                NULL,
                s.approver_ecno,
                'R',                -- R = Rejected
                @approved_by,
                GETDATE(),
                @comments,          -- Rejection reason stored as comments
                'Y',
                @pr_no
            FROM #approval_stages s
            WHERE s.approver_ecno = @approved_by;

            -- Update PR basic info: status = 'R', clear current approver
            UPDATE pr_basic_info
            SET status             = 'R',           -- R = Rejected
                current_approver_id = NULL           -- No further approval needed
            WHERE pr_basic_sno = @pr_basic_sno;

            DROP TABLE #approval_stages;

            -- Return rejection result
            SELECT
                'REJECTED'       AS result,
                @pr_no           AS pr_no,
                @approved_by     AS rejected_by,
                GETDATE()        AS rejected_on,
                @comments        AS rejection_reason,
                @request_mode    AS request_mode;

            RETURN;
        END

        -- =============================================
        -- ✅ APPROVE FLOW (original logic)
        -- =============================================

        -- Find next approver using LEAD()
        DECLARE @next_current_approver  VARCHAR(30);
        DECLARE @next_condition         VARCHAR(200);
        DECLARE @next_can_forward       CHAR(1);
        DECLARE @next_can_backward      CHAR(1);
        DECLARE @next_is_mandatory      CHAR(1);

        SELECT
            @next_current_approver = next_stage.approver_ecno,
            @next_condition        = next_stage.approver_condition,
            @next_can_forward      = next_stage.can_forward,
            @next_can_backward     = next_stage.can_backward,
            @next_is_mandatory     = next_stage.is_mandatory
        FROM (
            SELECT
                approver_ecno,
                LEAD(approver_ecno, 1, NULL) OVER (ORDER BY seq_no) AS next_approver_ecno
            FROM #approval_stages
        ) current_stage
        LEFT JOIN #approval_stages next_stage
            ON next_stage.approver_ecno = current_stage.next_approver_ecno
        WHERE current_stage.approver_ecno = @approved_by;

        -- Insert approval history
        INSERT INTO pr_history_data (
            pr_basic_sno, pr_edit_data, workflow_types_id,
            approver_ecno, status, status_by,
            status_date, commends, is_active, pr_no
        )
        SELECT
            @pr_basic_sno,
            NULL,
            NULL,
            s.approver_ecno,
            'A',                -- A = Approved
            @approved_by,
            GETDATE(),
            @comments,
            'Y',
            @pr_no
        FROM #approval_stages s
        WHERE s.approver_ecno = @approved_by;

        DECLARE @stages_processed INT = @@ROWCOUNT;

        -- Update current approver (NULL = final stage reached)
        UPDATE pr_basic_info
        SET current_approver_id = @next_current_approver
        WHERE pr_basic_sno = @pr_basic_sno;

        -- If final stage, mark PR as fully Approved
        IF @next_current_approver IS NULL
        BEGIN
            UPDATE pr_basic_info
            SET status = 'A'
            WHERE pr_basic_sno = @pr_basic_sno;
        END

        DROP TABLE #approval_stages;

        -- Return approval result
        SELECT
            'SUCCESS'                                  AS result,
            @pr_no                                     AS pr_no,
            @approved_by                               AS approved_by,
            GETDATE()                                  AS approved_on,
            @stages_processed                          AS stages_processed,
            ISNULL(@next_current_approver, 'FINAL_STAGE') AS next_approver,
            @next_condition                            AS next_condition,
            @next_can_forward                          AS next_can_forward,
            @pr_basic_sno                               AS pr_basic_sno,
            @request_mode                               AS request_mode;

    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL
            DROP TABLE #approval_stages;

        SELECT
            'ERROR'           AS result,
            ERROR_NUMBER()    AS error_number,
            ERROR_MESSAGE()   AS error_message,
            ERROR_LINE()      AS error_line,
            ERROR_PROCEDURE() AS error_procedure;
    END CATCH

END;
GO

-- sp_Get_Business_Details

  CREATE OR ALTER   PROCEDURE [dbo].[sp_Get_Business_Details] 
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        SELECT  [business_types_id]
      ,[business_types_name]
      ,[Description]
      ,[LiabilityType]
      ,[IsActive]
      ,[CreatedAt]
  FROM [Non_trade_Dev].[dbo].[business_types]
WHERE IsActive=1
ORDER BY business_types_id;
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        -- Re-throw the original error
        THROW;
    END CATCH
END
GO

-- sp_InserPurchaseRecords
  
  
CREATE OR ALTER   PROCEDURE [dbo].[sp_InserPurchaseRecords]  
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
        --FROM [Non_trade_Dev].[dbo].[po_request_info] WITH (UPDLOCK, HOLDLOCK)  
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
        INSERT INTO [Non_trade_Dev].[dbo].[po_request_info]  
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
        INSERT INTO [Non_trade_Dev].[dbo].[po_item_details]  
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
GO

-- sp_InsertPurchaseRecords
CREATE OR ALTER   PROCEDURE [dbo].[sp_InsertPurchaseRecords]
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
        INSERT INTO [Non_trade_Dev].[dbo].[po_request_info]
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
        INSERT INTO [Non_trade_Dev].[dbo].[po_item_details]
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
GO

-- sp_nt_AutoCreateStockIssueFromGRN
-- ============================================================
-- Perishable stock: auto-issue off GRN like Non-Regular, plus an
-- "Expiry Stock" signal on the Inventory Stock page.
-- Database: Non_trade_Dev (MSSQL)
--
-- Requires backend-stpl/sql/77_subcategory_perishable_type.sql to have run
-- first (adds subcat_stock_type = 'Perishable' and subcategory_master.
-- perishable_days).
--
-- Both procedures below are reproduced from their live OBJECT_DEFINITION()
-- (not from the on-disk 22_nonregular_direct_issue.sql / 29_inventory_
-- stock_level_reference.sql copies, which had already drifted from live).
-- Only the marked lines change.
-- ============================================================

-- ============================================================
-- sp_nt_AutoCreateStockIssueFromGRN
-- Change: the auto-create-Pending-request fast path (previously gated on
-- @stock_type = 'Non-Regular' only) now also fires for 'Perishable'. No
-- change needed anywhere else — sp_nt_IssueStockRequest already supports
-- issuing part of a request now and the remainder later (Pending ->
-- Partially Issued -> Issued), so Perishable inherits that for free.
-- ============================================================
CREATE OR ALTER   PROCEDURE dbo.sp_nt_AutoCreateStockIssueFromGRN
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_item_sno   INT           = JSON_VALUE(@jsonInput, '$.po_item_sno');
    DECLARE @item_sno      INT           = JSON_VALUE(@jsonInput, '$.item_sno');
    DECLARE @qty           DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.qty');
    DECLARE @grn_basic_sno INT           = JSON_VALUE(@jsonInput, '$.grn_basic_sno');
    DECLARE @grn_no        VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.grn_no');
    DECLARE @created_by    VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @po_item_sno IS NULL OR @item_sno IS NULL OR @qty IS NULL OR @qty <= 0
        RETURN;

    -- Resolve PR origin + the product's subcategory stock type in one hop.
    DECLARE @pr_item_sno    INT,
            @pr_basic_sno   INT,
            @pr_no          VARCHAR(20),
            @requester_ecno VARCHAR(20),
            @com_sno        INT, @div_sno INT, @brn_sno INT, @dept_sno INT,
            @stock_type     VARCHAR(20);

    SELECT
        @pr_item_sno    = pid.pr_item_sno,
        @pr_basic_sno   = pb.pr_basic_sno,
        @pr_no          = pb.pr_no,
        @requester_ecno = pb.created_by,
        @com_sno        = pb.com_sno,
        @div_sno        = pb.div_sno,
        @brn_sno        = pb.brn_sno,
        @dept_sno       = pb.dept_sno,
        @stock_type     = scm.subcat_stock_type
    FROM dbo.po_item_details poid
    JOIN dbo.pr_item_details pid ON pid.pr_item_sno = poid.pr_item_sno
    JOIN dbo.pr_basic_info pb    ON pb.pr_basic_sno = pid.pr_basic_sno
    LEFT JOIN dbo.product_master pm     ON pm.prod_sno   = pid.prod_sno
    LEFT JOIN dbo.subcategory_master scm ON scm.subcat_sno = pm.subcat_sno
    WHERE poid.po_item_sno = @po_item_sno;

    -- Not PR-traceable (e.g. a direct/Store PO line) -> nothing to create,
    -- nothing to notify.
    IF @pr_item_sno IS NULL
        RETURN;

    -- Idempotency: this exact Non-Regular/Perishable GRN line already
    -- produced a request (a retried GRN post). Nothing new to create or
    -- (re-)notify.
    IF @stock_type IN ('Non-Regular', 'Perishable') AND EXISTS (
        SELECT 1
        FROM dbo.nt_stock_request_items sri
        JOIN dbo.nt_stock_requests sr ON sr.request_sno = sri.request_sno
        WHERE sr.grn_basic_sno = @grn_basic_sno AND sri.po_item_sno = @po_item_sno
    )
        RETURN;

    DECLARE @requester_name VARCHAR(255);
    SELECT @requester_name = ename FROM dbo.vw_verified_employees WHERE ecno = @requester_ecno;

    DECLARE @item_code VARCHAR(50), @item_name VARCHAR(255), @uom VARCHAR(20);
    SELECT @item_code = item_code, @item_name = item_name, @uom = uom
    FROM dbo.nt_inventory_items WHERE item_sno = @item_sno;

    DECLARE @request_sno INT, @request_no VARCHAR(30);

    -- Non-Regular AND Perishable: auto-create the directly-issuable Pending
    -- request so the requester never has to raise a manual Store
    -- Requisition. (Perishable added here; Non-Regular behavior unchanged.)
    IF @stock_type IN ('Non-Regular', 'Perishable')
    BEGIN
        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));

        BEGIN TRANSACTION;
        BEGIN TRY
            DECLARE @seq INT;
            SELECT @seq = ISNULL(MAX(CAST(RIGHT(request_no, 4) AS INT)), 0) + 1
            FROM dbo.nt_stock_requests WITH (UPDLOCK, HOLDLOCK)
            WHERE request_no LIKE 'SR-' + @year + '-%';

            SET @request_no = 'SR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

            INSERT INTO dbo.nt_stock_requests (
                request_no, requested_by, requested_name, purpose, status,
                source_type, pr_basic_sno, pr_no, grn_basic_sno,
                com_sno, div_sno, brn_sno, dept_sno, created_at
            )
            VALUES (
                @request_no, @requester_ecno, @requester_name,
                'Auto: GRN receipt for ' + @stock_type + ' item, PR ' + ISNULL(@pr_no, ''), 'Pending',
                'Auto-GRN', @pr_basic_sno, @pr_no, @grn_basic_sno,
                @com_sno, @div_sno, @brn_sno, @dept_sno, GETDATE()
            );

            SET @request_sno = SCOPE_IDENTITY();

            INSERT INTO dbo.nt_stock_request_items (
                request_sno, item_sno, item_code, item_name, uom,
                requested_qty, issued_qty, line_status, pr_item_sno, po_item_sno
            )
            VALUES (
                @request_sno, @item_sno, @item_code, @item_name, @uom,
                @qty, 0, 'Pending', @pr_item_sno, @po_item_sno
            );

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            THROW;
        END CATCH
    END

    -- Always returned when PR-traceable, so the caller can notify the
    -- requester regardless of stock type. request_sno/request_no are only
    -- non-NULL when the auto-create above just ran.
    SELECT
        @requester_ecno AS requester_ecno,
        @requester_name AS requester_name,
        @pr_no          AS pr_no,
        @pr_basic_sno   AS pr_basic_sno,
        @stock_type     AS stock_type,
        @item_name      AS item_name,
        @uom            AS uom,
        @qty            AS qty,
        @request_sno    AS request_sno,
        @request_no     AS request_no;
END;
GO

-- sp_nt_CreateAcYearRecords
CREATE OR ALTER   PROCEDURE [dbo].[sp_nt_CreateAcYearRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        -- Input validation
        IF @jsonInput IS NULL OR @jsonInput = ''
        BEGIN
            SELECT 'Failed' as Status, 'JSON input is required' as ErrorMessage;
            RETURN;
        END
        
        -- Validate JSON format
        IF ISJSON(@jsonInput) = 0
        BEGIN
            SELECT 'Failed' as Status, 'Invalid JSON format' as ErrorMessage;
            RETURN;
        END
        
        -- Validate required fields
        IF JSON_VALUE(@jsonInput, '$.ac_year_code') IS NULL OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.ac_year_code'))) = ''
        BEGIN
            SELECT 'Failed' as Status, 'Ac year code is required' as ErrorMessage;
            RETURN;
        END
      
        BEGIN TRANSACTION;   
        
        DECLARE @InsertedCount INT;
     
        -- Insert records into ac_master table
        INSERT INTO [Non_trade_Dev].[dbo].[ac_master](
            ac_year_code, 
            ac_year
        )
        SELECT 
            LTRIM(RTRIM(ac_year_code)) as ac_year_code, 
            LTRIM(RTRIM(ac_year)) as ac_year
        FROM OPENJSON(@jsonInput)
        WITH (
            ac_year_code VARCHAR(50) '$.ac_year_code',
            ac_year VARCHAR(50) '$.ac_year'
        );
        
        SET @InsertedCount = @@ROWCOUNT;
        
        COMMIT TRANSACTION;
        
        -- Return success message with count
        SELECT 
            'Success' as Status, 
            CONCAT('Successfully inserted ', @InsertedCount, ' record(s)') as Message,
            @InsertedCount as RecordsInserted;
            
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        
        -- Return detailed error information
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        -- Re-throw the original error
        THROW;
    END CATCH
END

GO

-- sp_nt_CreateGstStateRecords
CREATE OR ALTER   PROCEDURE [dbo].[sp_nt_CreateGstStateRecords]  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
      
    BEGIN TRY  
        -- Input validation  
        IF @jsonInput IS NULL OR @jsonInput = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'JSON input is required' as ErrorMessage;  
            RETURN;  
        END  
          
        -- Validate JSON format  
        IF ISJSON(@jsonInput) = 0  
        BEGIN  
            SELECT 'Failed' as Status, 'Invalid JSON format' as ErrorMessage;  
            RETURN;  
        END  
          
        -- Validate required fields  
        IF JSON_VALUE(@jsonInput, '$.gst_state_un_name') IS NULL OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.gst_state_un_name'))) = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'State/Un name is required' as ErrorMessage;  
            RETURN;  
        END  
        
        BEGIN TRANSACTION;     
          
        DECLARE @InsertedCount INT;  
     
        -- Insert records into gst_master table (corrected table name)  
        INSERT INTO [Non_trade_Dev].[dbo].[gst_master](  
            gst_state_un_name,   
            gst_code,
            is_active,
            created_date,
            gst_alpha_code  
        )  
        SELECT   
            LTRIM(RTRIM(gst_state_un_name)) as gst_state_un_name,   
            LTRIM(RTRIM(gst_code)) as gst_code, 
            'Y',
            getDate(),
            LTRIM(RTRIM(gst_alpha_code)) as gst_alpha_code  
        FROM OPENJSON(@jsonInput)  
        WITH (  
            gst_state_un_name VARCHAR(50) '$.gst_state_un_name',  
            gst_code VARCHAR(10) '$.gst_code',  
            gst_alpha_code VARCHAR(5) '$.gst_alpha_code'  
        );  
          
        SET @InsertedCount = @@ROWCOUNT;  
          
        COMMIT TRANSACTION;  
          
        -- Return success message with count  
        SELECT   
            'Success' as Status,   
            CONCAT('Successfully inserted ', @InsertedCount, ' GST record(s)') as Message,  
            @InsertedCount as RecordsInserted;  
              
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
          
          DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();  
        DECLARE @ErrorNumber INT = ERROR_NUMBER();  
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();  
          
        -- Re-throw the original error  
        THROW;  
    END CATCH  
END
GO

-- sp_nt_CreatePriorityRecords

 CREATE OR ALTER   PROCEDURE [dbo].[sp_nt_CreatePriorityRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
       
       
       
      
        BEGIN TRANSACTION;   
        
        DECLARE @InsertedCount INT;
     
        -- Insert records into ac_master table
        INSERT INTO [Non_trade_Dev].[dbo].[priority_master](
            priority_name, 
            priority_desc
        )
        SELECT 
            LTRIM(RTRIM(priority_name)) as priority_name, 
            LTRIM(RTRIM(priority_desc)) as priority_desc
        FROM OPENJSON(@jsonInput)
        WITH (
            priority_name VARCHAR(50) '$.priority_name',
            priority_desc VARCHAR(50) '$.priority_desc'
        );
        
        SET @InsertedCount = @@ROWCOUNT;
        
        COMMIT TRANSACTION;
        
        -- Return success message with count
        SELECT 
            'Success' as Status, 
            CONCAT('Successfully inserted ', @InsertedCount, ' record(s)') as Message,
            @InsertedCount as RecordsInserted;
            
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        
        -- Return detailed error information
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        THROW;
    END CATCH
END

GO

-- sp_nt_CreateUomRecords
CREATE OR ALTER   PROCEDURE [dbo].[sp_nt_CreateUomRecords]  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
      
    BEGIN TRY  
        -- Input validation  
        IF @jsonInput IS NULL OR @jsonInput = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'JSON input is required' as ErrorMessage;  
            RETURN;  
        END  
          
        -- Validate JSON format  
        IF ISJSON(@jsonInput) = 0  
        BEGIN  
            SELECT 'Failed' as Status, 'Invalid JSON format' as ErrorMessage;  
            RETURN;  
        END  
          
        -- Validate required fields  
        IF JSON_VALUE(@jsonInput, '$.uom_code') IS NULL OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.uom_code'))) = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'uom_code is required' as ErrorMessage;  
            RETURN;  
        END  
        
        BEGIN TRANSACTION;     
          
        DECLARE @InsertedCount INT;  
       
        -- Insert records into uom_master table  
        INSERT INTO [Non_trade_Dev].[dbo].[uom_master](  
            uom_code,   
            uom_name,   
            uom_class,  
            uom_base_uom_flag,
            is_active,
            created_date,
            uom_con_factor
            
        )  
        SELECT   
            LTRIM(RTRIM(uom_code)) as uom_code,   
            LTRIM(RTRIM(uom_name)) as uom_name,   
            LTRIM(RTRIM(uom_class)) as uom_class,  
            LTRIM(RTRIM(uom_base_uom_flag)) as uom_base_uom_flag,
            'Y',
            getDate(),
            uom_con_factor  
        FROM OPENJSON(@jsonInput)  
        WITH (  
            uom_code CHAR(5) '$.uom_code',  
            uom_name VARCHAR(50) '$.uom_name',  
            uom_class VARCHAR(30) '$.uom_class',  
            uom_base_uom_flag CHAR(1) '$.uom_base_uom_flag',  
            uom_con_factor DECIMAL(18,6) '$.uom_con_factor'  
        )  
          
        SET @InsertedCount = @@ROWCOUNT;  
          
        COMMIT TRANSACTION;  
          
        -- Return success message with count  
        SELECT   
            'Success' as Status,   
            CONCAT('Successfully inserted ', @InsertedCount, ' UOM record(s)') as Message,  
            @InsertedCount as RecordsInserted;  
              
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
          
        -- Return detailed error information  
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();  
        DECLARE @ErrorNumber INT = ERROR_NUMBER();  
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();  
          
        -- Re-throw the original error  
        THROW;  
    END CATCH  
END  
GO

-- sp_nt_CreateWorkflowMaster
CREATE OR ALTER   PROCEDURE [dbo].[sp_nt_CreateWorkflowMaster]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        -- Input validation
        IF @jsonInput IS NULL OR @jsonInput = ''
        BEGIN
            SELECT 'Failed' AS Status, 'JSON input is required' AS ErrorMessage;
            RETURN;
        END

        -- Validate JSON format
        IF ISJSON(@jsonInput) = 0
        BEGIN
            SELECT 'Failed' AS Status, 'Invalid JSON format' AS ErrorMessage;
            RETURN;
        END

        BEGIN TRANSACTION;

        DECLARE @InsertedCount INT;

        -- Insert records into approval_workflow_master
        INSERT INTO [Non_trade_Dev].[dbo].[approval_workflow_master] (
            workflow_name,
            workflow_code,
            entity_type,
            [description],
            is_active,
            created_by,
            created_at
        )
        SELECT
            LTRIM(RTRIM(workflow_name))   AS workflow_name,
            LTRIM(RTRIM(workflow_code))   AS workflow_code,
            LTRIM(RTRIM(entity_type))     AS entity_type,
            [description],
            ISNULL(is_active, 'Y')        AS is_active,   -- default 'Y' if not provided
            created_by,
            ISNULL(created_at, GETDATE()) AS created_at   -- default current timestamp
        FROM OPENJSON(@jsonInput)
        WITH (
            workflow_name  VARCHAR(200) '$.workflow_name',
            workflow_code  VARCHAR(100) '$.workflow_code',
            entity_type    VARCHAR(100) '$.entity_type',
            [description]  NVARCHAR(MAX) '$.description',
            is_active      CHAR(1)       '$.is_active',
            created_by     INT           '$.created_by',
            created_at     DATETIME      '$.created_at'
        );

        SET @InsertedCount = @@ROWCOUNT;

        COMMIT TRANSACTION;

        -- Return success message with count
        SELECT
            'Success'                                                    AS Status,
            CONCAT('Successfully inserted ', @InsertedCount, ' workflow record(s)') AS Message,
            @InsertedCount                                               AS RecordsInserted;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber   INT            = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT            = ERROR_SEVERITY();

        -- Return structured error instead of re-throwing (optional: use THROW to bubble up)
        SELECT
            'Failed'         AS Status,
            @ErrorMessage    AS ErrorMessage,
            @ErrorNumber     AS ErrorNumber,
            @ErrorSeverity   AS ErrorSeverity;

        -- Uncomment below if you want to re-throw to the caller instead:
        -- THROW;
    END CATCH
END

GO

-- sp_nt_GetAllGRNs
-- ============================================================
-- Company/Division/Branch access scoping for grn-service list endpoints.
-- Database: Non_trade_Dev (MSSQL)
--
-- Companion to backend-stpl/sql/78_hierarchy_scope_wiring.sql — same
-- convention: an optional @HierarchyJson (or jsonInput.hierarchy for procs
-- that already take a single JSON blob) array of {com_sno, div_sno,
-- brn_sno}. NULL/absent = unfiltered (kept for internal/ops callers that
-- intentionally want everything). The Node layer always sends an actual
-- array — '[]' for an ecno with no assigned hierarchy — never omits it, so
-- the fail-closed "sees nothing until granted" default lives in
-- grn-service/src/middleware/hierarchyScope.js, not here.
--
-- sp_nt_GetStockSummary already had this (grn-service/sql/29_inventory_
-- stock_level_reference.sql) — needed no SQL change, only Node wiring.
-- This file extends the same pattern to the other org-scoped list procs:
-- GRN (grn_basic_info has com/div/brn), Inventory items (nt_inventory_items
-- has com/div/brn) and Stock Requests (nt_stock_requests has com/div/brn).
-- Each proc pulled fresh via OBJECT_DEFINITION() before editing, per
-- backend-stpl's established convention — the on-disk files these are
-- based on had already drifted from live in prior sessions.
-- ============================================================

-- ── sp_nt_GetAllGRNs ─────────────────────────────────────────────────────
CREATE OR ALTER   PROCEDURE dbo.sp_nt_GetAllGRNs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = NULL;
    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @status = JSON_VALUE(@jsonInput, '$.status');
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');
    END

    SELECT
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.gate_entry_sno,
        ge.gate_entry_no,
        b.po_basic_sno,
        p.po_df_no                                 AS po_no,
        b.vendor_sno,
        k.company_name                              AS vendor_name,
        CONVERT(VARCHAR(10), b.received_date, 120)  AS received_date,
        b.doc_ref_no,
        b.vehicle_no,
        b.challan_no,
        b.remarks,
        b.status,
        b.com_sno, b.div_sno, b.brn_sno, b.dept_sno,
        b.created_by                                AS received_by_name,
        CONVERT(VARCHAR(30), b.created_date, 120)    AS created_at,
        (
            SELECT
                gi.grn_item_sno,
                gi.po_item_sno,
                gi.prod_sno,
                gi.prod_name,
                gi.specification,
                gi.po_qty                            AS ordered_qty,
                gi.received_qty,
                gi.rejected_qty,
                gi.unit_name,
                gi.condition,
                gi.hsn_code,
                gi.remarks,
                gi.warehouse_location_sno,
                gi.warehouse_location_name
            FROM dbo.grn_item_details gi
            WHERE gi.grn_basic_sno = b.grn_basic_sno
              AND gi.is_active = 'Y'
            FOR JSON PATH
        )                                            AS items
    FROM dbo.grn_basic_info b
    LEFT JOIN dbo.nt_gate_entry ge   ON ge.gate_entry_sno = b.gate_entry_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = b.vendor_sno
    WHERE b.is_active = 'Y'
      AND (@status IS NULL OR b.status = @status)
      AND (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = b.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = b.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = b.brn_sno)
          )
      )
    ORDER BY b.grn_basic_sno DESC;
END;
GO

-- sp_nt_GetAllUsersSignUp

  
  
  CREATE OR ALTER   PROCEDURE [dbo].[sp_nt_GetAllUsersSignUp]  
     
AS  
BEGIN  
    SET NOCOUNT ON;  
     
  Select ntsp.nt_sign_up_sno,ntsp.ecno,vve.ename,vve.dept from nt_sign_up ntsp   
  inner join [Non_trade_Dev].[dbo].[vw_verified_employees] vve on ntsp.ecno=vve.ecno   
  --where ntsp.is_active='N'  
     
     
      
         
    END  
GO

-- sp_nt_GetApprovedPRsForPurchase
-- ============================================================
-- Exclude vendor-driven PRs from the Purchase Team screen
-- Database: Non_trade_Dev (MSSQL)
--
-- sp_nt_GetApprovedPRsForPurchase (predates this repo's sql/ convention —
-- reproduced byte-for-byte from OBJECT_DEFINITION(), same convention as
-- 33_nonstaff_approver_name_display.sql / 63_vw_pr_basic_info_vendor_driven.sql)
-- lists every status='A' PR that has no supplier_quotation_history row yet,
-- with no request_mode filter at all. Vendor-driven PRs never go through
-- the quotation flow, so they never get a supplier_quotation_history row —
-- they were showing up in the Purchase Team screen permanently, even after
-- their PO was already auto-created and emailed to the vendor
-- (sp_nt_CreateVendorDrivenPOFromPR / PR.controller.js#approvePr). Vendor-
-- driven PRs have their own dedicated queue (sp_nt_GetVendorDrivenApprovedPRs)
-- and don't belong here at all, at any stage — a straight request_mode
-- exclusion, not a "has a PO yet" check.
--
-- Only additive change: pbf.request_mode is now selected through the CTE,
-- and the final WHERE excludes it. Every other line is unchanged from the
-- live definition.
-- ============================================================

CREATE OR ALTER   PROCEDURE dbo.sp_nt_GetApprovedPRsForPurchase
    @HierarchyJson NVARCHAR(MAX) = NULL
AS
BEGIN TRY

    WITH pr_with_groups AS
    (
        SELECT
            pbf.pr_basic_sno,
            pbf.brn_sno,
            vadr.brn_name,
            vadr.brn_prefix,
            vadr.dept_name,
            vadr.div_prefix,
            vadr.div_name,
            vadr.div_sno,
            vadr.com_name,
            vadr.com_sno,
            vve.ename                     AS created_by_name,
            pbf.dept_sno,
            pbf.reg_date,
            pbf.required_date,
            pbf.priority_sno,
            pbf.purpose,
            pbf.is_active,
            pbf.created_by,
            pbf.created_date,
            pbf.modified_by,
            pbf.modified_date,
            pbf.request_mode,
            g.grp                         AS [group],
            CASE
                WHEN g.grp IS NOT NULL AND g.group_count > 1
                    THEN pbf.pr_no + '/' + CAST(g.grp AS VARCHAR(10))
                ELSE pbf.pr_no
            END                            AS pr_no,
            pbf.workflow_types_id,
            pbf.current_approver_id,
            pbf.status,
            pbf.pr_no                     AS base_pr_no,  -- Keep base pr_no for joining

            (
                SELECT
                    pid.pr_item_sno,
                    pid.pr_basic_sno,
                    pid.prod_sno,
                    pm.prod_name,
                    pm.prod_code,
                    pm.prod_notes,
                    pid.specification,
                    pid.qty,
                    pid.unit,
                    uom.uom_name,
                    uom.uom_code,
                    pid.est_cost,
                    pid.total_cost,
                    pid.remarks,
                    pid.created_by,
                    pid.created_date,
                    pid.modified_by,
                    pid.modified_date,
                    pid.is_active,
                    pid.[group],
                    pid.pr_no
                FROM pr_item_details pid
                INNER JOIN uom_master uom
                    ON uom.uom_sno = pid.unit
                INNER JOIN product_master pm
                    ON pid.prod_sno = pm.prod_sno
                WHERE pid.pr_basic_sno = pbf.pr_basic_sno
                  AND pid.is_active = 'Y'
                  AND (pid.[group] = g.grp OR (pid.[group] IS NULL AND g.grp IS NULL))
                FOR JSON PATH
            ) AS pr_item_details,

            (
                SELECT ws.stage_order_json
                FROM workflow_stage ws
                WHERE ws.workflow_types_id = pbf.workflow_types_id
                  AND ws.is_active = 'Y'
            ) AS stage_order_json,

            (
                SELECT
                    phd.status_by,
                    vve.ename,
                    phd.status_date,
                    phd.commends,
                    phd.pr_edit_data
                FROM pr_history_data phd
                INNER JOIN vw_verified_employees vve
                    ON phd.status_by = vve.ecno
                WHERE phd.pr_basic_sno = pbf.pr_basic_sno
                FOR JSON PATH
            ) AS pr_history_data,

            g.group_count

        FROM pr_basic_info pbf
        INNER JOIN workflow_types wt
            ON pbf.workflow_types_id = wt.workflow_types_id
        INNER JOIN vw_ActiveDeptRecords vadr
            ON pbf.brn_sno = vadr.brn_sno
           AND pbf.dept_sno = vadr.dept_sno
        INNER JOIN vw_verified_employees vve
            ON pbf.created_by = vve.ecno
        OUTER APPLY
        (
            SELECT
                pid.[group]        AS grp,
                COUNT(*) OVER ()   AS group_count
            FROM pr_item_details pid
            WHERE pid.pr_basic_sno = pbf.pr_basic_sno
              AND pid.is_active = 'Y'
            GROUP BY pid.[group]
        ) g
    )

    SELECT
        pr_basic_sno,
        brn_sno,
        brn_name,
        brn_prefix,
        dept_name,
        div_prefix,
        div_name,
        div_sno,
        com_name,
        com_sno,
        created_by_name,
        dept_sno,
        reg_date,
        required_date,
        priority_sno,
        purpose,
        is_active,
        created_by,
        created_date,
        modified_by,
        modified_date,
        [group],
        pr_no,
        workflow_types_id,
        current_approver_id,
        status,
        pr_item_details,
        stage_order_json,
        pr_history_data,
        CASE
            WHEN (SELECT COUNT(sqi.pr_no)
                  FROM supplier_quotation_info sqi
                  WHERE sqi.pr_no = p.pr_no) > 0
                THEN CAST(1 AS BIT)
            ELSE CAST(0 AS BIT)
        END AS isQuotationSubmitted
    FROM pr_with_groups p
    WHERE status = 'A'
      AND (p.request_mode IS NULL OR p.request_mode <> 'VENDOR_DRIVEN')
      AND NOT EXISTS
      (
          SELECT 1
          FROM supplier_quotation_history sqh
          WHERE sqh.pr_no = p.pr_no
            AND sqh.is_active = 1
      )
      AND (
          @HierarchyJson IS NULL
          OR EXISTS
          (
              SELECT 1
              FROM OPENJSON(@HierarchyJson)
              WITH (
                  com_sno INT '$.com_sno',
                  div_sno INT '$.div_sno',
                  brn_sno INT '$.brn_sno'
              ) h
              WHERE h.com_sno = p.com_sno
                AND (h.div_sno IS NULL OR h.div_sno = p.div_sno)
                AND (h.brn_sno IS NULL OR h.brn_sno = p.brn_sno)
          )
      );

END TRY
BEGIN CATCH
    DECLARE @ErrorMessage2  NVARCHAR(4000) = ERROR_MESSAGE(),
            @ErrorSeverity2 INT            = ERROR_SEVERITY(),
            @ErrorState2    INT            = ERROR_STATE();

    RAISERROR(@ErrorMessage2, @ErrorSeverity2, @ErrorState2);
END CATCH;
GO

-- sp_nt_GetCompanyRecords
-- ============================================================
-- Company/Division/Branch access scoping for the Masters generic CRUD
-- dispatch (backend-stpl/src/Masters/Routes/CommonMasterRoutes.js's
-- GET /:masterField, dispatched by CommonMasterRepo.storedProcedureMap).
-- Database: Non_trade_Dev (MSSQL)
--
-- Only the 5 masterFields whose rows actually carry a company/division/
-- branch identity get this treatment: CompanyMaster, DivisionMaster,
-- BranchMaster, DeptMaster, WarehouseLocationMaster. The other ~20 master
-- types dispatched through the same generic route (UomMaster, CategoryMaster,
-- ProductMaster, WorkflowMaster, etc.) are global reference data with no
-- org concept and are deliberately left untouched — see
-- [project-ecno-org-scope-and-grn-fifo] memory for the full triage.
--
-- Convention matches every other @HierarchyJson filter added this session:
-- an OPENJSON array of {com_sno, div_sno, brn_sno}, NULL = unfiltered (kept
-- for internal callers), empty array '[]' = sees nothing. The Node layer
-- (CommonMasterRepo.getAllCommonMasters) only attaches `hierarchy` for
-- these 5 masterFields — every other masterField keeps calling these SPs
-- with zero parameters exactly as before, so no other master type is
-- affected by this migration.
--
-- KNOWN LIMITATION: sp_nt_GetUserHierarchy (the source of every
-- @HierarchyJson value across this whole rollout) only returns
-- com_sno/div_sno/brn_sno — it drops dept_sno even though nt_user_
-- permissions_json.hierarchy_json can carry a dept_sno per row. So
-- DeptMaster filtering below can only narrow to "which branches", not
-- "which specific department within an allowed branch" — a department-
-- scoped permission grant is treated as full-branch access here. This is a
-- pre-existing gap in the shared hierarchy-resolution proc, not something
-- introduced by this file; fixing it means threading dept_sno through
-- sp_nt_GetUserHierarchy and every consumer, a larger follow-up.
-- ============================================================

CREATE OR ALTER   PROCEDURE [dbo].[sp_nt_GetCompanyRecords]
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');

    BEGIN TRY
        SELECT v.*
        FROM vw_company_address v
        WHERE (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno') h
                WHERE h.com_sno = v.com_sno
            )
        );
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

-- sp_nt_GetMyPRTracking
-- ============================================================
-- PR Tracking — surface approver NAMES and the full multi-stage chain
-- Database : Non_trade_Dev (MSSQL, 10.0.21.8)
--
-- Follow-up to sql/29_pr_tracking.sql, based on user feedback after the
-- first live walkthrough: the "PR Approval" stage only showed a generic
-- "Pending" status with no indication of WHO it's pending with, and no view
-- of the full approval chain (e.g. "Stage 1: KTM1148 -> Stage 2: KTM1006").
--
-- All 4 objects touched here are ones this feature itself created in file
-- 29 (not pre-existing/UAT procedures) — CREATE OR ALTER is safe, same as
-- every other proc in that file.
--
-- Root cause: the existing (pre-dates this feature, NOT touched)
-- vw_PR_Basic_Info.pr_history_data subquery omits status/approver_ecno/
-- ordering — it only has {status_by, ename, status_date, commends,
-- pr_edit_data}, no way to tell approve vs reject or which stage. Rather
-- than alter that view (also read by sp_get_pr_details_for_approval, which
-- UAT is actively using), this adds two new result sets to
-- sp_nt_GetPRTrackingTimeline that resolve the full stage chain (from
-- workflow_stage.stage_order_json) and the full ordered history (straight
-- from pr_history_data, not the view) independently.
-- ============================================================

-- ── 1. sp_nt_GetMyPRTracking — add current_approver_name ───────────────────
CREATE OR ALTER   PROCEDURE dbo.sp_nt_GetMyPRTracking
    @ecno VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        pbf.pr_basic_sno,
        pbf.pr_no,
        pbf.status                 AS pr_status,
        pbf.purpose,
        pbf.required_date,
        pbf.created_date,
        vadr.com_name, vadr.div_name, vadr.brn_name, vadr.dept_name,
        pbf.current_approver_id,
        vve_approver.ename         AS current_approver_name,
        sq.sq_basic_sno,
        sq.status                  AS quotation_status,
        po.po_basic_sno,
        po.status                  AS po_status,
        po.supplier_ack_status,
        po.po_pdf_url,
        ds.dispatch_slip_sno,
        ge.gate_entry_sno,
        ge.status                  AS gate_entry_status,
        grn.grn_basic_sno,
        grn.status                 AS grn_status,
        CASE
            WHEN grn.grn_basic_sno IS NOT NULL AND grn.status IN ('Received', 'Partial') THEN 'Received Stock'
            WHEN grn.grn_basic_sno IS NOT NULL                                            THEN 'GRN'
            WHEN ge.gate_entry_sno IS NOT NULL                                             THEN 'Gate Entry'
            WHEN ds.dispatch_slip_sno IS NOT NULL                                          THEN 'Dispatched'
            WHEN po.po_basic_sno IS NOT NULL AND po.status = 'A'                           THEN 'PO Sent / In Transit'
            WHEN po.po_basic_sno IS NOT NULL                                               THEN 'PO Approval'
            WHEN sq.sq_basic_sno IS NOT NULL                                               THEN 'Purchase Quotation'
            WHEN pbf.status = 'A'                                                          THEN 'PR Approved — Awaiting Quotation/PO'
            WHEN pbf.status = 'R'                                                          THEN 'PR Rejected'
            ELSE 'PR Approval Pending'
        END AS current_stage
    FROM dbo.pr_basic_info pbf
    INNER JOIN dbo.vw_ActiveDeptRecords vadr
        ON pbf.brn_sno = vadr.brn_sno AND pbf.dept_sno = vadr.dept_sno
    LEFT JOIN dbo.vw_verified_employees vve_approver
        ON vve_approver.ecno = pbf.current_approver_id
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.supplier_quotation_info
        WHERE pr_basic_sno = pbf.pr_basic_sno ORDER BY sq_basic_sno DESC
    ) sq
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.po_request_info
        WHERE pr_basic_sno = pbf.pr_basic_sno ORDER BY po_basic_sno DESC
    ) po
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.nt_dispatch_slip
        WHERE po_basic_sno = po.po_basic_sno ORDER BY dispatch_slip_sno DESC
    ) ds
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.nt_gate_entry
        WHERE po_basic_sno = po.po_basic_sno ORDER BY gate_entry_sno DESC
    ) ge
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.grn_basic_info
        WHERE po_basic_sno = po.po_basic_sno ORDER BY grn_basic_sno DESC
    ) grn
    WHERE pbf.created_by = @ecno AND pbf.is_active = 'Y'
    ORDER BY pbf.created_date DESC, pbf.pr_basic_sno DESC;
END;
GO

-- sp_nt_GetScreenPermissionRecords
CREATE OR ALTER   PROCEDURE [dbo].[sp_nt_GetScreenPermissionRecords]

AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SELECT * 
        FROM [Non_trade_Dev].[dbo].[permissions] WHERE is_active='Y';
    END TRY

    BEGIN CATCH
        SELECT  
            ERROR_NUMBER() AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage,
            ERROR_LINE() AS ErrorLine,
            ERROR_PROCEDURE() AS ErrorProcedure;
    END CATCH
END
GO

-- sp_nt_GetScreenRecords
CREATE OR ALTER   PROCEDURE [dbo].[sp_nt_GetScreenRecords]

AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SELECT * 
        FROM [Non_trade_Dev].[dbo].[screens] WHERE is_active='Y';
    END TRY

    BEGIN CATCH
        SELECT  
            ERROR_NUMBER() AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage,
            ERROR_LINE() AS ErrorLine,
            ERROR_PROCEDURE() AS ErrorProcedure;
    END CATCH
END
GO

-- sp_nt_GetSupplierQuotations
CREATE OR ALTER   PROCEDURE [dbo].[sp_nt_GetSupplierQuotations]  
    @pr_basic_sno INT,  
    @pr_no        VARCHAR(20)  
AS  
BEGIN  
    SET NOCOUNT ON;  
  
    SELECT  
        sq.*,  
        (  
            SELECT  
                sqi.sq_item_sno,  
                sqi.sq_basic_sno,  
                sqi.pr_item_sno,  
                sqi.prod_sno,  
                pm.prod_name,  
                sqi.specification,  
                sqi.qty        AS unit,  
                sqi.unit_price,  
                sqi.discount_pct,  
                sqi.tax_pct,  
                sqi.total_amount,  
                sqi.delivery_days,  
                sqi.remarks,  
                sqi.is_active  
            FROM supplier_quotation_items sqi  
            INNER JOIN product_master pm  
                ON sqi.prod_sno = pm.prod_sno  
            WHERE sqi.sq_basic_sno = sq.sq_basic_sno  
            FOR JSON PATH  
        ) AS sq_items,
        (
            SELECT
                sa.sq_adv_sno,
                sa.sq_basic_sno,
                sa.quotation_ref_no,
                sa.payment_terms,
                sa.advance_payment_pct,
                sa.gst_applicable,
                sa.gst_pct,
                sa.reason,
                sa.note,
                sa.adv_issue_stages,
                sa.is_active,
                sa.created_by,
                sa.created_date
            FROM [Non_trade_Dev].[dbo].[supplier_advance] sa
            WHERE sa.sq_basic_sno = sq.sq_basic_sno
            FOR JSON PATH
        ) AS supplier_advance
    FROM supplier_quotation_info sq  
    WHERE  
        sq.is_active   = 1  
        AND sq.pr_basic_sno = @pr_basic_sno  
        AND sq.pr_no        = @pr_no;  
END;

GO

-- sp_nt_GetTermsConditionsRecords
-- ============================================================
-- Company/Division/Branch access scoping — finish wiring an already
-- partially-built feature.
-- Database: Non_trade_Dev (MSSQL)
--
-- sp_nt_GetUserHierarchy, sp_get_pr_details_for_approval and
-- sp_nt_GetQuotationsForApproval already exist live with an @HierarchyJson
-- parameter (a prior, half-finished attempt at this same feature — no
-- matching Node code was ever committed). Those three needed NO SQL change,
-- only Node-side wiring (see backend-stpl/src/Middleware/hierarchyScope.js
-- and the PR/PO repository changes in this same commit).
--
-- sp_nt_GetApprovedPRsForPurchase also already has @HierarchyJson and uses
-- it correctly — its bug was purely on the Node side (PurchaseTeamRepository
-- wrapped it in a generic @jsonInput blob the SP never declared, so the
-- param was silently never bound). Also fixed in Node only, no SQL change.
--
-- This file's only actual schema/proc change: sp_nt_GetTermsConditionsRecords
-- had no scoping at all — every caller saw every company's T&C rows. Adding
-- the same optional @HierarchyJson pattern as the other procs above.
--
-- Convention (matches the existing procs, do not deviate): @HierarchyJson is
-- an OPENJSON array of {com_sno, div_sno, brn_sno}. NULL means "no filter"
-- (kept only for callers that intentionally want everything, e.g. future
-- admin tooling). The application layer is responsible for the actual
-- access-control default: an ecno with zero hierarchy_json rows must be
-- sent '[]' (an empty JSON array), never NULL, so EXISTS(...) is false for
-- every row and the caller sees nothing until an admin assigns them a
-- company/division/branch. See hierarchyScope.js for where that's enforced.
-- ============================================================

CREATE OR ALTER   PROCEDURE dbo.sp_nt_GetTermsConditionsRecords
    @HierarchyJson NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.tc_sno,
        t.tc_title,
        t.tc_text,
        t.com_sno,  c.com_name,
        t.div_sno,  d.div_name,
        t.brn_sno,  b.brn_name,
        t.dept_sno, dm.dept_name,
        t.is_default,
        t.is_active,
        t.created_by,
        CONVERT(VARCHAR(30), t.created_date, 120)  AS created_date,
        t.modified_by,
        CONVERT(VARCHAR(30), t.modified_date, 120) AS modified_date
    FROM dbo.terms_conditions_master t
    JOIN dbo.company_master  c  ON c.com_sno   = t.com_sno
    JOIN dbo.division_master d  ON d.div_sno   = t.div_sno
    JOIN dbo.branch_master   b  ON b.brn_sno   = t.brn_sno
    JOIN dbo.dept_master     dm ON dm.dept_sno = t.dept_sno
    WHERE t.is_active = 'Y'
      AND (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = t.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = t.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = t.brn_sno)
          )
      )
    ORDER BY c.com_name, d.div_name, b.brn_name, dm.dept_name, t.is_default DESC, t.tc_title;
END;
GO

-- sp_nt_GetUserHierarchy
-- ============================================================
-- Fix: department-level access grants were silently widened to full-branch
-- access, and inventory items never carried a department at all.
-- Database: Non_trade_Dev (MSSQL)
--
-- Root cause (KTM1006's "given access only to Canteen but sees all
-- inventory" report, 2026-09-15):
--
-- 1. sp_nt_GetUserHierarchy (the single shared source every @HierarchyJson
--    filter in this rollout reads from — see [project-ecno-org-scope-and-
--    grn-fifo] memory) only ever returned com_sno/div_sno/brn_sno. Even a
--    correctly department-scoped hierarchy_json row like {com:1,div:3,
--    brn:4,dept:16} came back as just {com:1,div:3,brn:4} — indistinguishable
--    from real full-branch access. Fixed here: dept_sno now included.
--    Safe/additive for every other already-scoped endpoint (PR/PO/
--    PurchaseTeam/TermsConditions/GRN/StockRequests/Masters) — their own
--    OPENJSON...WITH clauses don't project dept_sno, so the extra field is
--    silently ignored there; only a consumer that explicitly adds a
--    dept_sno column to its WITH clause (sp_nt_GetInventoryItems below)
--    actually gains department precision.
--
-- 2. Separately, UserRoleApprovalScreen.tsx's buildHierarchyPayload()
--    treats selectedCompanies/selectedDivisions/selectedBranches/
--    selectedDepartments as four INDEPENDENT arrays and writes one
--    hierarchy_json row per selected id at EVERY level, not just the
--    deepest one. Drilling down through the company/division/branch
--    pickers to reach a department (a natural interaction, since each
--    list is filtered by the parent's selection) checks each intermediate
--    level along the way, and each becomes its own full-width grant. This
--    is why KTM1006 ended up with three rows — {com:1}, {com:1,div:3},
--    {com:1,div:3,brn:4} — and no dept:16 row at all: the department step
--    was never actually reached/checked. Not fixed by this SQL file (it's
--    a frontend/UX issue) — KTM1006's bad rows are corrected by hand below,
--    and admins granting department-only access need to leave the
--    Company/Division/Branch pickers unchecked and select only the
--    Department, until that screen is reworked.
--
-- 3. Even with correct hierarchy_json, nt_inventory_items never had a
--    dept_sno populated on receipt — sp_nt_UpsertInventoryItemByProduct
--    (called from grn-service's receiveFromGRN, which DOES already
--    resolve dept_sno from the GRN's own org context) never accepted or
--    stored it. Fixed in grn-service/sql/34_inventory_dept_scope_fix.sql,
--    which also backfills the 3 existing Canteen items (Carrot/Tomato/
--    Onion, all received under dept_sno=16 per their real GRN history)
--    since they predate this fix and would otherwise stay invisible to a
--    correctly department-scoped user forever.
-- ============================================================

CREATE OR ALTER   PROCEDURE dbo.sp_nt_GetUserHierarchy
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX);
    SELECT TOP 1 @HierarchyJson = hierarchy_json
    FROM dbo.nt_user_permissions_json
    WHERE ecno = @Ecno AND is_active = 'Y'
    ORDER BY user_perm_json_sno DESC;

    SELECT com_sno, div_sno, brn_sno, dept_sno
    FROM OPENJSON(@HierarchyJson)
    WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno', dept_sno INT '$.dept_sno');
END;
GO

-- sp_nt_LogPOSentToSupplier
-- ============================================================
-- PR Requester Tracking — read-only aggregation layer
-- Database : Non_trade_Dev (MSSQL, 10.0.21.8)
-- Used by  : new backend-stpl/src/PRTracking module (Node)
--
-- IMPORTANT — nothing existing is touched. UAT is currently exercising
-- usp_InsertPurchaseRequest / sp_approve_pr_datas / the quotation and PO
-- approval procedures live, so this file creates ONLY brand-new objects
-- (no CREATE OR ALTER, no DROP+CREATE on anything that already exists) and
-- reads from existing tables/views without writing to any of them except
-- one new additive INSERT-only procedure (#1 below). Nothing here can change
-- the behaviour of a procedure UAT is currently mid-flow on.
--
-- Discovery note: pr_history_data (pr_basic_sno, pr_edit_data, is_active,
-- workflow_types_id, approver_ecno, status, status_by, status_date, commends,
-- pr_no) already exists live and is already populated by sp_approve_pr_datas
-- on every approve/reject — it was simply never checked into this repo's sql/
-- folder before now (same situation usp_InsertPurchaseRequest was in until
-- 06_usp_InsertPurchaseRequest_v2.sql). No new PR audit table is needed —
-- this file only reads it, via the existing vw_PR_Basic_Info view which
-- already nests it as JSON.
--
-- Contents:
--   1. sp_nt_LogPOSentToSupplier   — new, additive INSERT into the existing
--      po_history_data table. Call this from PurchaseTeamService.sendPOEmail
--      right after a successful send; today nothing logs that transition.
--   2. sp_nt_GetPRTrackingTimeline — new, one PR's full journey (PR header +
--      history, Quotation, PO + history, Dispatch, Gate Entry, GRN + history,
--      Inventory movements) as multiple result sets, all joined via
--      pr_basic_sno -> po_request_info.pr_basic_sno -> po_basic_sno, the same
--      FK chain every existing downstream table already uses.
--   3. sp_nt_GetMyPRTracking       — new, the caller's own PRs with a
--      computed current_stage, for a "My Requests" list.
--   4. sp_nt_GetOrgPRTracking      — new, pending/active PRs within an org
--      scope (com/div/brn/dept), for the permission-gated "Team / Org View".
--   5. sp_nt_GetPrNoByPoBasicSno   — new, tiny lookup so grn-service/PurchaseTeam
--      touch points (which only carry po_basic_sno) can resolve which
--      pr:track:{pr_no} room to broadcast into.
--   6. sp_nt_HasScreenPermission   — new, server-side check of the existing
--      screens/permissions grant, gating the "Team / Org View" endpoint.
--   7. Screens row for the new PRTrackingPage, same pattern as every prior
--      screen registration in this series (e.g.
--      24_service_bill_request_screens_and_backfill.sql) — reuses the
--      existing sp_nt_GrantScreenToUser, no new grant mechanism.
--
-- Deliberately NOT done: no org columns added to nt_gate_entry /
-- nt_dispatch_slip / nt_dispatch_slip_delivery / nt_transport_master — every
-- query below reaches them through po_basic_sno, which is already resolved
-- from a com/div/brn/dept-scoped pr_basic_info/po_request_info row.
-- ============================================================

-- ── 1. sp_nt_LogPOSentToSupplier ────────────────────────────────────────────
-- Additive audit row only. Never called in a way that can fail the actual
-- PO-send response — see PurchaseTeamService.sendPOEmail wiring.
CREATE OR ALTER   PROCEDURE dbo.sp_nt_LogPOSentToSupplier
    @po_basic_sno INT,
    @status_by    VARCHAR(20),
    @comment      VARCHAR(250) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
    VALUES (@po_basic_sno, 'SENT_TO_SUPPLIER', @status_by, @comment, 'Y');

    SELECT 'LOGGED' AS result, @po_basic_sno AS po_basic_sno, SCOPE_IDENTITY() AS po_history_sno;
END;
GO

-- sp_nt_sign_up

CREATE OR ALTER   PROCEDURE [dbo].[sp_nt_sign_up]  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
      
    BEGIN TRY  
        BEGIN TRANSACTION;  
       
        -- Validate JSON input  
        IF @jsonInput IS NULL OR @jsonInput = '' OR NOT ISJSON(@jsonInput) = 1  
        BEGIN  
            THROW 50001, 'Invalid or empty JSON input provided', 1;  
        END  
          
        -- Insert into nt_sign_up table with lookup from vw_verified_employees
        INSERT INTO nt_sign_up (  
            ecno, com_sno, div_sno, brn_sno, dept_sno, sign_up_cug,   
            sign_up_pass, sign_up_otp, nt_menu_sno, fingerprint_mantra_mfs, branch, dept ,is_active,workflow_id
        )  
        SELECT  
            CAST(j.ecno AS VARCHAR(10)),   
            CAST(j.com_sno AS INT),   
            CAST(j.div_sno AS INT),   
            CAST(j.brn_sno AS INT),   
            CAST(j.dept_sno AS INT),   
            CASE   
                WHEN j.sign_up_cug = '' OR j.sign_up_cug IS NULL THEN NULL   
                ELSE CAST(j.sign_up_cug AS BIGINT)   
            END,  
            CASE   
                WHEN LEN(j.sign_up_pass) > 15 THEN LEFT(CAST(j.sign_up_pass AS NVARCHAR(15)), 15)  
                ELSE CAST(j.sign_up_pass AS NVARCHAR(15))  
            END,  
            CASE   
                WHEN j.sign_up_otp = '' OR j.sign_up_otp IS NULL THEN NULL   
                ELSE CAST(j.sign_up_otp AS INT)   
            END,  
            CAST(j.nt_menu_sno AS NVARCHAR(MAX)),  
            CASE   
                WHEN LEN(j.fingerprint_mantra_mfs) > 100 THEN LEFT(CAST(j.fingerprint_mantra_mfs AS NVARCHAR(100)), 100)  
                ELSE CAST(j.fingerprint_mantra_mfs AS NVARCHAR(100))  
            END,
            v.branch,  -- Lookup from view
            v.dept,-- Lookup from view
            'Y',
            8
        FROM OPENJSON(@jsonInput)  
        WITH (  
            ecno NVARCHAR(50) '$.ecno',  
            com_sno NVARCHAR(50) '$.com_sno',  
            div_sno NVARCHAR(50) '$.div_sno',  
            brn_sno NVARCHAR(50) '$.brn_sno',  
            dept_sno NVARCHAR(50) '$.dept_sno',  
            sign_up_cug NVARCHAR(50) '$.sign_up_cug',  
            sign_up_pass NVARCHAR(MAX) '$.sign_up_pass',  
            sign_up_otp NVARCHAR(50) '$.sign_up_otp',  
            nt_menu_sno NVARCHAR(MAX) '$.nt_menu_sno',  
            fingerprint_mantra_mfs NVARCHAR(MAX) '$.fingerprint_mantra_mfs'  
        ) AS j
        LEFT JOIN [Non_trade_Dev].[dbo].[vw_verified_employees] v ON v.ecno = j.ecno;
          
        -- Return success message with row count  
        SELECT 'SUCCESS' as Status, @@ROWCOUNT as RowsAffected;  
          
        COMMIT TRANSACTION;  
          
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
          
        -- Return detailed error information  
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();  
        DECLARE @ErrorNumber INT = ERROR_NUMBER();  
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();  
        DECLARE @ErrorState INT = ERROR_STATE();  
          
        SELECT   
            'ERROR' as Status,  
            @ErrorNumber as ErrorNumber,  
            @ErrorMessage as ErrorMessage,  
            @ErrorSeverity as ErrorSeverity,  
            @ErrorState as ErrorState;  
          
        -- Re-throw the error for upstream handling  
        THROW;  
    END CATCH  
END

GO

-- sp_nt_UpsertInventoryItemByProduct
-- ============================================================
-- Fix: nt_inventory_items never carried a department, so department-scoped
-- access (e.g. "Canteen only") could never actually narrow the Inventory
-- list — see backend-stpl/sql/80_dept_scope_fix.sql for the full root-cause
-- writeup (KTM1006's report, 2026-09-15).
-- Database: Non_trade_Dev (MSSQL)
--
-- sp_nt_UpsertInventoryItemByProduct already receives dept_sno in its
-- caller's orgScope (grn-service/src/inventory/inventory.service.js's
-- receiveFromGRN, which resolves it from the GRN's own dept_sno — itself
-- traced from the originating PR) but silently dropped it: not accepted as
-- a parameter, not part of the item-matching WHERE, not stored, not
-- returned. All four fixed here, additively — items with no department
-- context (dept_sno IS NULL on both sides) match exactly as before.
-- ============================================================

CREATE OR ALTER   PROCEDURE [dbo].[sp_nt_UpsertInventoryItemByProduct]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @prod_sno     INT          = JSON_VALUE(@jsonInput, '$.prod_sno');
    DECLARE @prod_name    VARCHAR(255) = JSON_VALUE(@jsonInput, '$.prod_name');
    DECLARE @uom_name     VARCHAR(20)  = JSON_VALUE(@jsonInput, '$.uom_name');
    DECLARE @com_sno      INT          = JSON_VALUE(@jsonInput, '$.com_sno');
    DECLARE @div_sno      INT          = JSON_VALUE(@jsonInput, '$.div_sno');
    DECLARE @brn_sno      INT          = JSON_VALUE(@jsonInput, '$.brn_sno');
    DECLARE @dept_sno     INT          = JSON_VALUE(@jsonInput, '$.dept_sno');
    DECLARE @location_sno INT          = JSON_VALUE(@jsonInput, '$.location_sno');

    IF @prod_sno IS NULL
    BEGIN
        RAISERROR('prod_sno is required.', 16, 1);
        RETURN;
    END

    DECLARE @location VARCHAR(100);

    IF @location_sno IS NOT NULL
        SELECT @location = location_code
        FROM dbo.warehouse_location_master
        WHERE location_sno = @location_sno;

    DECLARE @item_sno INT;

    -- NULL-safe match: a receipt with no branch/department hits the
    -- no-branch/no-department row only, never some other branch's or
    -- department's stock.
    SELECT @item_sno = item_sno
    FROM dbo.nt_inventory_items
    WHERE prod_sno = @prod_sno
      AND ((@com_sno  IS NULL AND com_sno  IS NULL) OR com_sno  = @com_sno)
      AND ((@div_sno  IS NULL AND div_sno  IS NULL) OR div_sno  = @div_sno)
      AND ((@brn_sno  IS NULL AND brn_sno  IS NULL) OR brn_sno  = @brn_sno)
      AND ((@dept_sno IS NULL AND dept_sno IS NULL) OR dept_sno = @dept_sno);

    IF @item_sno IS NULL
    BEGIN
        DECLARE @item_code VARCHAR(50) =
            'AUTO-' + CAST(@prod_sno AS VARCHAR(20))
            + CASE WHEN @brn_sno IS NOT NULL
                   THEN '-B' + CAST(@brn_sno AS VARCHAR(20))
                   ELSE ''
              END
            + CASE WHEN @dept_sno IS NOT NULL
                   THEN '-D' + CAST(@dept_sno AS VARCHAR(20))
                   ELSE ''
              END;

        INSERT INTO dbo.nt_inventory_items (
            item_code, item_name, category, uom, current_stock, min_stock,
            max_stock, reorder_qty, warehouse, location, cost_price, selling_price,
            status, prod_sno, com_sno, div_sno, brn_sno, dept_sno, created_by, created_at
        )
        VALUES (
            @item_code,
            ISNULL(@prod_name, 'Product ' + CAST(@prod_sno AS VARCHAR(20))),
            'Raw Material', ISNULL(@uom_name, 'Nos'), 0, 0,
            0, 0, 'Main Warehouse', ISNULL(@location, 'B1'), 0, 0,
            'Active', @prod_sno, @com_sno, @div_sno, @brn_sno, @dept_sno, 'system', GETDATE()
        );

        SET @item_sno = SCOPE_IDENTITY();
    END
    ELSE IF @location IS NOT NULL
    BEGIN
        UPDATE dbo.nt_inventory_items
        SET location   = @location,
            updated_at = GETDATE()
        WHERE item_sno = @item_sno;
    END

    SELECT item_sno, item_code, item_name, uom, current_stock, warehouse, location,
           com_sno, div_sno, brn_sno, dept_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;
GO

-- sp_product_catagory
  CREATE OR ALTER   PROCEDURE [dbo].[sp_product_catagory] 
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        SELECT [cat_sno]
      ,[cat_name]
      ,[cat_description]
      ,[cat_notes]
       FROM [Non_trade_Dev].[dbo].[category_master] 
WHERE cat_active='Y' 
ORDER BY cat_sno;
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        -- Re-throw the original error
        THROW;
    END CATCH
END
GO

-- sp_product_sub_catagory
CREATE OR ALTER   PROCEDURE [dbo].[sp_product_sub_catagory]
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SELECT sc.[subcat_sno]
              ,sc.[subcat_name]
              ,sc.[subcat_description]
              ,sc.[subcat_notes]
              ,sc.[subcat_stock_type]
              ,sc.[cat_sno]
              ,cm.[cat_name]
        FROM [Non_trade_Dev].[dbo].[subcategory_master] sc
        INNER JOIN [Non_trade_Dev].[dbo].[category_master] cm ON cm.cat_sno = sc.cat_sno
        WHERE sc.subcat_active = 'Y'
        ORDER BY sc.subcat_sno;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

-- usp_GetPendingForEcno
CREATE OR ALTER   PROCEDURE [dbo].[usp_GetPendingForEcno]
  @ecno NVARCHAR(50)
AS
BEGIN
  SET NOCOUNT ON;

  ;WITH FlowSteps AS (
    SELECT af.nt_app_flow_sno, s.step_no, s.step_ecno
    FROM Non_trade_Dev.dbo.nt_approval_flow af
    CROSS APPLY ( VALUES
       (1, af.nt_app_flow_step1_ecno),
       (2, af.nt_app_flow_step2_ecno),
       (3, af.nt_app_flow_step3_ecno),
       (4, af.nt_app_flow_step4_ecno),
       (5, af.nt_app_flow_step5_ecno),
       (6, af.nt_app_flow_step6_ecno),
       (7, af.nt_app_flow_step7_ecno),
       (8, af.nt_app_flow_step8_ecno),
       (9, af.nt_app_flow_step9_ecno),
       (10, af.nt_app_flow_step10_ecno),
       (11, af.nt_app_flow_step11_ecno),
       (12, af.nt_app_flow_step12_ecno),
       (13, af.nt_app_flow_step13_ecno)
    ) s(step_no, step_ecno)
  ),
ApprovedHistory AS (
    SELECT nh.nt_app_flow_sno,
           TRY_CAST(nh.nt_app_his_auth_selection AS INT) AS step_no
    FROM Non_trade_Dev.dbo.nt_approval_history nh
    WHERE nh.nt_app_his_status = 'A'
      AND nh.is_active = 'Y'
),
RejectedHistory AS (
    SELECT nh.nt_app_flow_sno,
           TRY_CAST(nh.nt_app_his_auth_selection AS INT) AS step_no
    FROM Non_trade_Dev.dbo.nt_approval_history nh
    WHERE nh.nt_app_his_status = 'R'
      AND nh.is_active = 'Y'
),
CurrentStep AS (
    SELECT
      bde.bud_dta_sno,
      bde.bud_sno,
      bde.nt_app_flow_sno,
      (SELECT MIN(fs.step_no)
       FROM FlowSteps fs
       WHERE fs.nt_app_flow_sno = bde.nt_app_flow_sno
         AND fs.step_ecno IS NOT NULL
         AND NOT EXISTS (
             SELECT 1 FROM ApprovedHistory ah
             WHERE ah.nt_app_flow_sno = fs.nt_app_flow_sno
               AND ah.step_no = fs.step_no
         )
         AND NOT EXISTS (
           SELECT 1 FROM FlowSteps prev
           WHERE prev.nt_app_flow_sno = fs.nt_app_flow_sno
             AND prev.step_no < fs.step_no
             AND prev.step_ecno IS NOT NULL
             AND NOT EXISTS (
                 SELECT 1 FROM ApprovedHistory ah2
                 WHERE ah2.nt_app_flow_sno = prev.nt_app_flow_sno
                   AND ah2.step_no = prev.step_no
             )
         )
      ) AS current_step_no
    FROM Non_trade_Dev.dbo.budget_data_entries bde
    WHERE bde.is_active = 'Y'
)
 
SELECT
    cs.bud_dta_sno,
    cs.bud_sno,
    cs.nt_app_flow_sno,
    cs.current_step_no,
    fs.step_ecno AS current_step_ecno,
    bm.bud_code,
    bm.dept_sno,
    bm.com_sno,
    bde.bud_dta_desc,
    bde.bud_dta_ctg,
    bde.bud_dta_req_qty,
    bde.uom_sno,
    bde.bud_dta_unt_cst,
    bde.created_date
FROM CurrentStep cs
INNER JOIN FlowSteps fs
    ON fs.nt_app_flow_sno = cs.nt_app_flow_sno
   AND fs.step_no = cs.current_step_no
   AND fs.step_ecno = @ecno   -- ✅ filter here only for actual current step approver
INNER JOIN Non_trade_Dev.dbo.budget_data_entries bde
    ON bde.bud_dta_sno = cs.bud_dta_sno
LEFT JOIN Non_trade_Dev.dbo.budget_master bm
    ON bm.bud_sno = bde.bud_sno
WHERE cs.current_step_no IS NOT NULL
ORDER BY bde.created_date DESC;

END
GO

-- usp_ProcessApprovalAction
CREATE OR ALTER   PROCEDURE [dbo].[usp_ProcessApprovalAction]
  @bud_dta_sno INT,
  @nt_app_flow_sno INT,
  @ecno NVARCHAR(50),
  @action NVARCHAR(20),          -- 'Approve', 'Reject', 'Hold'
  @comments NVARCHAR(MAX) = NULL,
  @value_change DECIMAL(18,4) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  BEGIN TRY
    BEGIN TRAN;

    -- basic validation: is ecno the current approver?
    DECLARE @current_step_no INT;
    ;WITH FlowSteps AS (
      SELECT fs.step_no, fs.step_ecno
      FROM Non_trade_Dev.dbo.nt_approval_flow af
      CROSS APPLY ( VALUES
         (1, af.nt_app_flow_step1_ecno),
         (2, af.nt_app_flow_step2_ecno),
         (3, af.nt_app_flow_step3_ecno),
         (4, af.nt_app_flow_step4_ecno),
         (5, af.nt_app_flow_step5_ecno),
         (6, af.nt_app_flow_step6_ecno),
         (7, af.nt_app_flow_step7_ecno),
         (8, af.nt_app_flow_step8_ecno),
         (9, af.nt_app_flow_step9_ecno),
         (10, af.nt_app_flow_step10_ecno),
         (11, af.nt_app_flow_step11_ecno),
         (12, af.nt_app_flow_step12_ecno),
         (13, af.nt_app_flow_step13_ecno)
      ) fs(step_no, step_ecno)
      WHERE af.nt_app_flow_sno = @nt_app_flow_sno
    ),
    Approved AS (
      SELECT TRY_CAST(nh.nt_app_his_auth_selection AS INT) AS step_no
      FROM Non_trade_Dev.dbo.nt_approval_history nh
      WHERE nh.nt_app_flow_sno = @nt_app_flow_sno
        AND nh.nt_app_his_status = 'A'
        AND nh.is_active = 1
    )
    SELECT @current_step_no = MIN(fs.step_no)
    FROM FlowSteps fs
    WHERE fs.step_ecno IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM Approved a WHERE a.step_no = fs.step_no)
      AND NOT EXISTS (  -- ensure earlier steps are approved or absent
         SELECT 1 FROM FlowSteps prev
         WHERE prev.step_no < fs.step_no
           AND prev.step_ecno IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Approved a2 WHERE a2.step_no = prev.step_no)
      );

    IF @current_step_no IS NULL
    BEGIN
      RAISERROR('No pending step found for this flow/item - cannot process approval.', 16, 1);
      ROLLBACK TRAN;
      RETURN;
    END

    -- confirm @ecno matches current step ecno
    DECLARE @expected_ecno NVARCHAR(50);
    SELECT @expected_ecno = fs.step_ecno
    FROM (
      SELECT af.*, fs.step_no, fs.step_ecno
      FROM Non_trade_Dev.dbo.nt_approval_flow af
      CROSS APPLY ( VALUES
         (1, af.nt_app_flow_step1_ecno),
         (2, af.nt_app_flow_step2_ecno),
         (3, af.nt_app_flow_step3_ecno),
         (4, af.nt_app_flow_step4_ecno),
         (5, af.nt_app_flow_step5_ecno),
         (6, af.nt_app_flow_step6_ecno),
         (7, af.nt_app_flow_step7_ecno),
         (8, af.nt_app_flow_step8_ecno),
         (9, af.nt_app_flow_step9_ecno),
         (10, af.nt_app_flow_step10_ecno),
         (11, af.nt_app_flow_step11_ecno),
         (12, af.nt_app_flow_step12_ecno),
         (13, af.nt_app_flow_step13_ecno)
      ) fs(step_no, step_ecno)
      WHERE af.nt_app_flow_sno = @nt_app_flow_sno
    ) AS fs
    WHERE fs.step_no = @current_step_no;

    IF ISNULL(@expected_ecno,'') <> @ecno
    BEGIN
      RAISERROR('User [%s] is not the current approver (expected %s).', 16, 1, @ecno, @expected_ecno);
      ROLLBACK TRAN;
      RETURN;
    END

    -- Insert into history
    INSERT INTO Non_trade_Dev.dbo.nt_approval_history
    (
	--nt_app_flow_sno,
      nt_app_li_sno,
      brn_sno,
      dept_sno,
      com_sno,
      div_sno,
      reference_no,
      nt_app_his_auths,          -- store approver ecno
      nt_app_his_auth_selection, -- store step no
      nt_app_his_status,
      nt_app_his_comments,
      nt_app_his_status_date,
      is_active,
      created_date
    )
    SELECT
      --af.nt_app_flow_sno,
      af.nt_app_li_sno,
      af.brn_sno,
      af.dept_sno,
      af.com_sno,
      af.div_sno,
      NULL, -- reference_no: fill if you have a meaningful ref (e.g. bud_dta_sno)
      @ecno,
      CAST(@current_step_no AS NVARCHAR(10)),
      CASE WHEN @action = 'A' THEN 'A'
           WHEN @action = 'R' THEN 'R'
           WHEN @action = 'P' THEN 'P'
           ELSE @action END,
      @comments,
      GETDATE(),
      1,
      GETDATE()
    FROM Non_trade_Dev.dbo.nt_approval_flow af
    WHERE af.nt_app_flow_sno = @nt_app_flow_sno;

    -- Apply any value change to budget_data_entries if provided (example)
    IF @value_change IS NOT NULL
    BEGIN
      UPDATE Non_trade_Dev.dbo.budget_data_entries
      SET bud_dta_act_unt_cst = @value_change,
          -- track updated date if you have such column, else ignore
          created_date = created_date
      WHERE bud_dta_sno = @bud_dta_sno;
    END

    -- If action = Reject => potentially mark item as rejected (business rule dependent)
    IF @action = 'R'
    BEGIN
      -- mark item inactive or set a status column if exists (example: is_active = 0)
      UPDATE Non_trade_Dev.dbo.budget_data_entries
      SET is_active = 0
      WHERE bud_dta_sno = @bud_dta_sno;
      -- leave transaction and return no next approver
      COMMIT TRAN;
      SELECT NULL AS next_approver_ecno, NULL AS next_step_no, 'R' AS final_status;
      RETURN;
    END

    -- If action was Approve: find next step
    DECLARE @next_step_no INT;
    DECLARE @next_approver_ecno NVARCHAR(50);

    SELECT TOP(1) @next_step_no = fs.step_no, @next_approver_ecno = fs.step_ecno
    FROM (
      SELECT fs.step_no, fs.step_ecno
      FROM Non_trade_Dev.dbo.nt_approval_flow af
      CROSS APPLY ( VALUES
         (1, af.nt_app_flow_step1_ecno),
         (2, af.nt_app_flow_step2_ecno),
         (3, af.nt_app_flow_step3_ecno),
         (4, af.nt_app_flow_step4_ecno),
         (5, af.nt_app_flow_step5_ecno),
         (6, af.nt_app_flow_step6_ecno),
         (7, af.nt_app_flow_step7_ecno),
         (8, af.nt_app_flow_step8_ecno),
         (9, af.nt_app_flow_step9_ecno),
         (10, af.nt_app_flow_step10_ecno),
         (11, af.nt_app_flow_step11_ecno),
         (12, af.nt_app_flow_step12_ecno),
         (13, af.nt_app_flow_step13_ecno)
      ) fs(step_no, step_ecno)
      WHERE af.nt_app_flow_sno = @nt_app_flow_sno
    ) AS fs
    WHERE fs.step_no > @current_step_no
      AND fs.step_ecno IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM Non_trade_Dev.dbo.nt_approval_history nh
        WHERE nh.nt_app_flow_sno = @nt_app_flow_sno
          AND TRY_CAST(nh.nt_app_his_auth_selection AS INT) = fs.step_no
          AND nh.nt_app_his_status = 'A'
          AND nh.is_active = 1
      )
    ORDER BY fs.step_no;

    IF @next_approver_ecno IS NULL
    BEGIN
      -- No more approvers -> mark final state on master if needed (example: update budget_master)
      UPDATE Non_trade_Dev.dbo.budget_master
      SET is_bud_value_approved = 1,
          bud_value_approved_by = @ecno,
          bud_value_approved_date = GETDATE()
      FROM Non_trade_Dev.dbo.budget_master bm
      INNER JOIN Non_trade_Dev.dbo.budget_data_entries bde ON bde.bud_sno = bm.bud_sno
      WHERE bde.bud_dta_sno = @bud_dta_sno;

      COMMIT TRAN;
      SELECT NULL AS next_approver_ecno, NULL AS next_step_no, 'FullyApproved' AS final_status;
      RETURN;
    END

    COMMIT TRAN;
    SELECT @next_approver_ecno AS next_approver_ecno, @next_step_no AS next_step_no, 'InProgress' AS final_status;
    RETURN;

  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRAN;
    DECLARE @errMsg NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR('Error in usp_ProcessApprovalAction: %s',16,1,@errMsg);
    RETURN;
  END CATCH
END

GO

-- ActiveBranches
CREATE OR ALTER   VIEW ActiveBranches  
AS  
SELECT    
  bm.brn_sno,  
  bm.brn_name,  
  bm.brn_prefix,  
  cm.com_name, 
  cm.com_sno,
  cm.com_prefix,  
  dm.div_name,
  dm.div_sno,
  dm.div_prefix,  
  dm.div_type,  
  am.add_door_no,  
  am.add_street,  
  am.add_city,  
  am.add_state,  
  am.add_state_code,  
  am.add_pin_code  
  
  FROM [Non_trade_Dev].[dbo].[branch_master] bm left join [Non_trade_Dev].[dbo].[company_master] cm on  
  bm.com_sno=cm.com_sno left join [Non_trade_Dev].[dbo].[division_master] dm on bm.div_sno =dm.div_sno   
  left join [Non_trade_Dev].[dbo].[address_master] am on bm.add_sno=am.add_sno where bm.is_active='Y'
GO

-- vw_ActiveDivisions
CREATE OR ALTER   VIEW [dbo].[vw_ActiveDivisions]  
AS  
SELECT   
    dm.div_sno AS div_sno,  
    dm.div_name AS div_name,  
dm.div_prefix as div_prefix,  
    dm.div_type AS div_type, 
    cm.com_sno AS com_sno,
    cm.com_name AS com_name,  
    cm.com_prefix AS com_prefix  
FROM [Non_trade_Dev].[dbo].[division_master] dm   
LEFT JOIN [Non_trade_Dev].[dbo].[company_master] cm   
    ON dm.com_sno = cm.com_sno   
WHERE dm.is_active = 'Y';
GO

-- vw_company_address
  CREATE OR ALTER   VIEW vw_company_address AS
SELECT 
    -- Company Master fields
    cm.com_sno AS com_sno ,
    cm.com_name AS com_name,
    cm.com_prefix AS com_prefix,
    cm.is_active AS is_active,
    cm.created_date AS created_date,
    
    -- Address Master fields
     am.add_pan AS add_pan,
    am.is_gst_applicable AS is_gst_applicable,
    am.add_gst AS add_gst,
    am.add_tan AS add_tan,
    am.add_cin AS add_cin,
    am.add_door_no AS add_door_no,
    am.add_street AS add_street,
    am.add_city AS add_city,
    am.add_state AS add_state,
    am.add_state_code AS add_state_code,
    am.add_pin_code AS add_pin_code,
    am.add_reg_door_no AS add_reg_door_no,
    am.add_reg_street AS add_reg_street,
    am.add_reg_city AS add_reg_city,
    am.add_reg_state AS add_reg_state,
    am.add_reg_pincode AS add_reg_pincode
    
FROM [Non_trade_Dev].[dbo].[company_master] cm
LEFT JOIN [Non_trade_Dev].[dbo].[address_master] am 
    ON cm.add_sno = am.add_sno where cm.is_active='Y' ;
GO
