-- ============================================================
-- Remove the Service Agreement / Service PO / Service Entry /
-- Service Bill Request / Service Vendor Entry / Service Vendor KYC
-- feature entirely, plus its underlying masters (Service Master,
-- Service Type Master, Recurrence Cadence Master, Service Supplier
-- Mapping) — per explicit user instruction to clear this out for a
-- new flow design. Full data + proc-body backup taken first, see
-- backend-stpl/sql/backups/pre_service_removal_2026-09-11/.
--
-- Does NOT touch the unrelated "Vendor-Driven Purchase Requisition"
-- feature (pr_basic_info.request_mode='VENDOR_DRIVEN') — confirmed
-- zero table/code overlap, only a shared English phrase.
--
-- Order matters: (1) edit shared/core procs that embed Service-table
-- references (usp_InsertPurchaseRequest, sp_nt_ApproveSupplierQuotation,
-- sp_nt_GetPrLinesForPoGrouping, sp_nt_MatchInvoiceBucket) so the
-- generic PR/PO/Invoice pipeline keeps working; (2) drop the 4 FK
-- constraints shared tables hold into Service tables; (3) drop the
-- 49 Service-exclusive procedures; (4) drop the 16 Service tables in
-- dependency order; (5) delete workflow/entity_master/screens config
-- rows. po_request_info/po_item_details/pr_item_details themselves
-- are NOT dropped (shared with regular non-Service POs/PRs) — their
-- now-orphaned service_sno/agreement_sno/service_type_sno/ceiling_amount/
-- is_retrospective/po_type columns are left in place (harmless, just
-- permanently unused going forward) rather than risk an ALTER TABLE
-- DROP COLUMN on core, heavily-relied-upon shared tables.
-- ============================================================

-- ── 1a. usp_InsertPurchaseRequest v5 — drops the Fixed Recurring
-- Service Agreement validation block and service_sno/agreement_sno
-- item handling; items are product lines only from here on. ───────
IF OBJECT_ID('dbo.usp_InsertPurchaseRequest', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_InsertPurchaseRequest;
GO
CREATE PROCEDURE usp_InsertPurchaseRequest
    @jsonInput NVARCHAR(MAX),
    @pr_no     VARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @com_sno            INT,
                @div_sno            INT,
                @brn_sno            INT,
                @dept_sno           INT,
                @reg_date           DATE,
                @required_date      DATE,
                @priority_sno       INT,
                @purpose            NVARCHAR(500),
                @current_year       VARCHAR(10),
                @pr_prefix          VARCHAR(20),
                @sequence_number    INT,
                @pr_basic_sno       INT,
                @created_by         VARCHAR(20),
                @workflow_types_id  INT,
                @first_approver     VARCHAR(20),
                @workflow_id        INT,
                @items_inserted     INT,
                @requisition_type   VARCHAR(30),
                @category           VARCHAR(20),
                @source_invoice_sno INT;

        SET @current_year = dbo.fn_GetFinancialYear(GETDATE());
        SET @pr_prefix    = 'PR' + @current_year ;

        SELECT @sequence_number = ISNULL(MAX(
            CASE
                WHEN pr_no LIKE @pr_prefix + '%'
                THEN TRY_CAST(
                         SUBSTRING(pr_no, LEN(@pr_prefix) + 1, LEN(pr_no))
                     AS INT)
                ELSE 0
            END
        ), 0) + 1
        FROM [Non_trade_Dev].[dbo].[pr_basic_info] WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE @pr_prefix + '%';

        SET @pr_no = @pr_prefix + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);

        SELECT
            @com_sno            = JSON_VALUE(@jsonInput, '$.basicInfo.com_sno'),
            @div_sno            = JSON_VALUE(@jsonInput, '$.basicInfo.div_sno'),
            @brn_sno            = JSON_VALUE(@jsonInput, '$.basicInfo.brn_sno'),
            @dept_sno           = JSON_VALUE(@jsonInput, '$.basicInfo.dept_sno'),
            @reg_date           = JSON_VALUE(@jsonInput, '$.basicInfo.req_date'),
            @required_date      = JSON_VALUE(@jsonInput, '$.basicInfo.required_date'),
            @priority_sno       = JSON_VALUE(@jsonInput, '$.basicInfo.priority_sno'),
            @purpose            = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.purpose'), ''),
            @requisition_type   = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.requisition_type'), ''),
            @source_invoice_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.source_invoice_sno') AS INT),
            @created_by         = 'KTM1148';

        SET @category = CASE @requisition_type
            WHEN 'civil_works'     THEN 'CIVIL'
            WHEN 'electrical_works' THEN 'ELECTRICAL'
            WHEN 'transportation'  THEN 'TRANSPORTATION'
            WHEN 'routine'         THEN 'ROUTINE'
            ELSE NULL
        END;

        IF @com_sno IS NULL
            THROW 50010, 'Company (com_sno) is required.', 1;

        IF @div_sno IS NULL
            THROW 50011, 'Division (div_sno) is required.', 1;

        IF @brn_sno IS NULL
            THROW 50001, 'Branch (brn_sno) is required.', 1;

        IF @reg_date IS NULL
            THROW 50002, 'Request date (req_date) is required.', 1;

        IF @required_date IS NULL
            THROW 50003, 'Required date is required.', 1;

        IF @created_by IS NULL
            THROW 50004, 'Created by is required.', 1;

        -- Validate items array has at least one valid PRODUCT line
        -- (prod_sno + unit_sno). Service lines removed along with the
        -- Service Agreement feature.
        IF NOT EXISTS (
            SELECT 1
            FROM OPENJSON(@jsonInput, '$.items')
            WHERE JSON_VALUE(value, '$.prod_sno') IS NOT NULL
              AND JSON_VALUE(value, '$.prod_sno') != ''
              AND JSON_VALUE(value, '$.unit_sno')  IS NOT NULL
              AND JSON_VALUE(value, '$.unit_sno')  != ''
        )
            THROW 50005, 'At least one valid item (prod_sno+unit_sno) is required.', 1;

      SELECT
    @workflow_id       = wt.workflow_id,
    @workflow_types_id = wt.workflow_types_id
FROM workflow_types wt
INNER JOIN approval_workflow_master awm
    ON awm.workflow_id = wt.workflow_id
WHERE wt.brn_sno  = @brn_sno
  AND wt.dept_sno = @dept_sno
  AND wt.com_sno  = @com_sno
  AND wt.div_sno  = @div_sno
  AND awm.entity_type  = 'PurchaseRequisition';
        SELECT @workflow_types_id = workflow_types_id
        FROM workflow_types
       WHERE brn_sno  = @brn_sno
          AND dept_sno = @dept_sno
          AND com_sno=@com_sno
          AND div_sno=@div_sno
          AND workflow_id=@workflow_id;

        IF @workflow_types_id IS NULL
            THROW 50006, 'No workflow configuration found for this branch and department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key]  = '0'
          AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 50007, 'No approver found for the first stage of the workflow.', 1;

        INSERT INTO [Non_trade_Dev].[dbo].[pr_basic_info]
        (
            [pr_no],               [com_sno],            [div_sno],
            [brn_sno],             [dept_sno],           [reg_date],
            [required_date],       [priority_sno],       [purpose],
            [is_active],           [created_by],         [created_date],
            [workflow_types_id],   [current_approver_id],[status],
            [category],            [source_invoice_sno]
        )
        VALUES
        (
            @pr_no,                @com_sno,             @div_sno,
            @brn_sno,              @dept_sno,            @reg_date,
            @required_date,        @priority_sno,        @purpose,
            'Y',                   @created_by,          GETDATE(),
            @workflow_types_id,    @first_approver,      'P',
            @category,             @source_invoice_sno
        );

        SET @pr_basic_sno = SCOPE_IDENTITY();

        -- ── Insert PR Item Details (product lines only — service_sno/
        -- agreement_sno no longer populated; those columns remain on the
        -- table but are permanently NULL for new rows going forward) ──────
        INSERT INTO [Non_trade_Dev].[dbo].[pr_item_details]
        (
            [pr_no],        [pr_basic_sno],  [prod_sno],
            [qty],          [unit],          [est_cost],
            [total_cost],   [remarks],       [specification],
            [pr_prod_file], [item_type],
            [is_active],
            [created_by],   [created_date]
        )
        SELECT
            @pr_no,
            @pr_basic_sno,
            NULLIF(JSON_VALUE(value, '$.prod_sno'), ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.qty'), ''), '0'),
            NULLIF(JSON_VALUE(value, '$.unit_sno'), ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.est_cost'), ''), 0),
            ISNULL(NULLIF(JSON_VALUE(value, '$.total_cost'), ''), 0),
            ISNULL(NULLIF(JSON_VALUE(value, '$.remarks'),        ''), ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.service_desc'),   ''), ''),
            NULLIF(JSON_VALUE(value, '$.item_attachment'),       ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.item_type'),      ''), 'product'),
            'Y',
            @created_by,
            GETDATE()
        FROM OPENJSON(@jsonInput, '$.items')
        WHERE JSON_VALUE(value, '$.prod_sno') IS NOT NULL
          AND JSON_VALUE(value, '$.prod_sno') != ''
          AND JSON_VALUE(value, '$.unit_sno')  IS NOT NULL
          AND JSON_VALUE(value, '$.unit_sno')  != '';

        SET @items_inserted = @@ROWCOUNT;

        IF @items_inserted = 0
            THROW 50008, 'No items were inserted. Check that items array is valid and non-empty.', 1;

        COMMIT TRANSACTION;

        SELECT
            'PR Data Saved Successfully. PR No: ' + @pr_no AS Message,
            'Success'                                       AS Status,
            @items_inserted                                 AS ItemsInserted;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT    = ERROR_SEVERITY();
        DECLARE @ErrorState    INT            = ERROR_STATE();

        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END;
GO

-- ── 1b. sp_nt_ApproveSupplierQuotation — drops the LEFT JOIN
-- service_master + service_name column from the PO-items response.
-- Everything else byte-identical to the live version (programmatic
-- edit, not hand-retyped — see backend-stpl/_build_removal_migration.mjs
-- used to produce this, deleted after use). ───────────────────────
IF OBJECT_ID('dbo.sp_nt_ApproveSupplierQuotation', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_ApproveSupplierQuotation;
GO
CREATE PROCEDURE dbo.sp_nt_ApproveSupplierQuotation
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
        -- 5a. Insert PO header — OR reuse an existing active PO for the
        -- same (pr_basic_sno, vendor_sno) pair (Part B grouping rule: a
        -- Service PO for this vendor+PR may already exist, e.g. the
        -- Electrical worked example's combined PO). Symmetric to the
        -- merge-check in sp_nt_CreateServicePO.
        ------------------------------------------------------------------
        DECLARE @po_basic_sno INT;
        DECLARE @po_df_no VARCHAR(50);
        DECLARE @is_new_po BIT = 0;

        SELECT @po_basic_sno = po_basic_sno, @po_df_no = po_df_no
        FROM po_request_info
        WHERE pr_basic_sno = @pr_basic_sno
          AND vendor_sno = @vendor_sno
          AND is_active = 'Y';

        IF @po_basic_sno IS NULL
        BEGIN
            SET @is_new_po = 1;

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
            -- 5b. Generate formatted PO number: com_prefix+div_prefix+brn_prefix+seq
            ------------------------------------------------------------------
            DECLARE @po_prefix VARCHAR(30),
                    @next_seq  INT;

            SELECT @po_prefix = ISNULL(vadr.com_prefix, '')
                              + ISNULL(vadr.div_prefix, '')
                              + ISNULL(vadr.brn_prefix, '')
            FROM vw_ActiveDeptRecords vadr
            WHERE vadr.com_sno  = @com_sno
              AND vadr.div_sno  = @div_sno
              AND vadr.brn_sno  = @brn_sno
              AND vadr.dept_sno = @dept_sno;

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
        END

        ------------------------------------------------------------------
        -- 5c. Insert PO line items (po_section='MATERIAL' — a combined PO
        -- may also carry SERVICE-section lines inserted separately by
        -- sp_nt_CreateServicePO, either before or after this runs)
        ------------------------------------------------------------------
       INSERT INTO po_item_details (
    po_basic_sno, pr_item_sno, prod_sno, specification,
    qty, unit, agreed_unit_price, discount_pct, tax_pct,
    total_cost, net_cost, remarks, po_section,
    created_by, created_date, is_active, split_pr_no
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
    sid.total_amount,              -- total_cost
    calc.net_cost,                 -- net_cost
    sid.remarks,
    'MATERIAL',
    @approved_by,
    GETDATE(),
    1,
    @pr_no
FROM supplier_quotation_items sid
CROSS APPLY (
    SELECT
      ((sid.qty * sid.unit_price - (sid.qty * sid.unit_price * ISNULL(sid.discount_pct,0) / 100.0))
            * ISNULL(sid.tax_pct,0) / 100.0) AS net_cost
) calc
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
            'PO ' + @po_df_no + CASE WHEN @is_new_po = 1
                THEN ' auto-generated on final quotation approval'
                ELSE ' — MATERIAL lines appended to the existing PO already shared with this vendor on this PR'
                END,
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

        -- v2: LEFT JOIN product_master/uom_master/pr_item_details (were
        -- INNER — would silently exclude SERVICE-section lines already on a
        -- combined PO, since those rows have prod_sno=NULL) + LEFT JOIN
        -- po_section, so the response shows every line on
        -- the PO, both sections combined.
        SELECT @po_items_json = (
            SELECT
                pid.po_item_sno,
                pid.po_basic_sno,
                @po_df_no                                    AS po_df_no,
                pid.split_pr_no                              AS pr_no,
                pid.pr_item_sno,
                pid.po_section,
                pid.prod_sno,
                pm.prod_name,
                pm.prod_code,
                pm.prod_notes,
                pid.service_sno,
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
            LEFT JOIN product_master pm     ON pm.prod_sno = pid.prod_sno
            LEFT JOIN uom_master uom        ON uom.uom_sno = pid.unit
            LEFT JOIN pr_item_details prid  ON prid.pr_item_sno = pid.pr_item_sno
            WHERE pid.po_basic_sno = @po_basic_sno
              AND pid.is_active = 1
            ORDER BY pid.po_item_sno
            FOR JSON PATH
        );

        SELECT @approver_name = vve.ename
        FROM vw_verified_employees vve
        WHERE vve.ecno = @approved_by;

        IF @approver_name IS NULL
            SELECT @approver_name = nsl.full_name
            FROM dbo.nt_nonstaff_login nsl
            WHERE nsl.login_id = @approved_by;

        SELECT
            'FINAL_APPROVED'                     AS result,
            'Y'                                  AS is_final,
            @sq_basic_sno                        AS sq_basic_sno,
            @pr_no                               AS pr_no,
            @approved_by                         AS final_approved_by,
            @approver_name  AS final_approved_by_name,
            CONVERT(VARCHAR(23), GETDATE(), 126) AS final_approved_on,
            @is_new_po                           AS is_new_po,
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
GO

-- ── 1c. sp_nt_GetPrLinesForPoGrouping v2 — drops service_master JOIN
-- + service_sno/service_name columns. ──────────────────────────────
IF OBJECT_ID('dbo.sp_nt_GetPrLinesForPoGrouping', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPrLinesForPoGrouping;
GO
CREATE PROCEDURE dbo.sp_nt_GetPrLinesForPoGrouping
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @pr_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT);

    IF @pr_basic_sno IS NULL
    BEGIN
        RAISERROR('pr_basic_sno is required.', 16, 1);
        RETURN;
    END

    ;WITH pr_lines AS (
        SELECT
            pid.pr_item_sno,
            pid.item_type,
            pid.prod_sno,
            pm.prod_name,
            pid.qty,
            pid.remarks,
            sq.vendor_sno,
            k.company_name AS vendor_name
        FROM dbo.pr_item_details pid
        LEFT JOIN dbo.product_master pm ON pm.prod_sno = pid.prod_sno
        LEFT JOIN dbo.supplier_quotation_items sqi ON sqi.pr_item_sno = pid.pr_item_sno AND sqi.is_active = 1
        LEFT JOIN dbo.supplier_quotation_info sq ON sq.sq_basic_sno = sqi.sq_basic_sno AND sq.is_selected = 1
        LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sq.vendor_sno
        WHERE pid.pr_basic_sno = @pr_basic_sno AND pid.is_active = 'Y'
    )
    SELECT
        vendor_sno,
        vendor_name,
        item_type AS line_type,
        (
            SELECT pl2.pr_item_sno, pl2.item_type, pl2.prod_sno, pl2.prod_name,
                   pl2.qty, pl2.remarks
            FROM pr_lines pl2
            WHERE ISNULL(pl2.vendor_sno, -1) = ISNULL(pr_lines.vendor_sno, -1)
              AND pl2.item_type = pr_lines.item_type
            FOR JSON PATH
        ) AS lines,
        (
            SELECT TOP 1 po_basic_sno FROM dbo.po_request_info
            WHERE pr_basic_sno = @pr_basic_sno AND vendor_sno = pr_lines.vendor_sno AND is_active = 'Y'
        ) AS existing_po_basic_sno
    FROM pr_lines
    GROUP BY vendor_sno, vendor_name, item_type
    ORDER BY vendor_name, item_type;
END;
GO

-- ── 1d. sp_nt_MatchInvoiceBucket v2 — drops the SERVICE-bucket ratio
-- branch (Service Entry-based); MATERIAL-only ratio from here on,
-- since bucket_type is never 'SERVICE' for any row created going
-- forward (0 live rows have bucket_type='SERVICE' today either). ──
IF OBJECT_ID('dbo.sp_nt_MatchInvoiceBucket', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_MatchInvoiceBucket;
GO
CREATE PROCEDURE dbo.sp_nt_MatchInvoiceBucket
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @invoice_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_sno') AS INT);
        IF @invoice_sno IS NULL
            THROW 54010, 'invoice_sno is required.', 1;

        -- Ratio from GRN receipts. The Service Entry-based branch was
        -- removed along with the Service Agreement/Service Entry feature.
        UPDATE iad
        SET matched_qty_ratio = ratios.ratio,
            hold_amount       = iad.allocated_amount * (1 - ratios.ratio),
            release_amount    = iad.allocated_amount * ratios.ratio,
            match_status      = CASE WHEN ratios.ratio >= 0.999999 THEN 'Matched' ELSE 'Partial' END
        FROM dbo.invoice_allocation_details iad
        JOIN dbo.po_item_details pid ON pid.po_item_sno = iad.po_item_sno
        CROSS APPLY (
            SELECT
                received_qty = (
                    SELECT ISNULL(SUM(gi.received_qty - ISNULL(gi.rejected_qty, 0)), 0)
                    FROM dbo.grn_item_details gi
                    WHERE gi.po_item_sno = pid.po_item_sno AND gi.is_active = 'Y'
                )
        ) raw
        CROSS APPLY (
            SELECT rawRatio = CASE
                WHEN ISNULL(pid.qty, 0) = 0 THEN 0
                ELSE CAST(raw.received_qty AS DECIMAL(18,6)) / pid.qty
            END
        ) computed
        CROSS APPLY (SELECT ratio = CASE WHEN computed.rawRatio > 1 THEN 1.0 ELSE computed.rawRatio END) ratios
        WHERE iad.invoice_sno = @invoice_sno AND iad.is_active = 'Y';

        DECLARE @totalRelease DECIMAL(18,2), @bucketCount INT, @matchedCount INT;
        SELECT
            @totalRelease = SUM(release_amount),
            @bucketCount  = COUNT(*),
            @matchedCount = SUM(CASE WHEN match_status = 'Matched' THEN 1 ELSE 0 END)
        FROM dbo.invoice_allocation_details WHERE invoice_sno = @invoice_sno AND is_active = 'Y';

        UPDATE dbo.invoice_info
        SET net_payable = ISNULL(@totalRelease, 0),
            match_status = CASE WHEN @matchedCount = @bucketCount THEN 'Matched' ELSE 'PartialRelease' END,
            modified_date = GETDATE()
        WHERE invoice_sno = @invoice_sno;

        COMMIT TRANSACTION;

        SELECT invoice_alloc_sno, po_item_sno, bucket_type, allocated_amount, matched_qty_ratio, hold_amount, release_amount, match_status
        FROM dbo.invoice_allocation_details WHERE invoice_sno = @invoice_sno AND is_active = 'Y';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- 2. Drop the 4 FK constraints shared tables hold into Service tables
-- (must happen before the referenced Service tables are dropped).
-- ============================================================
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_po_item_details_service_sno')
    ALTER TABLE dbo.po_item_details DROP CONSTRAINT FK_po_item_details_service_sno;
GO
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_po_request_info_service_type')
    ALTER TABLE dbo.po_request_info DROP CONSTRAINT FK_po_request_info_service_type;
GO
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_pr_item_details_service_sno')
    ALTER TABLE dbo.pr_item_details DROP CONSTRAINT FK_pr_item_details_service_sno;
GO
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_pr_item_details_agreement')
    ALTER TABLE dbo.pr_item_details DROP CONSTRAINT FK_pr_item_details_agreement;
GO

-- ============================================================
-- 3. Drop the 49 Service-exclusive procedures.
-- ============================================================
IF OBJECT_ID('dbo.sp_approve_service_agreement', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_approve_service_agreement;
IF OBJECT_ID('dbo.sp_approve_service_vendor_kyc', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_approve_service_vendor_kyc;
IF OBJECT_ID('dbo.sp_nt_ApproveServiceBillRequest', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ApproveServiceBillRequest;
IF OBJECT_ID('dbo.sp_nt_ApproveServicePO', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ApproveServicePO;
IF OBJECT_ID('dbo.sp_nt_ApproveServiceVendorDailyEntry', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ApproveServiceVendorDailyEntry;
IF OBJECT_ID('dbo.sp_nt_CancelServiceVendorDailyEntry', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CancelServiceVendorDailyEntry;
IF OBJECT_ID('dbo.sp_nt_CreateRecurrenceCadenceRecords', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateRecurrenceCadenceRecords;
IF OBJECT_ID('dbo.sp_nt_CreateServiceAgreement', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateServiceAgreement;
IF OBJECT_ID('dbo.sp_nt_CreateServiceBillRequest', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateServiceBillRequest;
IF OBJECT_ID('dbo.sp_nt_CreateServiceMasterSupplierMapping', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateServiceMasterSupplierMapping;
IF OBJECT_ID('dbo.sp_nt_CreateServicePO', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateServicePO;
IF OBJECT_ID('dbo.sp_nt_CreateServiceRecords', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateServiceRecords;
IF OBJECT_ID('dbo.sp_nt_CreateServiceTypeRecords', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateServiceTypeRecords;
IF OBJECT_ID('dbo.sp_nt_CreateServiceVendorDailyEntry', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateServiceVendorDailyEntry;
IF OBJECT_ID('dbo.sp_nt_CreateServiceVendorKyc', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateServiceVendorKyc;
IF OBJECT_ID('dbo.sp_nt_DirectIssueServicePO', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_DirectIssueServicePO;
IF OBJECT_ID('dbo.sp_nt_ExpireServiceAgreements', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ExpireServiceAgreements;
IF OBJECT_ID('dbo.sp_nt_FinalizeServiceVendorEntriesConsolidation', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_FinalizeServiceVendorEntriesConsolidation;
IF OBJECT_ID('dbo.sp_nt_GetActiveCeilingAgreementsForBilling', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetActiveCeilingAgreementsForBilling;
IF OBJECT_ID('dbo.sp_nt_GetActiveServiceAgreement', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetActiveServiceAgreement;
IF OBJECT_ID('dbo.sp_nt_GetAgreementsDueForNotification', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetAgreementsDueForNotification;
IF OBJECT_ID('dbo.sp_nt_GetAgreementsDueForRecurringPR', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetAgreementsDueForRecurringPR;
IF OBJECT_ID('dbo.sp_nt_GetAllServicePOs', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetAllServicePOs;
IF OBJECT_ID('dbo.sp_nt_GetApprovedServiceVendorKycs', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetApprovedServiceVendorKycs;
IF OBJECT_ID('dbo.sp_nt_GetApprovedSuppliersForService', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetApprovedSuppliersForService;
IF OBJECT_ID('dbo.sp_nt_GetApprovedVendorsForServicePicker', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetApprovedVendorsForServicePicker;
IF OBJECT_ID('dbo.sp_nt_GetEligiblePrLinesForServicePO', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetEligiblePrLinesForServicePO;
IF OBJECT_ID('dbo.sp_nt_GetRecurrenceCadenceRecords', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetRecurrenceCadenceRecords;
IF OBJECT_ID('dbo.sp_nt_GetServiceAgreements', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceAgreements;
IF OBJECT_ID('dbo.sp_nt_GetServiceAgreementsForApproval', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceAgreementsForApproval;
IF OBJECT_ID('dbo.sp_nt_GetServiceBillRequests', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceBillRequests;
IF OBJECT_ID('dbo.sp_nt_GetServiceBillRequestsForApproval', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceBillRequestsForApproval;
IF OBJECT_ID('dbo.sp_nt_GetServiceMasterSupplierMappings', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceMasterSupplierMappings;
IF OBJECT_ID('dbo.sp_nt_GetServicePOsForApproval', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServicePOsForApproval;
IF OBJECT_ID('dbo.sp_nt_GetServiceRecords', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceRecords;
IF OBJECT_ID('dbo.sp_nt_GetServiceTypeRecords', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceTypeRecords;
IF OBJECT_ID('dbo.sp_nt_GetServiceVendorDailyEntries', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceVendorDailyEntries;
IF OBJECT_ID('dbo.sp_nt_GetServiceVendorKycs', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceVendorKycs;
IF OBJECT_ID('dbo.sp_nt_GetServiceVendorKycsForApproval', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceVendorKycsForApproval;
IF OBJECT_ID('dbo.sp_nt_IssueRecurringServicePOCycle', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_IssueRecurringServicePOCycle;
IF OBJECT_ID('dbo.sp_nt_LockServiceVendorEntriesForConsolidation', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_LockServiceVendorEntriesForConsolidation;
IF OBJECT_ID('dbo.sp_nt_MarkAgreementNotificationSent', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_MarkAgreementNotificationSent;
IF OBJECT_ID('dbo.sp_nt_ProcessDueRecurringServiceAgreements', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ProcessDueRecurringServiceAgreements;
IF OBJECT_ID('dbo.sp_nt_ReleaseServiceVendorEntriesLock', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ReleaseServiceVendorEntriesLock;
IF OBJECT_ID('dbo.sp_nt_RetryServiceBillRequestPOIssue', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_RetryServiceBillRequestPOIssue;
IF OBJECT_ID('dbo.sp_nt_ReviseServicePOCeiling', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ReviseServicePOCeiling;
IF OBJECT_ID('dbo.sp_nt_UpdateServiceAgreement', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_UpdateServiceAgreement;
IF OBJECT_ID('dbo.sp_nt_CreateCallOffPO', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateCallOffPO;
IF OBJECT_ID('dbo.sp_nt_CreateServiceEntry', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateServiceEntry;
IF OBJECT_ID('dbo.sp_nt_ApproveServiceEntry', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ApproveServiceEntry;
IF OBJECT_ID('dbo.sp_nt_GetPendingServicePOsForServiceEntry', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetPendingServicePOsForServiceEntry;
IF OBJECT_ID('dbo.sp_nt_GetServiceEntriesByPO', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServiceEntriesByPO;
IF OBJECT_ID('dbo.sp_nt_GetAllServiceEntries', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetAllServiceEntries;
GO

-- ============================================================
-- 4. Drop the 16 Service tables in dependency order (children first).
-- ============================================================
IF OBJECT_ID('dbo.service_agreement_history', 'U') IS NOT NULL DROP TABLE dbo.service_agreement_history;
GO
IF OBJECT_ID('dbo.service_agreement_notification_log', 'U') IS NOT NULL DROP TABLE dbo.service_agreement_notification_log;
GO
IF OBJECT_ID('dbo.service_agreement_recurring_pr_log', 'U') IS NOT NULL DROP TABLE dbo.service_agreement_recurring_pr_log;
GO
IF OBJECT_ID('dbo.service_bill_request_history', 'U') IS NOT NULL DROP TABLE dbo.service_bill_request_history;
GO
IF OBJECT_ID('dbo.service_bill_request_item_details', 'U') IS NOT NULL DROP TABLE dbo.service_bill_request_item_details;
GO
IF OBJECT_ID('dbo.service_bill_request', 'U') IS NOT NULL DROP TABLE dbo.service_bill_request;
GO
IF OBJECT_ID('dbo.service_entry_item_details', 'U') IS NOT NULL DROP TABLE dbo.service_entry_item_details;
GO
IF OBJECT_ID('dbo.service_entry_info', 'U') IS NOT NULL DROP TABLE dbo.service_entry_info;
GO
IF OBJECT_ID('dbo.service_vendor_kyc_history', 'U') IS NOT NULL DROP TABLE dbo.service_vendor_kyc_history;
GO
IF OBJECT_ID('dbo.service_vendor_kyc', 'U') IS NOT NULL DROP TABLE dbo.service_vendor_kyc;
GO
IF OBJECT_ID('dbo.service_vendor_daily_entry', 'U') IS NOT NULL DROP TABLE dbo.service_vendor_daily_entry;
GO
IF OBJECT_ID('dbo.service_master_supplier', 'U') IS NOT NULL DROP TABLE dbo.service_master_supplier;
GO
IF OBJECT_ID('dbo.service_agreement', 'U') IS NOT NULL DROP TABLE dbo.service_agreement;
GO
IF OBJECT_ID('dbo.service_master', 'U') IS NOT NULL DROP TABLE dbo.service_master;
GO
IF OBJECT_ID('dbo.service_type_master', 'U') IS NOT NULL DROP TABLE dbo.service_type_master;
GO
IF OBJECT_ID('dbo.recurrence_cadence_master', 'U') IS NOT NULL DROP TABLE dbo.recurrence_cadence_master;
GO

-- ============================================================
-- 5. Clean up workflow/entity_master/screens config rows.
-- ============================================================
DELETE FROM dbo.workflow_stage WHERE workflow_types_id IN (15,16,17,18,28);
GO
DELETE FROM dbo.workflow_types WHERE workflow_types_id IN (15,16,17,18,28);
GO
DELETE FROM dbo.approval_workflow_master WHERE workflow_id IN (15,16,17,18,23);
GO
DELETE FROM dbo.entity_master WHERE entity_code IN ('ServicePO','ServiceEntry','ServiceAgreement','ServiceBillRequest','ServiceVendorKYC','ServiceVendorEntry');
GO
DELETE FROM dbo.screens WHERE comp IN (
  'ServicePOPage','ServicePOApprovalScreen','ServiceEntryPage','ServiceAgreementPage',
  'ServiceAgreementApprovalScreen','ServiceBillRequestPage','ServiceBillRequestApprovalScreen',
  'ServiceVendorConsolidationPage','ServiceVendorKycPage','ServiceVendorKycApprovalScreen',
  'ServiceAgreementListPage','ServiceEntryApprovalScreen','ServiceVendorEntryApprovalScreen'
);
GO

-- ============================================================
-- After running, confirm:
--   SELECT name FROM sys.tables WHERE name LIKE 'service_%' OR name = 'recurrence_cadence_master';  -- expect 0 rows
--   SELECT name FROM sys.procedures WHERE name LIKE '%Service%';  -- expect 0 rows (aside from unrelated names, if any)
--   SELECT * FROM dbo.screens WHERE comp LIKE 'Service%';  -- expect 0 rows
--   EXEC dbo.usp_InsertPurchaseRequest @jsonInput = N'{...a real material-only PR...}', @pr_no = '' OUTPUT;  -- sanity smoke test
-- ============================================================
