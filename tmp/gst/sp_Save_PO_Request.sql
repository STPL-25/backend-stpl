  
  
CREATE    PROCEDURE sp_Save_PO_Request    
    @jsonInput NVARCHAR(MAX)    
AS    
BEGIN    
    SET NOCOUNT ON;    
    
    BEGIN TRY    
        BEGIN TRANSACTION;    
    
  
        CREATE TABLE #tmp_po_header (    
            pr_basic_sno         INT,    
            required_date        DATETIME,    
            vendor_sno           INT,    
            brn_sno              INT,    
            dept_sno             INT,    
            com_sno              INT,    
            div_sno              INT,    
            budget_sno           INT,    
            budget_code          NVARCHAR(50),    
            priority_sno         INT,    
            purpose              NVARCHAR(MAX),    
            terms_conditions     NVARCHAR(MAX),    
            delivery_address     NVARCHAR(MAX),    
            workflow_types_id    INT,    
            current_approver_id  INT,    
            status               CHAR(1),    
            po_df_no             NVARCHAR(100),    
            created_by           INT    
        );    
    
        INSERT INTO #tmp_po_header (    
            pr_basic_sno, required_date, vendor_sno, brn_sno,    
            dept_sno, com_sno, div_sno,    
            budget_sno, budget_code, priority_sno,    
            purpose, terms_conditions, delivery_address,    
            workflow_types_id, current_approver_id,    
            status, po_df_no, created_by    
        )    
        SELECT    
            CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno')          AS INT),    
            CAST(JSON_VALUE(@jsonInput, '$.required_date')         AS DATETIME),    
            CAST(JSON_VALUE(@jsonInput, '$.vendor_sno')            AS INT),    
            CAST(JSON_VALUE(@jsonInput, '$.brn_sno')               AS INT),    
            CAST(JSON_VALUE(@jsonInput, '$.dept_sno')              AS INT),    
            CAST(JSON_VALUE(@jsonInput, '$.com_sno')               AS INT),    
            CAST(JSON_VALUE(@jsonInput, '$.div_sno')               AS INT),    
            CAST(JSON_VALUE(@jsonInput, '$.budget_sno')            AS INT),    
            JSON_VALUE(@jsonInput, '$.budget_code'),    
            CAST(JSON_VALUE(@jsonInput, '$.priority_sno')          AS INT),    
            JSON_VALUE(@jsonInput, '$.purpose'),    
            JSON_VALUE(@jsonInput, '$.terms_conditions'),    
            JSON_VALUE(@jsonInput, '$.delivery_address'),    
            CAST(JSON_VALUE(@jsonInput, '$.workflow_types_id')     AS INT),    
            CAST(JSON_VALUE(@jsonInput, '$.current_approver_id')   AS INT),    
            ISNULL(LEFT(JSON_VALUE(@jsonInput, '$.status'), 1), 'P'),    
            JSON_VALUE(@jsonInput, '$.po_df_no'),    
            CAST(JSON_VALUE(@jsonInput, '$.created_by')            AS INT);    
    
        -- ══════════════════════════════════════════════════════════════    
        -- STEP 2: FETCH pr_no FROM pr_basic_info    
        -- ══════════════════════════════════════════════════════════════    
        DECLARE @pr_basic_sno INT;    
        DECLARE @pr_no        VARCHAR(30);    
    
        SELECT @pr_basic_sno = pr_basic_sno FROM #tmp_po_header;    
    
        SELECT @pr_no = pr_no    
        FROM pr_basic_info    
        WHERE pr_basic_sno = @pr_basic_sno;    
    
        IF @pr_no IS NULL    
            THROW 50005, 'pr_no not found in pr_basic_info for given pr_basic_sno.', 1;    
    
        -- ══════════════════════════════════════════════════════════════    
        -- STEP 3: PARSE ITEMS INTO TEMP TABLE    
        -- ══════════════════════════════════════════════════════════════    
        CREATE TABLE #tmp_po_items (    
            pr_item_sno      INT,    
            prod_sno         INT,    
            prod_name        NVARCHAR(255),    
            specification    NVARCHAR(MAX),    
            qty              DECIMAL(18,4),    
            unit             INT,    
            unit_name        NVARCHAR(100),    
            est_cost         DECIMAL(18,4),    
            total_cost       DECIMAL(18,4),    
       split_group      INT,    
            split_pr_no      NVARCHAR(50)   -- e.g. "PR-2026-001/1"    
        );    
    
        INSERT INTO #tmp_po_items (    
            pr_item_sno, prod_sno, prod_name, specification,    
            qty, unit, unit_name,    
            est_cost, total_cost,    
            split_group, split_pr_no    
        )    
        SELECT    
            CAST(JSON_VALUE(item.value, '$.pr_item_sno')  AS INT),    
            CAST(JSON_VALUE(item.value, '$.prod_sno')     AS INT),    
            JSON_VALUE(item.value, '$.prod_name'),    
            JSON_VALUE(item.value, '$.specification'),    
            CAST(JSON_VALUE(item.value, '$.qty')          AS DECIMAL(18,4)),    
            CAST(JSON_VALUE(item.value, '$.unit')         AS INT),    
            JSON_VALUE(item.value, '$.unit_name'),    
            CAST(JSON_VALUE(item.value, '$.est_cost')     AS DECIMAL(18,4)),    
            CAST(JSON_VALUE(item.value, '$.qty')          AS DECIMAL(18,4))    
                * CAST(JSON_VALUE(item.value, '$.est_cost') AS DECIMAL(18,4)),    
            CAST(JSON_VALUE(item.value, '$.split_group')  AS INT),    
            @pr_no + '/' + CAST(JSON_VALUE(item.value, '$.split_group') AS VARCHAR(10))    
        FROM OPENJSON(@jsonInput, '$.items') AS item;    
    
        -- ══════════════════════════════════════════════════════════════    
        -- STEP 4: VALIDATIONS    
        -- ══════════════════════════════════════════════════════════════    
        IF NOT EXISTS (SELECT 1 FROM #tmp_po_header)    
            THROW 50001, 'Header data is missing in JSON.', 1;    
    
        IF NOT EXISTS (SELECT 1 FROM #tmp_po_items)    
            THROW 50002, 'No items found in JSON.', 1;    
    
        IF EXISTS (    
            SELECT 1 FROM #tmp_po_items    
            WHERE qty <= 0    
        )    
            THROW 50004, 'Item qty and est_cost must be greater than zero.', 1;    
    
        -- ══════════════════════════════════════════════════════════════    
        -- STEP 5: GET DISTINCT SPLIT GROUPS INTO TEMP    
        -- ══════════════════════════════════════════════════════════════    
        CREATE TABLE #tmp_split_groups (    
            split_group     INT,    
            split_pr_no     NVARCHAR(50),    
            po_basic_sno    INT DEFAULT 0    -- filled after each insert    
        );    
    
        INSERT INTO #tmp_split_groups (split_group, split_pr_no)    
        SELECT DISTINCT split_group, split_pr_no    
        FROM #tmp_po_items    
        ORDER BY split_group;    
    
        -- ══════════════════════════════════════════════════════════════    
        -- STEP 6: LOOP — INSERT ONE po_request_info ROW PER SPLIT GROUP    
        -- ══════════════════════════════════════════════════════════════    
        DECLARE @cur_split_group  INT;    
        DECLARE @cur_split_pr_no  NVARCHAR(50);    
        DECLARE @cur_po_basic_sno INT;    
    
        DECLARE split_cursor CURSOR LOCAL FAST_FORWARD FOR    
            SELECT split_group, split_pr_no FROM #tmp_split_groups ORDER BY split_group;    
    
        OPEN split_cursor;    
        FETCH NEXT FROM split_cursor INTO @cur_split_group, @cur_split_pr_no;    
    
        WHILE @@FETCH_STATUS = 0    
        BEGIN    
            -- Insert one header row per split group    
            INSERT INTO po_request_info (    
                vendor_sno, brn_sno, dept_sno, com_sno, div_sno,    
                budget_sno, budget_code, pr_basic_sno,    
                po_date, required_date,    
                priority_sno, purpose, terms_conditions, delivery_address,    
                is_active, workflow_types_id, current_approver_id,    
                status, po_df_no,    
                split_pr_no                    -- ✅ set per split group    
            )    
            SELECT    
                vendor_sno, brn_sno, dept_sno, com_sno, div_sno,    
                budget_sno, budget_code, pr_basic_sno,    
                GETDATE(), required_date,    
                priority_sno, purpose, terms_conditions, delivery_address,    
                1, workflow_types_id, current_approver_id,    
                status, po_df_no,    
      @cur_split_pr_no               -- ✅ e.g. "PR-2026-001/1"    
            FROM #tmp_po_header;    
    
            SET @cur_po_basic_sno = SCOPE_IDENTITY();    
    
            -- Track which po_basic_sno belongs to which split group    
            UPDATE #tmp_split_groups    
            SET po_basic_sno = @cur_po_basic_sno    
            WHERE split_group = @cur_split_group;    
    
            -- Insert items for this split group only    
            INSERT INTO po_item_details (    
                po_basic_sno, pr_item_sno, prod_sno, prod_name,    
                budget_sno, specification,    
                qty, unit, unit_name,    
                agreed_unit_price, total_cost,    
                discount_pct, tax_pct, net_cost,    
                remarks,    
                created_by, created_date,    
                modifed_by, modifed_date,    
                is_active, split_pr_no    
            )    
            SELECT    
                @cur_po_basic_sno,    
                i.pr_item_sno,    
                i.prod_sno,    
                i.prod_name,    
                h.budget_sno,    
                i.specification,    
                i.qty,    
                i.unit,    
                i.unit_name,    
                i.est_cost,    
                i.total_cost,    
                0,    
                0,    
                i.total_cost,    
                NULL,    
                h.created_by,    
                GETDATE(),    
                NULL, NULL,    
                1,    
                i.split_pr_no              -- ✅ "PR-2026-001/1"    
            FROM #tmp_po_items i    
            CROSS JOIN #tmp_po_header h    
            WHERE i.split_group = @cur_split_group;  -- ✅ only this group's items    
    
            FETCH NEXT FROM split_cursor INTO @cur_split_group, @cur_split_pr_no;    
        END;    
    
        CLOSE split_cursor;    
        DEALLOCATE split_cursor;    
    
        COMMIT TRANSACTION;    
    
        -- ══════════════════════════════════════════════════════════════    
        -- STEP 7: RETURN — all created PO rows with their split info    
        -- ══════════════════════════════════════════════════════════════    
        SELECT    
            sg.po_basic_sno,    
            sg.split_group,    
            sg.split_pr_no,    
            @pr_no    AS pr_no,    
            'SUCCESS' AS result    
        FROM #tmp_split_groups sg    
        ORDER BY sg.split_group;    
    
    END TRY    
    BEGIN CATCH    
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;    
    
        IF CURSOR_STATUS('local', 'split_cursor') >= 0    
        BEGIN    
            CLOSE split_cursor;    
            DEALLOCATE split_cursor;    
        END;    
    
        SELECT    
            ERROR_NUMBER()  AS ErrorNumber,    
            ERROR_MESSAGE() AS ErrorMessage,    
            ERROR_LINE()    AS ErrorLine,    
            'FAILED'        AS result;    
    END CATCH    
    
    IF OBJECT_ID('tempdb..#tmp_po_header')      IS NOT NULL DROP TABLE #tmp_po_header;    
    IF OBJECT_ID('tempdb..#tmp_po_items')        IS NOT NULL DROP TABLE #tmp_po_items;    
    IF OBJECT_ID('tempdb..#tmp_split_groups')    IS NOT NULL DROP TABLE #tmp_split_groups;    
    
END; 