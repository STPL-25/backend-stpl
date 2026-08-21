-- ============================================================
-- usp_InsertPurchaseRequest v3 — Fixed Recurring PR lines require a valid
-- Service Agreement (pr_item_details.agreement_sno)
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/PR/repository/PR.repository.js (createPrRecords) —
--            unchanged; it JSON.stringify()s whatever basicInfo/items the
--            frontend sends and passes it straight through, so no Node.js
--            changes are needed for this file — the frontend just needs to
--            include agreement_sno on the item once it starts calling
--            GET /api/service_agreement/getActiveServiceAgreement.
--
-- Why this is needed
-- ------------------
-- backend-stpl/docs/service-agreement-approval-po-spec.md §4: a PR line for a
-- FIXED_RECURRING service (e.g. Rent) must reference an approved,
-- currently-in-period dbo.service_agreement for the PR's own
-- (com_sno,div_sno,brn_sno,dept_sno) + that service — and the rate/UOM on the
-- line must come from that agreement server-side, never from client-submitted
-- est_cost/total_cost/unit_sno. Two changes, both inside
-- usp_InsertPurchaseRequest (06_usp_InsertPurchaseRequest_v2.sql, itself
-- CREATE OR ALTER — following that same convention here rather than the
-- DROP+CREATE style used for the sp_nt_* procedures elsewhere in this repo):
--
--   1. A new pre-check THROWs (error 50012) before any insert happens if any
--      item's service is FIXED_RECURRING and its agreement_sno doesn't
--      resolve to a service_agreement row that is Approved, in-period, and
--      scoped to this exact PR's org unit + service.
--   2. The item INSERT gains an OUTER APPLY/LEFT JOIN to service_agreement:
--      for a line that matches (i.e. every FIXED_RECURRING line, guaranteed
--      by check #1), unit/est_cost/total_cost are sourced from the agreement
--      instead of the client JSON, qty defaults to 1 instead of 0 (a service
--      PR with no typed quantity still means "this period's amount," not
--      zero), and the new agreement_sno column is populated.
--
-- Everything else — financial-year numbering, workflow/approver resolution
-- (including its pre-existing redundant double workflow lookup),
-- error codes 50001-50008 — is preserved byte-for-byte from
-- 06_usp_InsertPurchaseRequest_v2.sql, same "smallest possible behavioural
-- diff" goal that file stated for itself.
-- ============================================================

-- ── Schema: pr_item_details needs to reference the agreement it billed from ─

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.pr_item_details') AND name = 'agreement_sno')
    ALTER TABLE dbo.pr_item_details
        ADD agreement_sno INT NULL CONSTRAINT FK_pr_item_details_agreement FOREIGN KEY REFERENCES dbo.service_agreement (agreement_sno);
GO

-- ── usp_InsertPurchaseRequest v3 ────────────────────────────────────────────

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

        -- Every Fixed Recurring service line must reference an approved,
        -- in-period Service Agreement for THIS PR's org scope + that service
        -- (spec §4) — never a free-typed rate. Checked before any insert so
        -- a bad line aborts the whole PR, same as the other item validation
        -- above, rather than silently dropping the line.
        IF EXISTS (
            SELECT 1
            FROM OPENJSON(@jsonInput, '$.items') AS item
            CROSS APPLY (
                SELECT TRY_CAST(JSON_VALUE(item.value, '$.service_sno')   AS INT) AS parsed_service_sno,
                       TRY_CAST(JSON_VALUE(item.value, '$.agreement_sno') AS INT) AS parsed_agreement_sno
            ) parsed
            JOIN dbo.service_master sm      ON sm.service_sno = parsed.parsed_service_sno
            JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
            WHERE st.service_type_code = 'FIXED_RECURRING'
              AND NOT EXISTS (
                  SELECT 1 FROM dbo.service_agreement sa
                  WHERE sa.agreement_sno = parsed.parsed_agreement_sno
                    AND sa.service_sno   = parsed.parsed_service_sno
                    AND sa.com_sno = @com_sno AND sa.div_sno = @div_sno
                    AND sa.brn_sno = @brn_sno AND sa.dept_sno = @dept_sno
                    AND sa.status  = 'A'
                    AND CAST(GETDATE() AS DATE) BETWEEN sa.period_start_date AND sa.period_end_date
              )
        )
            THROW 50012, 'One or more Fixed Recurring service lines are missing a valid, approved, in-period Service Agreement (agreement_sno) for this company/division/branch/department.', 1;

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
        -- service_sno (v2) populated for SERVICE lines, NULL for PRODUCT
        -- lines. agreement_sno (v3): for a FIXED_RECURRING service line, `sa`
        -- below is GUARANTEED to match (the pre-check above already rejected
        -- the batch otherwise), so unit/est_cost/total_cost are overridden
        -- from the agreement rather than trusted from the client, and qty
        -- defaults to 1 (one billing period) instead of 0. Every other line
        -- (product, or a non-FIXED_RECURRING service) has sa.agreement_sno
        -- NULL and behaves exactly as before.
        INSERT INTO [Non_Trade].[dbo].[pr_item_details]
        (
            [pr_no],        [pr_basic_sno],  [prod_sno],
            [qty],          [unit],          [est_cost],
            [total_cost],   [remarks],       [specification],
            [pr_prod_file], [item_type],     [service_sno],
            [agreement_sno],
            [is_active],
            [created_by],   [created_date]
        )
        SELECT
            @pr_no,
            @pr_basic_sno,
            NULLIF(JSON_VALUE(value, '$.prod_sno'), ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.qty'), ''),
                   CASE WHEN sa.agreement_sno IS NOT NULL THEN '1' ELSE '0' END),
            ISNULL(sa.rate_uom_sno, NULLIF(JSON_VALUE(value, '$.unit_sno'), '')),
            ISNULL(sa.rate_amount, ISNULL(NULLIF(JSON_VALUE(value, '$.est_cost'), ''), 0)),
            ISNULL(
                sa.rate_amount * TRY_CAST(
                    ISNULL(NULLIF(JSON_VALUE(value, '$.qty'), ''),
                           CASE WHEN sa.agreement_sno IS NOT NULL THEN '1' ELSE '0' END)
                    AS DECIMAL(18,4)),
                ISNULL(NULLIF(JSON_VALUE(value, '$.total_cost'), ''), 0)
            ),
            ISNULL(NULLIF(JSON_VALUE(value, '$.remarks'),        ''), ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.service_desc'),   ''), ''),
            NULLIF(JSON_VALUE(value, '$.item_attachment'),       ''),  -- FIX 5: NULL not ''
            ISNULL(NULLIF(JSON_VALUE(value, '$.item_type'),      ''), 'product'),
            NULLIF(JSON_VALUE(value, '$.service_sno'), ''),
            sa.agreement_sno,
            'Y',
            @created_by,
            GETDATE()
        FROM OPENJSON(@jsonInput, '$.items')
        OUTER APPLY (
            SELECT TRY_CAST(JSON_VALUE(value, '$.service_sno')   AS INT) AS parsed_service_sno,
                   TRY_CAST(JSON_VALUE(value, '$.agreement_sno') AS INT) AS parsed_agreement_sno
        ) parsed
        LEFT JOIN dbo.service_agreement sa
            ON sa.agreement_sno = parsed.parsed_agreement_sno
           AND sa.service_sno   = parsed.parsed_service_sno
           AND sa.com_sno = @com_sno AND sa.div_sno = @div_sno
           AND sa.brn_sno = @brn_sno AND sa.dept_sno = @dept_sno
           AND sa.status  = 'A'
           AND CAST(GETDATE() AS DATE) BETWEEN sa.period_start_date AND sa.period_end_date
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

-- ============================================================
-- After running, confirm:
--   SELECT * FROM sys.columns WHERE object_id = OBJECT_ID('dbo.pr_item_details') AND name = 'agreement_sno';
--   SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID('dbo.usp_InsertPurchaseRequest');
--
-- Manual smoke test (Fixed Recurring line with NO agreement_sno — should now
-- THROW 50012 instead of silently accepting a free-typed rate):
--   DECLARE @pr_no VARCHAR(20);
--   EXEC usp_InsertPurchaseRequest
--     @jsonInput = N'{"basicInfo":{"com_sno":1,"div_sno":1,"brn_sno":1,"dept_sno":1,
--       "req_date":"2026-08-14","required_date":"2026-08-20","priority_sno":1,"purpose":"rent"},
--       "items":[{"service_sno":<a FIXED_RECURRING service_sno>,"item_type":"service","qty":1}]}',
--     @pr_no = @pr_no OUTPUT;
--   -- expect: THROW 50012
--
-- Then with a real agreement_sno for that service_sno+org scope, approved and
-- in-period: expect success, and
--   SELECT unit, est_cost, total_cost, agreement_sno FROM pr_item_details
--   WHERE pr_no = @pr_no;
-- should show the agreement's rate/UOM, not whatever (if anything) the JSON
-- passed for est_cost/total_cost/unit_sno.
-- ============================================================
