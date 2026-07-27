ALTER PROCEDURE dbo.sp_nt_ApproveSupplierQuotation      
    @jsonInput NVARCHAR(MAX)      
AS      
BEGIN      
    SET NOCOUNT ON;      
    SET XACT_ABORT ON;      
      
    BEGIN TRY      
        ------------------------------------------------------------------      
        -- 1. Validate input      
        ------------------------------------------------------------------      
        IF ISJSON(@jsonInput) = 0      
        BEGIN      
            RAISERROR('Invalid JSON format for @jsonInput', 16, 1);      
            RETURN;      
        END      
      
        DECLARE @sq_basic_sno    INT            = TRY_CAST(JSON_VALUE(@jsonInput, '$.sq_basic_sno') AS INT),      
                @pr_no           VARCHAR(30)    = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.pr_no'))), ''),      
                @comments        VARCHAR(1000)  = JSON_VALUE(@jsonInput, '$.comments'),      
                @approval_stages NVARCHAR(MAX)  = JSON_QUERY(@jsonInput, '$.approval_stages'),      
                @approved_by     VARCHAR(30)    = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.approved_by'))), ''),      
                @transfer_to     VARCHAR(30)    = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.transfer_to_ecno'))), ''),      
                @action          VARCHAR(30)    = LOWER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.action'))));      
      
        IF @sq_basic_sno IS NULL      
        BEGIN      
            RAISERROR('sq_basic_sno is required.', 16, 1);      
            RETURN;      
        END      
      
        IF @action IS NULL OR @action NOT IN ('approve', 'reject', 'forward', 'backward')      
        BEGIN      
            RAISERROR('Invalid action. Use approve | reject | forward | backward.', 16, 1);      
            RETURN;      
        END      
      
        IF @approved_by IS NULL      
        BEGIN      
            RAISERROR('approved_by (approver EC number) is required.', 16, 1);      
            RETURN;      
        END      
      
        IF @action IN ('forward', 'backward')      
           AND @transfer_to IS NULL      
        BEGIN      
            RAISERROR('transfer_to_ecno is required for forward/backward.', 16, 1);      
            RETURN;      
        END      
      
        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0      
        BEGIN      
            RAISERROR('Invalid or missing approval_stages.', 16, 1);      
            RETURN;      
        END      
      
        ------------------------------------------------------------------      
        -- 2. Load quotation header      
        ------------------------------------------------------------------      
        DECLARE @pr_basic_sno      INT,      
                @vendor_sno        INT,      
                @com_sno           INT,      
                @div_sno           INT,      
                @brn_sno           INT,      
                @dept_sno          INT,      
                @workflow_types_id INT,      
                @cur_transfer_from VARCHAR(30),      
                @sq_pr_no          VARCHAR(30);      
      
        SELECT      
            @pr_basic_sno      = sq.pr_basic_sno,      
            @vendor_sno        = sq.vendor_sno,      
            @com_sno           = pr.com_sno,      
            @div_sno           = pr.div_sno,      
            @brn_sno           = sq.brn_sno,      
            @dept_sno          = sq.dept_sno,      
            @workflow_types_id = sq.workflow_types_id,      
            @cur_transfer_from = sq.transferred_from,      
            @sq_pr_no          = sq.pr_no      
        FROM supplier_quotation_info sq      
        INNER JOIN pr_basic_info pr ON pr.pr_basic_sno = sq.pr_basic_sno      
        WHERE sq.sq_basic_sno = @sq_basic_sno      
          AND sq.is_active = 1;      
      
        IF @pr_basic_sno IS NULL      
        BEGIN      
            RAISERROR('Invalid sq_basic_sno or inactive quotation.', 16, 1);      
            RETURN;      
        END      
      
        IF @pr_no IS NULL      
    SET @pr_no = @sq_pr_no;      
      
        ------------------------------------------------------------------      
        -- 3. Materialize approval stages into temp table      
        ------------------------------------------------------------------      
        CREATE TABLE #approval_stages (      
            seq_no             INT,      
            approver_ecno      VARCHAR(30),      
          stage              VARCHAR(100),      
            required_approvals VARCHAR(10),      
            is_mandatory       CHAR(1),      
            escalation_hours   VARCHAR(10),      
            approver_condition VARCHAR(200),      
            next_approver_ecno VARCHAR(30),      
            can_forward        CHAR(1),      
            can_backward       CHAR(1),      
            can_edit_data      CHAR(1)      
        );      
      
        INSERT INTO #approval_stages (      
            seq_no, approver_ecno, stage, required_approvals, is_mandatory,      
            escalation_hours, approver_condition, next_approver_ecno,      
            can_forward, can_backward, can_edit_data      
        )      
        SELECT      
            CAST(oj.[key] AS INT),      
            JSON_VALUE(oj.[value], '$.approver_ecno'),      
            JSON_VALUE(oj.[value], '$.stage'),      
            JSON_VALUE(oj.[value], '$.required_approvals'),      
            JSON_VALUE(oj.[value], '$.is_mandatory'),      
            JSON_VALUE(oj.[value], '$.escalation_hours'),      
            JSON_VALUE(oj.[value], '$.approver_condition'),      
            JSON_VALUE(oj.[value], '$.next_approver_ecno'),      
            JSON_VALUE(oj.[value], '$.can_forward'),      
            JSON_VALUE(oj.[value], '$.can_backward'),      
            JSON_VALUE(oj.[value], '$.can_edit_data')      
        FROM OPENJSON(@approval_stages) AS oj;      
      
        DECLARE @stage_ecno VARCHAR(30) =      
            CASE      
                WHEN EXISTS (SELECT 1 FROM #approval_stages WHERE approver_ecno = @approved_by)      
                    THEN @approved_by      
                ELSE @cur_transfer_from      
            END;      
      
        IF @action IN ('approve', 'forward', 'backward')      
           AND NOT EXISTS (SELECT 1 FROM #approval_stages WHERE approver_ecno = @stage_ecno)      
        BEGIN      
            RAISERROR('Current approver is not part of the approval workflow.', 16, 1);      
            RETURN;      
        END      
      
        BEGIN TRANSACTION;      
      
        ------------------------------------------------------------------      
        -- 4A. REJECT      
        -- Reject process for all quotations under same PR      
        ------------------------------------------------------------------      
        IF @action = 'reject'      
        BEGIN      
            INSERT INTO supplier_quotation_history (      
                sq_basic_sno, sq_edit_data, is_active, workflow_types_id,      
                approver_ecno, status, status_by, transferred_from,      
                transferred_to, comment, action_type, pr_basic_sno,      
                selected_by, pr_no      
            )      
            SELECT      
                sq.sq_basic_sno, NULL, 1, sq.workflow_types_id,      
                @approved_by, 'R', @approved_by, sq.transferred_from,      
                sq.transferred_to, @comments, 'REJECTED', sq.pr_basic_sno,      
                NULL, sq.pr_no      
            FROM supplier_quotation_info sq      
            WHERE sq.pr_no = @pr_no      
              AND sq.is_active = 1;      
      
            UPDATE supplier_quotation_info      
            SET status           = 'R',      
                approver_ecno    = NULL,      
                transferred_from = NULL,      
                transferred_to   = NULL,      
                modifed_by       = @approved_by,      
                modifed_date     = GETDATE()      
            WHERE pr_no = @pr_no      
              AND is_active = 1;      
      
            COMMIT TRANSACTION;      
            DROP TABLE #approval_stages;      
      
            SELECT 'REJECTED'    AS result,      
                   @sq_basic_sno AS sq_basic_sno,      
                   @pr_no        AS pr_no,      
                   @approved_by  AS rejected_by,      
                   GETDATE()     AS rejected_on,      
                   @comments     AS rejection_reason;      
            RETURN;      
        END      
      
        ------------------------------------------------------------------      
        -- 4B. FORWARD / BACKWARD      
        -- Update workflow columns for all quotations under same PR      
        -- Keep status as process flag only; do not touch is_selected      
        ------------------------------------------------------------------      
      IF @action IN ('forward', 'backward')      
        BEGIN      
            DECLARE @can CHAR(1);      
      
            SELECT @can =      
                CASE      
                    WHEN @action = 'forward' THEN can_forward      
                    ELSE can_backward      
                END      
            FROM #approval_stages      
            WHERE approver_ecno = @stage_ecno;      
      
            IF ISNULL(@can, 'N') <> 'Y'      
            BEGIN      
                ROLLBACK TRANSACTION;      
                DROP TABLE #approval_stages;      
                RAISERROR('Current approver is not allowed to %s.', 16, 1, @action);      
                RETURN;      
            END      
      
            INSERT INTO supplier_quotation_history (      
                sq_basic_sno, sq_edit_data, is_active, workflow_types_id,      
                approver_ecno, status, status_by, transferred_from,      
                transferred_to, comment, action_type, pr_basic_sno,      
                selected_by, pr_no      
            )      
            SELECT      
                sq.sq_basic_sno, NULL, 1, sq.workflow_types_id,      
                @transfer_to, sq.status, @approved_by, @approved_by,      
                @transfer_to, @comments, UPPER(@action), sq.pr_basic_sno,      
                sq.is_selected, sq.pr_no      
            FROM supplier_quotation_info sq      
            WHERE sq.pr_no = @pr_no      
              AND sq.is_active = 1;      
      
            UPDATE supplier_quotation_info      
            SET approver_ecno    = @transfer_to,      
                transferred_from = @approved_by,      
                transferred_to   = @transfer_to,      
                modifed_by       = @approved_by,      
                modifed_date     = GETDATE()      
            WHERE pr_no = @pr_no      
              AND is_active = 1;      
      
            COMMIT TRANSACTION;      
            DROP TABLE #approval_stages;      
      
            SELECT UPPER(@action) AS result,      
                   @sq_basic_sno  AS sq_basic_sno,      
                   @pr_no         AS pr_no,      
                   @approved_by   AS transferred_from,      
                   @transfer_to   AS transferred_to,      
                   GETDATE()      AS transferred_on;      
            RETURN;      
        END      
      
        ------------------------------------------------------------------      
        -- 4C. APPROVE — resolve next stage      
        -- Update workflow columns for all quotations under same PR      
        -- Keep final status/is_selected only for chosen quotation at final stage      
        ------------------------------------------------------------------      
        DECLARE @next_approver  VARCHAR(30),      
                @next_condition VARCHAR(200);      
      
        ;WITH stage_cte AS      
        (      
            SELECT      
                seq_no,      
                approver_ecno,      
                LEAD(approver_ecno) OVER (ORDER BY seq_no) AS next_ecno      
            FROM #approval_stages      
        )      
        SELECT      
            @next_approver  = s2.approver_ecno,      
            @next_condition = s2.approver_condition      
        FROM stage_cte s1      
        LEFT JOIN #approval_stages s2      
               ON s2.approver_ecno = s1.next_ecno      
        WHERE s1.approver_ecno = @stage_ecno;      
      
        INSERT INTO supplier_quotation_history (      
            sq_basic_sno, sq_edit_data, is_active, workflow_types_id,      
            approver_ecno, status, status_by, transferred_from,      
            transferred_to, comment, action_type, pr_basic_sno,      
            selected_by, pr_no      
        )      
        VALUES (      
            @sq_basic_sno, NULL, 1, @workflow_types_id,      
            @approved_by,      
            CASE WHEN @next_approver IS NULL THEN 'A' ELSE 'P' END,      
            @approved_by, NULL,      
            NULL,      
            @comments,      
            CASE WHEN @next_approver IS NULL THEN 'FINAL_APPROVED' ELSE 'APPROVED' END,      
            @pr_basic_sno,      
            CASE WHEN @next_approver IS NULL THEN @approved_by ELSE NULL END,      
            @pr_no      
        );      
      
        ------------------------------------------------------------------      
        -- Intermediate approval: move all quotations in same PR      
    -- to next approver, but do not finalize selection/status      
        ------------------------------------------------------------------      
        IF @next_approver IS NOT NULL      
        BEGIN      
            UPDATE supplier_quotation_info      
            SET approver_ecno    = @next_approver,      
                transferred_from = NULL,      
                transferred_to   = NULL,      
                modifed_by       = @approved_by,      
                modifed_date     = GETDATE()      
            WHERE pr_no = @pr_no      
              AND is_active = 1;      
      
            COMMIT TRANSACTION;      
            DROP TABLE #approval_stages;      
      
            SELECT 'APPROVED'      AS result,      
                   @sq_basic_sno   AS sq_basic_sno,      
                   @pr_no          AS pr_no,      
                   @approved_by    AS approved_by,      
                   GETDATE()       AS approved_on,      
                   @next_approver  AS next_approver,      
                   @next_condition AS next_condition,      
                   'N'             AS is_final;      
            RETURN;      
        END      
      
        --================================================================      
        -- 5. FINAL STAGE → selected quotation only gets approved/selected      
        -- other quotations only workflow columns reset; status/is_selected      
        -- remain independent      
        --================================================================      
      
        UPDATE supplier_quotation_info      
        SET status           = 'A',      
            is_selected      = 1,      
            approver_ecno    = NULL,      
            transferred_from = NULL,      
            transferred_to   = NULL,      
            modifed_by       = @approved_by,      
            modifed_date     = GETDATE()      
        WHERE sq_basic_sno = @sq_basic_sno      
          AND is_active = 1;      
      
        UPDATE supplier_quotation_info      
        SET is_selected      = 0,      
            approver_ecno    = NULL,      
            transferred_from = NULL,      
            transferred_to   = NULL,      
            modifed_by       = @approved_by,      
            modifed_date     = GETDATE()      
        WHERE pr_no = @pr_no      
          AND sq_basic_sno <> @sq_basic_sno      
          AND is_active = 1;      
      
        ------------------------------------------------------------------      
        -- 5a. Insert PO header      
        ------------------------------------------------------------------      
        DECLARE @po_basic_sno INT;      
      
        INSERT INTO po_request_info (      
            vendor_sno, brn_sno, dept_sno, com_sno, div_sno,      
            pr_basic_sno, po_date,      
            terms_conditions,      
  is_active, workflow_types_id, status,      
            po_df_no,      
            split_pr_no      
        )      
        SELECT      
            sq.vendor_sno,      
            sq.brn_sno,      
            sq.dept_sno,      
            pr.com_sno,      
            pr.div_sno,      
            sq.pr_basic_sno,      
            GETDATE(),      
            sq.payment_terms,      
            'Y',      
            sq.workflow_types_id,      
            'A',      
            NULL,      
            @pr_no      
        FROM supplier_quotation_info sq      
        INNER JOIN pr_basic_info pr ON pr.pr_basic_sno = sq.pr_basic_sno      
        WHERE sq.sq_basic_sno = @sq_basic_sno;      
      
        SET @po_basic_sno = SCOPE_IDENTITY();      
      
        ------------------------------------------------------------------      
        -- 5b. Generate formatted PO number      
        ------------------------------------------------------------------      
        --DECLARE @po_df_no VARCHAR(50) =      
        --    'PO-' + CONVERT(VARCHAR(8), GETDATE(), 112) + '-' +      
        --    RIGHT('000000' + CAST(@po_basic_sno AS VARCHAR(10)), 6);     
            ------------------------------------------------------------------  
-- 5b. Generate formatted PO number: com_prefix+div_prefix+brn_prefix+seq  
------------------------------------------------------------------  
DECLARE @po_prefix VARCHAR(30),  
        @next_seq  INT,  
        @po_df_no  VARCHAR(50);  
  
SELECT @po_prefix = ISNULL(vadr.com_prefix, '')  
                  + ISNULL(vadr.div_prefix, '')  
                  + ISNULL(vadr.brn_prefix, '')  
FROM vw_ActiveDeptRecords vadr
WHERE vadr.brn_sno  = @brn_sno
  AND vadr.dept_sno = @dept_sno;
  --select * from vw_ActiveDeptRecords where com_sno=2 and div_sno=7 and brn_sno=3 and dept_sno=6  
IF @po_prefix IS NULL OR @po_prefix = ''  
BEGIN  
    ROLLBACK TRANSACTION;  
    DROP TABLE #approval_stages;  
    RAISERROR('Unable to resolve PO prefix (company/division/branch).', 16, 1);  
    RETURN;  
END  
  
-- Find last sequence for this prefix; lock to avoid duplicates under concurrency  
SELECT @next_seq = ISNULL(MAX(  
           TRY_CAST(SUBSTRING(po_df_no, LEN(@po_prefix) + 1, 20) AS INT)  
       ), 0) + 1  
FROM po_request_info WITH (UPDLOCK, HOLDLOCK)  
WHERE po_df_no LIKE @po_prefix + '%'  
  AND TRY_CAST(SUBSTRING(po_df_no, LEN(@po_prefix) + 1, 20) AS INT) IS NOT NULL;  
  
SET @po_df_no = @po_prefix + RIGHT('000' + CAST(@next_seq AS VARCHAR(10)), 3);  
  
UPDATE po_request_info  
SET po_df_no = @po_df_no  
WHERE po_basic_sno = @po_basic_sno;  
      
        --UPDATE po_request_info      
        --SET po_df_no = @po_df_no      
        --WHERE po_basic_sno = @po_basic_sno;      
      
        ------------------------------------------------------------------      
        -- 5c. Insert PO line items      
        ------------------------------------------------------------------      
        INSERT INTO po_item_details (      
            po_basic_sno,      
            pr_item_sno,      
            prod_sno,      
            specification,      
            qty,      
            unit,      
            agreed_unit_price,      
            discount_pct,      
            tax_pct,      
            total_cost,      
            net_cost,      
            remarks,      
            created_by,      
            created_date,      
            is_active,      
            split_pr_no      
        )      
        SELECT      
            @po_basic_sno,      
            sid.pr_item_sno,      
            sid.prod_sno,      
            sid.specification,      
            sid.qty,      
            sid.unit,      
            sid.unit_price,      
            sid.discount_pct,      
            sid.tax_pct,      
            sid.total_amount,      
            ROUND(      
                (sid.total_amount      
                 - (sid.total_amount * ISNULL(TRY_CAST(sid.discount_pct AS DECIMAL(9,4)), 0) / 100.0))   
                * (1 + ISNULL(TRY_CAST(sid.tax_pct AS DECIMAL(9,4)), 0) / 100.0)      
            , 2),      
            sid.remarks,      
            @approved_by,      
            GETDATE(),      
            1,      
            @pr_no      
        FROM supplier_quotation_items sid      
        WHERE sid.sq_basic_sno = @sq_basic_sno      
          AND sid.is_active = 1;      
      
        ------------------------------------------------------------------      
        -- 5d. PO creation history      
        ------------------------------------------------------------------      
        INSERT INTO supplier_quotation_history (      
            sq_basic_sno, sq_edit_data, is_active, workflow_types_id,      
            approver_ecno, status, status_by, transferred_from,      
            transferred_to, comment, action_type, pr_basic_sno,      
            selected_by, pr_no      
        )      
        VALUES (      
            @sq_basic_sno, NULL, 1, @workflow_types_id,      
            @approved_by, 'A', @approved_by, NULL,      
            NULL,      
            'PO ' + @po_df_no + ' auto-generated on final quotation approval',      
            'PO_CREATED',      
            @pr_basic_sno,      
            @approved_by,      
            @pr_no      
        );      
      
        COMMIT TRANSACTION;      
        DROP TABLE #approval_stages;      
      
        ------------------------------------------------------------------      
        -- 6. Final response      
        ------------------------------------------------------------------      
        DECLARE @po_header_json NVARCHAR(MAX),      
                @vendor_json    NVARCHAR(MAX),      
                @po_items_json  NVARCHAR(MAX),      
                @approver_name  NVARCHAR(200);      
      
        SELECT @po_header_json = (      
            SELECT      
                po.po_basic_sno,      
                po.po_df_no,      
                po.split_pr_no                              AS po_pr_no,      
                CONVERT(VARCHAR(23), po.po_date, 126)       AS po_date,      
                po.status                                   AS po_status,      
                po.terms_conditions,      
                vadr.com_sno,      
                vadr.com_name,      
                ISNULL(vadr.logo, '')                       AS com_logo,    
                vadr.company_address,    
                vadr.branch_address,    
                vadr.div_sno,      
                vadr.div_name,      
                vadr.div_prefix,      
                vadr.brn_name,      
                vadr.brn_prefix,      
                vadr.dept_name,      
                pr.pr_basic_sno                             AS source_pr_basic_sno,      
                pr.pr_no                                    AS source_pr_no,      
                CONVERT(VARCHAR(23), pr.reg_date, 126)      AS pr_reg_date,      
                CONVERT(VARCHAR(23), pr.required_date, 126) AS pr_required_date,      
                pr.purpose                                  AS pr_purpose,      
                pr.priority_sno      
            FROM po_request_info po      
            INNER JOIN vw_ActiveDeptRecords vadr      
                ON vadr.brn_sno = po.brn_sno      
               AND vadr.dept_sno = po.dept_sno      
            INNER JOIN pr_basic_info pr      
                ON pr.pr_basic_sno = po.pr_basic_sno      
            WHERE po.po_basic_sno = @po_basic_sno      
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER      
        );      
      
        SELECT @vendor_json = (      
            SELECT      
               vgaki.kyc_basic_info_sno AS vendor_sno,      
                vgaki.company_name       AS vendor_name,      
                vgaki.supp_code          AS vendor_code,      
                vgaki.contact_person,      
                vgaki.mobile_number      AS vendor_mobile,      
                vgaki.email              AS vendor_email,      
                vgaki.kyc_address        AS vendor_address,      
                vgaki.gst_no,      
                vgaki.pan_no,      
                vgaki.business_type      
            FROM vw_get_all_kyc_info vgaki      
            WHERE vgaki.kyc_basic_info_sno = @vendor_sno      
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER      
        );      
      
        SELECT @po_items_json = (      
            SELECT      
                pid.po_item_sno,      
                pid.po_basic_sno,      
                @po_df_no                                    AS po_df_no,      
                pid.split_pr_no                              AS pr_no,      
                pid.pr_item_sno,      
                pid.prod_sno,      
                pm.prod_name,      
                pm.prod_code,      
                pm.prod_notes,      
                pid.specification,      
                pid.qty,      
                pid.unit                                     AS uom_sno,      
                uom.uom_name,      
                uom.uom_code,      
                pid.agreed_unit_price,      
                pid.discount_pct,      
                pid.tax_pct,      
                pid.total_cost,      
                pid.net_cost,      
                pid.remarks,      
                prid.est_cost                                AS pr_est_cost,      
                prid.total_cost                              AS pr_total_cost,      
                prid.qty                                     AS pr_qty,      
                pid.created_by,      
                CONVERT(VARCHAR(23), pid.created_date, 126)  AS created_date,      
                pid.is_active      
            FROM po_item_details pid      
            INNER JOIN product_master pm  ON pm.prod_sno = pid.prod_sno      
            INNER JOIN uom_master uom     ON uom.uom_sno = pid.unit      
            INNER JOIN pr_item_details prid ON prid.pr_item_sno = pid.pr_item_sno      
            WHERE pid.po_basic_sno = @po_basic_sno      
              AND pid.is_active = 1      
            ORDER BY pid.po_item_sno      
            FOR JSON PATH      
        );      
      
        SELECT @approver_name = vve.ename      
        FROM vw_verified_employees vve      
        WHERE vve.ecno = @approved_by;      
      
        SELECT      
            'FINAL_APPROVED'                     AS result,      
            'Y'                                  AS is_final,      
            @sq_basic_sno                        AS sq_basic_sno,      
            @pr_no                               AS pr_no,      
            @approved_by                         AS final_approved_by,      
            @approver_name  AS final_approved_by_name,      
            CONVERT(VARCHAR(23), GETDATE(), 126) AS final_approved_on,      
            JSON_QUERY(@po_header_json)          AS po_header,      
            JSON_QUERY(@vendor_json)             AS vendor,      
            JSON_QUERY(@po_items_json)           AS po_items;      
      
    END TRY      
    BEGIN CATCH      
        IF @@TRANCOUNT > 0      
            ROLLBACK TRANSACTION;      
      
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL      
            DROP TABLE #approval_stages;      
      
        SELECT      
            'ERROR'            AS result,      
            ERROR_NUMBER()     AS error_number,      
            ERROR_MESSAGE()    AS error_message,      
            ERROR_LINE()       AS error_line,      
            ERROR_PROCEDURE()  AS error_procedure;      
    END CATCH      
END;