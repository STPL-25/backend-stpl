-- ============================================================
-- sp_nt_CreateServicePO (REPLACED) — no-workflow -> direct-issue branch
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/ServicePO module
--
-- Why this is needed
-- ------------------
-- backend-stpl/docs/service-agreement-approval-po-spec.md §7: "if a workflow
-- is configured for PO generation, follow it; otherwise generate the PO
-- directly after the PR and send it." As originally written in
-- 07_po_service_extensions.sql, sp_nt_CreateServicePO instead THROWs 52006
-- when no ServicePO workflow is configured for the (com,div,brn,dept) scope —
-- there was no direct-issue branch at all.
--
-- This replacement adds it, reusing the exact
-- workflow_types_id=NULL/current_approver_id=NULL/status='A' shape
-- sp_nt_CreateCallOffPO (09_call_off_po.sql) already uses for call-offs
-- against a standing PO — same "this PO doesn't need approval" state, just
-- reached for a different reason (no workflow configured, vs. the parent
-- blanket PO already covering it).
--
-- Everything else about the procedure — grouping rule, item insert, numbering
-- — is unchanged from 07_po_service_extensions.sql; only the workflow-
-- resolution block (previously two unconditional THROWs) and the status
-- literal in the INSERT are touched. Error code 52006 (no workflow
-- configured) is retired — that path no longer errors. 52007 (workflow
-- configured but its first stage has no approver) still throws: that's a
-- genuine misconfiguration, not "no workflow", and shouldn't silently
-- fall through to direct-issue.
--
-- The result set gains @is_direct_issue so the Node layer
-- (ServicePO.service.js) knows to send the "PO generated" notification
-- immediately, the same way sp_nt_ApproveSupplierQuotation's final-stage
-- approval already triggers one — a direct-issue PO has no approval event to
-- hang that notification off of, so it has to fire from creation instead.
-- This only applies to the new-PO path (@po_basic_sno was NULL going in);
-- appending items to an already-grouped PO never re-triggers it.
-- ============================================================

IF OBJECT_ID('dbo.sp_nt_CreateServicePO', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateServicePO;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServicePO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @pr_basic_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT);
        DECLARE @vendor_sno             INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @service_type_code      VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.service_type_code');
        DECLARE @po_type                VARCHAR(20)   = ISNULL(JSON_VALUE(@jsonInput, '$.po_type'), 'ONE_TIME');
        DECLARE @validity_from          DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.validity_from') AS DATE);
        DECLARE @validity_to            DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.validity_to') AS DATE);
        DECLARE @ceiling_amount         DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @variance_tolerance_pct DECIMAL(5,2)  = TRY_CAST(JSON_VALUE(@jsonInput, '$.variance_tolerance_pct') AS DECIMAL(5,2));
        DECLARE @is_retrospective       BIT           = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.is_retrospective') AS BIT), 0);
        DECLARE @parent_blanket_po_sno  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.parent_blanket_po_sno') AS INT);
        DECLARE @delivery_address       VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.delivery_address');
        DECLARE @terms_conditions       VARCHAR(MAX)  = JSON_VALUE(@jsonInput, '$.terms_conditions');
        DECLARE @purpose                VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.purpose');
        DECLARE @com_sno                INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno                INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno                INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno               INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @budget_sno             INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.budget_sno') AS INT);
        DECLARE @budget_code            VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.budget_code');
        DECLARE @created_by             VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
        DECLARE @items                  NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');

        IF @vendor_sno IS NULL OR @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @created_by IS NULL
            THROW 52001, 'vendor_sno, com_sno, div_sno, brn_sno, dept_sno and created_by are required.', 1;

        IF @pr_basic_sno IS NULL AND @is_retrospective = 0
            THROW 52002, 'pr_basic_sno is required unless is_retrospective is set (Type 3 call-off).', 1;

        IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
            THROW 52003, 'At least one item is required.', 1;

        DECLARE @service_type_sno INT, @requires_ceiling BIT;
        SELECT @service_type_sno = service_type_sno, @requires_ceiling = requires_ceiling_amount
        FROM dbo.service_type_master
        WHERE service_type_code = @service_type_code AND is_active = 'Y';

        IF @service_type_sno IS NULL
            THROW 52004, 'Unknown or inactive service_type_code.', 1;

        IF @requires_ceiling = 1 AND @ceiling_amount IS NULL
            THROW 52005, 'ceiling_amount is required for this service type.', 1;

        -- ── PO grouping: same PR + same vendor always shares one PO ────────
        DECLARE @po_basic_sno INT = NULL;
        IF @pr_basic_sno IS NOT NULL
            SELECT @po_basic_sno = po_basic_sno
            FROM dbo.po_request_info
            WHERE pr_basic_sno = @pr_basic_sno AND vendor_sno = @vendor_sno AND is_active = 'Y';

        DECLARE @po_no VARCHAR(50);
        DECLARE @is_new_po BIT = 0;
        DECLARE @is_direct_issue BIT = 0;

        IF @po_basic_sno IS NULL
        BEGIN
            SET @is_new_po = 1;

            DECLARE @workflow_types_id INT, @first_approver VARCHAR(20), @po_status CHAR(1);

            SELECT @workflow_types_id = wt.workflow_types_id
            FROM dbo.workflow_types wt
            INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
            WHERE wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno AND wt.com_sno = @com_sno AND wt.div_sno = @div_sno
              AND awm.entity_type = 'ServicePO';

            IF @workflow_types_id IS NULL
            BEGIN
                -- No ServicePO workflow configured for this org scope: issue
                -- directly rather than throwing (spec §7). @first_approver
                -- and @workflow_types_id both stay NULL — same shape
                -- sp_nt_CreateCallOffPO uses for an auto-approved call-off.
                SET @first_approver  = NULL;
                SET @po_status       = 'A';
                SET @is_direct_issue = 1;
            END
            ELSE
            BEGIN
                SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
                FROM dbo.vw_workflow_stages AS ws
                CROSS APPLY OPENJSON(ws.stages_json) AS s
                CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
                WHERE ws.workflow_types_id = @workflow_types_id
                  AND s.[key] = '0' AND s2.[key] = '0';

                IF @first_approver IS NULL
                    THROW 52007, 'No approver found for the first stage of the ServicePO workflow.', 1;

                SET @po_status = 'P';
            END

            DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
            DECLARE @seq  INT;
            SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
            FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
            WHERE po_df_no LIKE 'SVO-' + @year + '-%';
            SET @po_no = 'SVO-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

            INSERT INTO dbo.po_request_info (
                vendor_sno, brn_sno, dept_sno, com_sno, div_sno,
                budget_sno, budget_code, pr_basic_sno,
                po_date, required_date, purpose, terms_conditions, delivery_address,
                is_active, workflow_types_id, current_approver_id, status, po_df_no,
                po_type, validity_from, validity_to, ceiling_amount, variance_tolerance_pct,
                consumed_amount, service_type_sno, is_retrospective, parent_blanket_po_sno
            )
            VALUES (
                @vendor_sno, @brn_sno, @dept_sno, @com_sno, @div_sno,
                @budget_sno, @budget_code, @pr_basic_sno,
                CAST(GETDATE() AS DATE), @validity_to, @purpose, @terms_conditions, @delivery_address,
                'Y', @workflow_types_id, @first_approver, @po_status, @po_no,
                @po_type, @validity_from, @validity_to, @ceiling_amount, @variance_tolerance_pct,
                0, @service_type_sno, @is_retrospective, @parent_blanket_po_sno
            );

            SET @po_basic_sno = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            SELECT @po_no = po_df_no FROM dbo.po_request_info WHERE po_basic_sno = @po_basic_sno;
        END

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
            TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)),
            TRY_CAST(JSON_VALUE(j.value, '$.unit') AS INT),
            um.uom_name,
            TRY_CAST(JSON_VALUE(j.value, '$.agreed_unit_price') AS DECIMAL(18,4)),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.total_cost') AS DECIMAL(18,4)),
                   ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 0) * ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.agreed_unit_price') AS DECIMAL(18,4)), 0)),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.discount_pct') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.tax_pct') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.net_cost') AS DECIMAL(18,4)),
                   ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 0) * ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.agreed_unit_price') AS DECIMAL(18,4)), 0)),
            JSON_VALUE(j.value, '$.remarks'),
            'SERVICE',
            -- po_item_details.is_active uses '1'/'0' in this DB (unlike
            -- po_request_info's 'Y'/'N') — see 07_po_service_extensions.sql's
            -- note on this same line.
            @created_by, GETDATE(), '1'
        FROM OPENJSON(@items) j
        LEFT JOIN dbo.service_master sm ON sm.service_sno = TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT)
        LEFT JOIN dbo.uom_master um     ON um.uom_sno = TRY_CAST(JSON_VALUE(j.value, '$.unit') AS INT);

        DECLARE @items_inserted INT = @@ROWCOUNT;
        IF @items_inserted = 0
            THROW 52008, 'No items were inserted. Check that items array is valid and non-empty.', 1;

        COMMIT TRANSACTION;

        SELECT
            @po_basic_sno     AS po_basic_sno,
            @po_no            AS po_no,
            @is_new_po        AS is_new_po,
            @is_direct_issue  AS is_direct_issue,
            @items_inserted   AS items_inserted,
            'SUCCESS'         AS result;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.sp_nt_CreateServicePO')) LIKE '%is_direct_issue%'; -- should be 1
--
-- Manual test once a real org scope has NO ServicePO workflow configured:
--   EXEC dbo.sp_nt_CreateServicePO @jsonInput = N'{"vendor_sno":1,"com_sno":1,
--     "div_sno":1,"brn_sno":1,"dept_sno":1,"service_type_code":"FIXED_RECURRING",
--     "is_retrospective":1,"created_by":"system","items":[{"service_sno":1,"qty":1,
--     "agreed_unit_price":100}]}';
--   -- expect: is_direct_issue = 1, and SELECT status FROM po_request_info
--   -- WHERE po_basic_sno = <returned> should be 'A', not 'P'.
-- ============================================================
