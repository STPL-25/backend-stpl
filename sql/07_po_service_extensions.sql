-- ============================================================
-- Service PO — po_request_info/po_item_details extensions + Service PO procs
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : new backend-stpl/src/ServicePO module
--
-- Why this is needed
-- ------------------
-- Service_Procurement_Flow.pdf: standing/one-time Service POs with a fixed
-- amount (Type 1), a ceiling (Type 2), or a call-off against a blanket PO
-- (Type 3). Service POs deliberately do NOT go through supplier_quotation_info
-- (its RFQ-specific columns — currency, buyback, advance payment % — don't
-- fit a single-vendor service agreement); sp_nt_CreateServicePO is a new,
-- much smaller create+approve pair shaped like usp_InsertPurchaseRequest /
-- sp_approve_pr_datas instead of the ~400-line multi-vendor quotation-compare
-- proc.
--
-- po_section ('MATERIAL'|'SERVICE') is added now so Part B's combined-PO
-- worked example (one vendor supplying both a product line and a service
-- line on the same PR -> ONE po_basic_sno, two sections) has somewhere to
-- live. sp_nt_CreateServicePO already implements the merge side of that: it
-- looks for an existing active po_request_info row on (pr_basic_sno,
-- vendor_sno) and appends a SERVICE-section item to it instead of creating a
-- new PO. The other half — patching sp_nt_ApproveSupplierQuotation to do the
-- same check and stamp po_section='MATERIAL' — lands in Part B (08_grouped_po_from_pr.sql).
--
-- PO numbering: pure Service POs get their own 'SVO-YYYY-NNNN' sequence
-- (matches the PDF's own worked-example numbering), independent of whatever
-- prefix scheme product POs use — self-contained, no dependency on
-- vw_ActiveDeptRecords.com_prefix.
-- ============================================================

-- ── po_request_info: standing/ceiling/call-off fields ───────────────────────

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_request_info') AND name = 'po_type')
    ALTER TABLE dbo.po_request_info ADD po_type VARCHAR(20) NOT NULL CONSTRAINT DF_po_request_info_po_type DEFAULT 'ONE_TIME';
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_request_info') AND name = 'validity_from')
    ALTER TABLE dbo.po_request_info ADD validity_from DATE NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_request_info') AND name = 'validity_to')
    ALTER TABLE dbo.po_request_info ADD validity_to DATE NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_request_info') AND name = 'ceiling_amount')
    ALTER TABLE dbo.po_request_info ADD ceiling_amount DECIMAL(18,2) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_request_info') AND name = 'variance_tolerance_pct')
    ALTER TABLE dbo.po_request_info ADD variance_tolerance_pct DECIMAL(5,2) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_request_info') AND name = 'consumed_amount')
    ALTER TABLE dbo.po_request_info ADD consumed_amount DECIMAL(18,2) NOT NULL CONSTRAINT DF_po_request_info_consumed_amount DEFAULT 0;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_request_info') AND name = 'service_type_sno')
    ALTER TABLE dbo.po_request_info ADD service_type_sno INT NULL CONSTRAINT FK_po_request_info_service_type FOREIGN KEY REFERENCES dbo.service_type_master (service_type_sno);
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_request_info') AND name = 'is_retrospective')
    ALTER TABLE dbo.po_request_info ADD is_retrospective BIT NOT NULL CONSTRAINT DF_po_request_info_is_retrospective DEFAULT 0;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_request_info') AND name = 'parent_blanket_po_sno')
    ALTER TABLE dbo.po_request_info ADD parent_blanket_po_sno INT NULL CONSTRAINT FK_po_request_info_parent_blanket FOREIGN KEY REFERENCES dbo.po_request_info (po_basic_sno);
GO

-- ── po_item_details: section tag + service line reference ──────────────────

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_item_details') AND name = 'po_section')
    ALTER TABLE dbo.po_item_details ADD po_section VARCHAR(10) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_item_details') AND name = 'service_sno')
    ALTER TABLE dbo.po_item_details ADD service_sno INT NULL CONSTRAINT FK_po_item_details_service_sno FOREIGN KEY REFERENCES dbo.service_master (service_sno);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_po_request_info_pr_vendor' AND object_id = OBJECT_ID('dbo.po_request_info'))
    CREATE INDEX IX_po_request_info_pr_vendor ON dbo.po_request_info (pr_basic_sno, vendor_sno) WHERE is_active = 'Y';
GO

-- ============================================================
-- sp_nt_CreateServicePO
-- @jsonInput: { pr_basic_sno?, vendor_sno, service_type_code, po_type,
--   validity_from?, validity_to?, ceiling_amount?, variance_tolerance_pct?,
--   is_retrospective?, parent_blanket_po_sno?, delivery_address,
--   terms_conditions, purpose, com_sno, div_sno, brn_sno, dept_sno,
--   budget_sno?, budget_code?, created_by,
--   items: [{ pr_item_sno?, service_sno, specification?, qty?, unit?,
--     agreed_unit_price?, total_cost?, discount_pct?, tax_pct?, net_cost?, remarks? }] }
--
-- Grouping rule (Part B): if an active po_request_info row already exists for
-- (pr_basic_sno, vendor_sno), the items are appended to it (po_section =
-- 'SERVICE') instead of creating a new PO — same vendor + same PR always
-- shares one PO document, per the PDF's grouping rule.
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

        IF @po_basic_sno IS NULL
        BEGIN
            SET @is_new_po = 1;

            DECLARE @workflow_id INT, @workflow_types_id INT, @first_approver VARCHAR(20);

            SELECT @workflow_id = wt.workflow_id, @workflow_types_id = wt.workflow_types_id
            FROM dbo.workflow_types wt
            INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
            WHERE wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno AND wt.com_sno = @com_sno AND wt.div_sno = @div_sno
              AND awm.entity_type = 'ServicePO';

            IF @workflow_types_id IS NULL
                THROW 52006, 'No ServicePO workflow configuration found for this branch and department.', 1;

            SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
            FROM dbo.vw_workflow_stages AS ws
            CROSS APPLY OPENJSON(ws.stages_json) AS s
            CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
            WHERE ws.workflow_types_id = @workflow_types_id
              AND s.[key] = '0' AND s2.[key] = '0';

            IF @first_approver IS NULL
                THROW 52007, 'No approver found for the first stage of the ServicePO workflow.', 1;

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
                'Y', @workflow_types_id, @first_approver, 'P', @po_no,
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
            -- po_request_info's 'Y'/'N') — confirmed against live data after
            -- Part B2 surfaced the mismatch (sp_nt_ApproveSupplierQuotation's
            -- final-response query does `pid.is_active = 1`, which throws a
            -- conversion error against any row stored as 'Y').
            @created_by, GETDATE(), '1'
        FROM OPENJSON(@items) j
        LEFT JOIN dbo.service_master sm ON sm.service_sno = TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT)
        LEFT JOIN dbo.uom_master um     ON um.uom_sno = TRY_CAST(JSON_VALUE(j.value, '$.unit') AS INT);

        DECLARE @items_inserted INT = @@ROWCOUNT;
        IF @items_inserted = 0
            THROW 52008, 'No items were inserted. Check that items array is valid and non-empty.', 1;

        COMMIT TRANSACTION;

        SELECT
            @po_basic_sno    AS po_basic_sno,
            @po_no           AS po_no,
            @is_new_po       AS is_new_po,
            @items_inserted  AS items_inserted,
            'SUCCESS'        AS result;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- sp_nt_ApproveServicePO — single-stage progression, mirrors sp_approve_pr_datas
-- @jsonInput: { po_basic_sno, approved_by, comments, approval_stages, action }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ApproveServicePO', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_ApproveServicePO;
GO
CREATE PROCEDURE dbo.sp_nt_ApproveServicePO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF ISJSON(@jsonInput) = 0
        BEGIN
            RAISERROR('Invalid JSON format for @jsonInput', 16, 1);
            RETURN;
        END

        DECLARE @po_basic_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT),
                @comments        VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by     VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action          VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');

        IF @po_basic_sno IS NULL
        BEGIN
            RAISERROR('po_basic_sno is required.', 16, 1);
            RETURN;
        END

        IF @action IS NULL OR LTRIM(RTRIM(LOWER(@action))) NOT IN ('approve', 'reject')
        BEGIN
            RAISERROR('Invalid action. Must be ''approve'' or ''reject''.', 16, 1);
            RETURN;
        END
        SET @action = LOWER(LTRIM(RTRIM(@action)));

        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
        BEGIN
            RAISERROR('Invalid or missing approval_stages in JSON', 16, 1);
            RETURN;
        END

        IF @approved_by IS NULL OR LTRIM(RTRIM(@approved_by)) = ''
        BEGIN
            RAISERROR('Approver EC number is required.', 16, 1);
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.po_request_info WHERE po_basic_sno = @po_basic_sno AND is_active = 'Y')
        BEGIN
            RAISERROR('Service PO not found or inactive.', 16, 1);
            RETURN;
        END

        CREATE TABLE #approval_stages (
            seq_no INT, approver_ecno VARCHAR(30), stage VARCHAR(100),
            required_approvals VARCHAR(10), is_mandatory CHAR(1), escalation_hours VARCHAR(10),
            approver_condition VARCHAR(200), next_approver_ecno VARCHAR(30),
            can_forward CHAR(1), can_backward CHAR(1), can_edit_data CHAR(1)
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

        IF @action = 'reject'
        BEGIN
            INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
            VALUES (@po_basic_sno, 'REJECTED', @approved_by, @comments, 'Y');

            UPDATE dbo.po_request_info
            SET status = 'R', current_approver_id = NULL
            WHERE po_basic_sno = @po_basic_sno;

            DROP TABLE #approval_stages;

            SELECT 'REJECTED' AS result, @po_basic_sno AS po_basic_sno, @approved_by AS rejected_by, GETDATE() AS rejected_on;
            RETURN;
        END

        DECLARE @next_current_approver VARCHAR(30);

        SELECT @next_current_approver = next_stage.approver_ecno
        FROM (
            SELECT approver_ecno, LEAD(approver_ecno, 1, NULL) OVER (ORDER BY seq_no) AS next_approver_ecno
            FROM #approval_stages
        ) current_stage
        LEFT JOIN #approval_stages next_stage
            ON next_stage.approver_ecno = current_stage.next_approver_ecno
        WHERE current_stage.approver_ecno = @approved_by;

        INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
        VALUES (@po_basic_sno, 'APPROVED', @approved_by, @comments, 'Y');

        UPDATE dbo.po_request_info
        SET current_approver_id = @next_current_approver
        WHERE po_basic_sno = @po_basic_sno;

        IF @next_current_approver IS NULL
        BEGIN
            UPDATE dbo.po_request_info SET status = 'A' WHERE po_basic_sno = @po_basic_sno;
        END

        DROP TABLE #approval_stages;

        SELECT
            'SUCCESS'                                      AS result,
            @po_basic_sno                                  AS po_basic_sno,
            @approved_by                                   AS approved_by,
            GETDATE()                                       AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE')   AS next_approver;

    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL
            DROP TABLE #approval_stages;

        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO

-- ============================================================
-- sp_nt_GetServicePOsForApproval — pending Service POs for the logged-in approver
-- @Ecno VARCHAR(50) — matches sp_get_pr_details_for_approval's calling convention
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServicePOsForApproval', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetServicePOsForApproval;
GO
CREATE PROCEDURE dbo.sp_nt_GetServicePOsForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.po_basic_sno,
        p.po_df_no                                  AS po_no,
        p.pr_basic_sno,
        pr.pr_no,
        p.vendor_sno,
        k.company_name                               AS vendor_name,
        p.po_type,
        p.service_type_sno,
        st.service_type_code,
        st.service_type_name,
        p.validity_from,
        p.validity_to,
        p.ceiling_amount,
        p.variance_tolerance_pct,
        p.consumed_amount,
        p.is_retrospective,
        p.parent_blanket_po_sno,
        p.purpose,
        p.terms_conditions,
        p.delivery_address,
        p.com_sno, p.div_sno, p.brn_sno, p.dept_sno,
        p.workflow_types_id,
        p.current_approver_id,
        p.status,
        (
            SELECT ws.stage_order_json
            FROM dbo.workflow_stage ws
            WHERE ws.workflow_types_id = p.workflow_types_id AND ws.is_active = 'Y'
        ) AS stage_order_json,
        (
            SELECT
                pid.po_item_sno, pid.pr_item_sno, pid.service_sno, sm.service_name,
                pid.specification, pid.qty, pid.unit_name, pid.agreed_unit_price,
                pid.total_cost, pid.discount_pct, pid.tax_pct, pid.net_cost,
                pid.remarks, pid.po_section
            FROM dbo.po_item_details pid
            LEFT JOIN dbo.service_master sm ON sm.service_sno = pid.service_sno
            WHERE pid.po_basic_sno = p.po_basic_sno AND pid.is_active = '1'
            FOR JSON PATH
        ) AS items
    FROM dbo.po_request_info p
    LEFT JOIN dbo.service_type_master st ON st.service_type_sno = p.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k        ON k.kyc_basic_info_sno = p.vendor_sno
    LEFT JOIN dbo.pr_basic_info pr        ON pr.pr_basic_sno = p.pr_basic_sno
    WHERE p.current_approver_id = @Ecno
      AND p.status = 'P'
      AND p.service_type_sno IS NOT NULL
    ORDER BY p.po_basic_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetAllServicePOs — all Service POs (po_section='SERVICE' rows, i.e.
-- service_type_sno set), optionally filtered by status/vendor
-- @jsonInput optional: { status?, vendor_sno? }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetAllServicePOs', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetAllServicePOs;
GO
CREATE PROCEDURE dbo.sp_nt_GetAllServicePOs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = NULL, @vendor_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @status = JSON_VALUE(@jsonInput, '$.status');
        SET @vendor_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    END

    SELECT
        p.po_basic_sno,
        p.po_df_no        AS po_no,
        p.pr_basic_sno,
        pr.pr_no,
        p.vendor_sno,
        k.company_name    AS vendor_name,
        p.po_type,
        st.service_type_code,
        st.service_type_name,
        p.validity_from,
        p.validity_to,
        p.ceiling_amount,
        p.consumed_amount,
        p.status,
        (
            SELECT
                pid.po_item_sno, pid.service_sno, sm.service_name,
                pid.qty, pid.unit_name, pid.agreed_unit_price, pid.net_cost, pid.po_section
            FROM dbo.po_item_details pid
            LEFT JOIN dbo.service_master sm ON sm.service_sno = pid.service_sno
            WHERE pid.po_basic_sno = p.po_basic_sno AND pid.is_active = '1'
            FOR JSON PATH
        ) AS items
    FROM dbo.po_request_info p
    LEFT JOIN dbo.service_type_master st ON st.service_type_sno = p.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k        ON k.kyc_basic_info_sno = p.vendor_sno
    LEFT JOIN dbo.pr_basic_info pr        ON pr.pr_basic_sno = p.pr_basic_sno
    WHERE p.service_type_sno IS NOT NULL
      AND (@status IS NULL OR p.status = @status)
      AND (@vendor_sno IS NULL OR p.vendor_sno = @vendor_sno)
    ORDER BY p.po_basic_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetEligiblePrLinesForServicePO — approved SERVICE lines on a PR that
-- have not yet been placed on any PO. Feeds ServicePOPage.tsx's line picker.
-- @jsonInput: { pr_basic_sno }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetEligiblePrLinesForServicePO', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetEligiblePrLinesForServicePO;
GO
CREATE PROCEDURE dbo.sp_nt_GetEligiblePrLinesForServicePO
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

    SELECT
        pid.pr_item_sno,
        pid.pr_basic_sno,
        pb.pr_no,
        pid.service_sno,
        sm.service_name,
        sm.service_type_sno,
        st.service_type_code,
        st.service_type_name,
        sm.default_uom_sno,
        pid.specification,
        pid.qty,
        pid.unit,
        pid.est_cost,
        pid.total_cost,
        pid.remarks
    FROM dbo.pr_item_details pid
    JOIN dbo.pr_basic_info pb    ON pb.pr_basic_sno = pid.pr_basic_sno
    JOIN dbo.service_master sm   ON sm.service_sno = pid.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    WHERE pid.pr_basic_sno = @pr_basic_sno
      AND pid.item_type = 'service'
      AND pid.is_active = 'Y'
      AND pb.status = 'A'
      AND NOT EXISTS (
          -- po_item_details uses '1'/'0', unlike pr_item_details' 'Y'/'N' above
          SELECT 1 FROM dbo.po_item_details poi
          WHERE poi.pr_item_sno = pid.pr_item_sno AND poi.is_active = '1'
      )
    ORDER BY pid.pr_item_sno;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_request_info') AND name IN ('po_type','ceiling_amount','po_section');
--   SELECT name FROM sys.procedures WHERE name LIKE 'sp_nt_%ServicePO%';
--
-- NOTE before using in anger: entity_master already has a 'ServicePO' row
-- (seeded in 06_usp_InsertPurchaseRequest_v2.sql), but sp_nt_CreateServicePO
-- will THROW 52006 until an actual approval_workflow_master/workflow_types
-- row is configured with entity_type='ServicePO' for each (com,div,brn,dept)
-- that needs to raise one — same setup burden as any other document type.
-- ============================================================
