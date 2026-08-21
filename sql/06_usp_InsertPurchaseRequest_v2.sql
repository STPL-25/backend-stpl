-- ============================================================
-- usp_InsertPurchaseRequest v2 — accept service-only PR lines
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/PR/repository/PR.repository.js (createPrRecords)
--
-- Why this is needed
-- ------------------
-- This procedure is NOT checked in anywhere else in this repo — its live
-- definition was pulled directly from the DB server to write this file. It is
-- the first time it goes into version control. It already reads and persists
-- `item_type` ('product'|'service') per line, but has two bugs that block
-- every service-line use case in the Service Procurement feature:
--
--   1. The header-level guard THROWs (error 50005, aborting the whole PR)
--      unless at least one item has BOTH prod_sno and unit_sno — so a
--      pure-service PR (Type 1/2/3 service requisitions) is rejected outright.
--   2. The INSERT ... SELECT ... FROM OPENJSON that populates pr_item_details
--      has the same prod_sno+unit_sno filter, so even a mixed PR (Part B:
--      Civil/Electrical/Transportation) would silently drop every service
--      line with no error.
--
-- Fix: a line is now valid if it has EITHER (prod_sno AND unit_sno) — a
-- product line — OR service_sno — a service line. Both the header guard and
-- the insert filter use the same OR condition. service_sno is threaded
-- through to the new pr_item_details.service_sno column (see the ALTERs
-- below, applied first since the INSERT needs the column to exist and
-- prod_sno/unit need to allow NULL for a service-only row).
--
-- Everything else (financial-year PR numbering, workflow/approver
-- resolution, error codes 50001-50008) is preserved byte-for-byte from the
-- live definition — including its pre-existing redundant double workflow
-- lookup — since this proc is load-bearing for every PR submitted today and
-- the goal here is the smallest possible behavioural diff.
-- ============================================================

-- ── Schema relax: pr_item_details must allow a service-only row ────────────

IF EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.pr_item_details') AND name = 'prod_sno' AND is_nullable = 0
)
    ALTER TABLE dbo.pr_item_details ALTER COLUMN prod_sno INT NULL;
GO

IF EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.pr_item_details') AND name = 'unit' AND is_nullable = 0
)
    ALTER TABLE dbo.pr_item_details ALTER COLUMN unit INT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.pr_item_details') AND name = 'service_sno')
    ALTER TABLE dbo.pr_item_details
        ADD service_sno INT NULL CONSTRAINT FK_pr_item_details_service_sno FOREIGN KEY REFERENCES dbo.service_master (service_sno);
GO

-- pr_basic_info.source_invoice_sno: Type-3 retrospective PR references the
-- vendor bill captured before this PR existed. No FK yet — dbo.invoice_info
-- is created later (grn-service/sql/13_invoice.sql); add the constraint then.
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.pr_basic_info') AND name = 'source_invoice_sno')
    ALTER TABLE dbo.pr_basic_info ADD source_invoice_sno INT NULL;
GO

-- ── usp_InsertPurchaseRequest v2 ────────────────────────────────────────────

CREATE OR ALTER PROCEDURE usp_InsertPurchaseRequest
    @jsonInput NVARCHAR(MAX),
    @pr_no     VARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @com_sno           INT,
                @div_sno           INT,
                @brn_sno           INT,
                @dept_sno          INT,
                @reg_date          DATE,
                @required_date     DATE,
                @priority_sno      INT,
                @purpose           NVARCHAR(500),
                @current_year      VARCHAR(10),   -- FIX 1: was INT, fn returns '26-27'
                @pr_prefix         VARCHAR(20),
                @sequence_number   INT,
                @pr_basic_sno      INT,
                @created_by        VARCHAR(20),
                @workflow_types_id INT,
                @first_approver    VARCHAR(20),
                @workflow_id INT,
                @items_inserted    INT;

        -- FIX 1: @current_year is VARCHAR e.g. '26-27'
        SET @current_year = dbo.fn_GetFinancialYear(GETDATE());
        SET @pr_prefix    = 'PR' + @current_year ;  -- 'PR-26-27-'

        -- FIX 2: Use SUBSTRING+LEN for safe sequence extraction (no CAST truncation)
        SELECT @sequence_number = ISNULL(MAX(
            CASE
                WHEN pr_no LIKE @pr_prefix + '%'
                THEN TRY_CAST(
                         SUBSTRING(pr_no, LEN(@pr_prefix) + 1, LEN(pr_no))
                     AS INT)
                ELSE 0
            END
        ), 0) + 1
        FROM [Non_Trade].[dbo].[pr_basic_info] WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE @pr_prefix + '%';

        -- e.g. PR-26-27-0001
        SET @pr_no = @pr_prefix + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);

        -- FIX 3: Parse com_sno and div_sno from JSON (were missing before)
        SELECT
            @com_sno       = JSON_VALUE(@jsonInput, '$.basicInfo.com_sno'),
            @div_sno       = JSON_VALUE(@jsonInput, '$.basicInfo.div_sno'),
            @brn_sno       = JSON_VALUE(@jsonInput, '$.basicInfo.brn_sno'),
            @dept_sno      = JSON_VALUE(@jsonInput, '$.basicInfo.dept_sno'),  -- FIX 4: no hardcoded fallback
            @reg_date      = JSON_VALUE(@jsonInput, '$.basicInfo.req_date'),
            @required_date = JSON_VALUE(@jsonInput, '$.basicInfo.required_date'),
            @priority_sno  = JSON_VALUE(@jsonInput, '$.basicInfo.priority_sno'),
            @purpose       = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.purpose'), ''),
            @created_by    = 'KTM1148'; -- replace with JSON_VALUE when auth is ready

        -- ── Field Validations ──────────────────────────────────────────────
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

        -- Validate items array has at least one valid entry — a PRODUCT line
        -- (prod_sno + unit_sno) OR a SERVICE line (service_sno).
        IF NOT EXISTS (
            SELECT 1
            FROM OPENJSON(@jsonInput, '$.items')
            WHERE (
                JSON_VALUE(value, '$.prod_sno') IS NOT NULL
                AND JSON_VALUE(value, '$.prod_sno') != ''
                AND JSON_VALUE(value, '$.unit_sno')  IS NOT NULL
                AND JSON_VALUE(value, '$.unit_sno')  != ''
            )
            OR (
                JSON_VALUE(value, '$.service_sno') IS NOT NULL
                AND JSON_VALUE(value, '$.service_sno') != ''
            )
        )
            THROW 50005, 'At least one valid item (product with prod_sno+unit_sno, or service with service_sno) is required.', 1;

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
        -- ── Resolve Workflow ───────────────────────────────────────────────
        SELECT @workflow_types_id = workflow_types_id
        FROM workflow_types
       WHERE brn_sno  = @brn_sno
          AND dept_sno = @dept_sno
          AND com_sno=@com_sno
          AND div_sno=@div_sno
          AND workflow_id=@workflow_id;



        IF @workflow_types_id IS NULL
            THROW 50006, 'No workflow configuration found for this branch and department.', 1;

        -- Resolve first approver from workflow stages
        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key]  = '0'
          AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 50007, 'No approver found for the first stage of the workflow.', 1;

        -- ── Insert PR Basic Info ───────────────────────────────────────────
        -- FIX 3: com_sno and div_sno included in INSERT
        INSERT INTO [Non_Trade].[dbo].[pr_basic_info]
        (
            [pr_no],               [com_sno],            [div_sno],
            [brn_sno],             [dept_sno],           [reg_date],
            [required_date],       [priority_sno],       [purpose],
            [is_active],           [created_by],         [created_date],
            [workflow_types_id],   [current_approver_id],[status]
        )
        VALUES
        (
            @pr_no,                @com_sno,             @div_sno,
            @brn_sno,              @dept_sno,            @reg_date,
            @required_date,        @priority_sno,        @purpose,
            'Y',                   @created_by,          GETDATE(),
            @workflow_types_id,    @first_approver,      'P'
        );

        SET @pr_basic_sno = SCOPE_IDENTITY();

        -- ── Insert PR Item Details ─────────────────────────────────────────
        -- service_sno added (v2): populated for SERVICE lines, NULL for
        -- PRODUCT lines. prod_sno/unit are the inverse — NULL on SERVICE
        -- lines instead of erroring, now that both columns allow NULL.
        INSERT INTO [Non_Trade].[dbo].[pr_item_details]
        (
            [pr_no],        [pr_basic_sno],  [prod_sno],
            [qty],          [unit],          [est_cost],
            [total_cost],   [remarks],       [specification],
            [pr_prod_file], [item_type],     [service_sno],
            [is_active],
            [created_by],   [created_date]
        )
        SELECT
            @pr_no,
            @pr_basic_sno,
            NULLIF(JSON_VALUE(value, '$.prod_sno'), ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.qty'),            ''), 0),
            NULLIF(JSON_VALUE(value, '$.unit_sno'), ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.est_cost'),       ''), 0),
            ISNULL(NULLIF(JSON_VALUE(value, '$.total_cost'),     ''), 0),
            ISNULL(NULLIF(JSON_VALUE(value, '$.remarks'),        ''), ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.service_desc'),   ''), ''),
            NULLIF(JSON_VALUE(value, '$.item_attachment'),       ''),  -- FIX 5: NULL not ''
            ISNULL(NULLIF(JSON_VALUE(value, '$.item_type'),      ''), 'product'),
            NULLIF(JSON_VALUE(value, '$.service_sno'), ''),
            'Y',
            @created_by,
            GETDATE()
        FROM OPENJSON(@jsonInput, '$.items')
        WHERE (
            JSON_VALUE(value, '$.prod_sno') IS NOT NULL
            AND JSON_VALUE(value, '$.prod_sno') != ''
            AND JSON_VALUE(value, '$.unit_sno')  IS NOT NULL
            AND JSON_VALUE(value, '$.unit_sno')  != ''
        )
        OR (
            JSON_VALUE(value, '$.service_sno') IS NOT NULL
            AND JSON_VALUE(value, '$.service_sno') != ''
        );

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

-- ── entity_master seed rows for the two new document types ─────────────────

IF NOT EXISTS (SELECT 1 FROM dbo.entity_master WHERE entity_code = 'ServicePO')
    INSERT INTO dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by)
    VALUES (N'Service Purchase Order', N'ServicePO', NULL, 'Y', N'system');
GO

IF NOT EXISTS (SELECT 1 FROM dbo.entity_master WHERE entity_code = 'ServiceEntry')
    INSERT INTO dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by)
    VALUES (N'Service Entry', N'ServiceEntry', NULL, 'Y', N'system');
GO

-- ============================================================
-- After running, confirm:
--   SELECT prod_sno, unit, IS_NULLABLE FROM sys.columns c
--     JOIN sys.types t ON t.user_type_id = c.user_type_id
--    WHERE c.object_id = OBJECT_ID('dbo.pr_item_details') AND c.name IN ('prod_sno','unit');
--   SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID('dbo.usp_InsertPurchaseRequest');
--   SELECT * FROM dbo.entity_master WHERE entity_code IN ('ServicePO','ServiceEntry');
--
-- Manual smoke test (pure-service PR — previously THREW 50005):
--   DECLARE @pr_no VARCHAR(20);
--   EXEC usp_InsertPurchaseRequest
--     @jsonInput = N'{"basicInfo":{"com_sno":1,"div_sno":1,"brn_sno":1,"dept_sno":1,
--       "req_date":"2026-08-13","required_date":"2026-08-20","priority_sno":1,"purpose":"test"},
--       "items":[{"service_sno":1,"item_type":"service","qty":1,"remarks":"test service line"}]}',
--     @pr_no = @pr_no OUTPUT;
--   SELECT @pr_no;
-- ============================================================
