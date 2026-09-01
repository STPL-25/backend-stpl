-- ============================================================
-- usp_InsertPurchaseRequest v4 — persist category + source_invoice_sno
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/PR/repository/PR.repository.js (createPrRecords) —
--            unchanged, same reason as v3's header: it JSON.stringify()s
--            whatever basicInfo the frontend sends and passes it straight
--            through with no field allowlisting.
--
-- Why this is needed
-- ------------------
-- Two dead inputs, closed together since both are single new fields added to
-- the same pr_basic_info INSERT:
--
--   1. category (CIVIL/ELECTRICAL/TRANSPORTATION/ROUTINE) — the 4 requisition
--      entry pages (CivilWorksRequisitionPage.tsx etc.) already set
--      basicFormData.requisition_type = requisitionType client-side (values
--      'civil_works'|'electrical_works'|'transportation'|'routine'), and it's
--      already serialized into basicInfo on every create-PR call — confirmed
--      by reading PurchaseRequisitionPage.tsx. usp_InsertPurchaseRequest has
--      simply never read it. No pr_basic_info column exists to hold it, so
--      it's unqueryable/unreportable today. This adds the column and reads
--      the value that's already being sent — no frontend change needed.
--
--   2. source_invoice_sno — added to pr_basic_info all the way back in
--      06_usp_InsertPurchaseRequest_v2.sql (the Vendor-Bill-Driven
--      retrospective-PR link, FK'd from grn-service's invoice_info) but no
--      version of this proc, v2 or v3, has ever written it — confirmed by
--      reading both. Dead column. This reads
--      $.basicInfo.source_invoice_sno (nullable — absent/null for every
--      normal PR, populated only when a requester creates a PR from the new
--      "Create PR from this Bill" action being added to the Invoice screen).
--
-- Everything else is preserved byte-for-byte from v3
-- (sql/12_pr_agreement_autofill.sql) — same "smallest possible behavioural
-- diff" convention that file and v2 before it both used.
-- ============================================================

-- ── Schema: pr_basic_info needs a place to record which of the 4 entry
--    pages a PR came from, and (if any) which retrospective invoice it's for.

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.pr_basic_info') AND name = 'category')
    ALTER TABLE dbo.pr_basic_info
        ADD category VARCHAR(20) NULL
            CONSTRAINT CK_pr_basic_info_category
            CHECK (category IS NULL OR category IN ('CIVIL','ELECTRICAL','TRANSPORTATION','ROUTINE'));
GO

-- source_invoice_sno already exists (06_usp_InsertPurchaseRequest_v2.sql) —
-- nothing to add here, this file only starts writing to it.

-- ── usp_InsertPurchaseRequest v4 ────────────────────────────────────────────

CREATE OR ALTER PROCEDURE usp_InsertPurchaseRequest
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
                @current_year       VARCHAR(10),   -- FIX 1: was INT, fn returns '26-27'
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
            @com_sno            = JSON_VALUE(@jsonInput, '$.basicInfo.com_sno'),
            @div_sno            = JSON_VALUE(@jsonInput, '$.basicInfo.div_sno'),
            @brn_sno            = JSON_VALUE(@jsonInput, '$.basicInfo.brn_sno'),
            @dept_sno           = JSON_VALUE(@jsonInput, '$.basicInfo.dept_sno'),  -- FIX 4: no hardcoded fallback
            @reg_date           = JSON_VALUE(@jsonInput, '$.basicInfo.req_date'),
            @required_date      = JSON_VALUE(@jsonInput, '$.basicInfo.required_date'),
            @priority_sno       = JSON_VALUE(@jsonInput, '$.basicInfo.priority_sno'),
            @purpose            = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.purpose'), ''),
            @requisition_type   = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.requisition_type'), ''),
            @source_invoice_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.source_invoice_sno') AS INT),
            @created_by         = 'KTM1148'; -- replace with JSON_VALUE when auth is ready

        SET @category = CASE @requisition_type
            WHEN 'civil_works'     THEN 'CIVIL'
            WHEN 'electrical_works' THEN 'ELECTRICAL'
            WHEN 'transportation'  THEN 'TRANSPORTATION'
            WHEN 'routine'         THEN 'ROUTINE'
            ELSE NULL
        END;

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
        -- v4: category + source_invoice_sno added, both parsed above.
        INSERT INTO [Non_Trade].[dbo].[pr_basic_info]
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

        -- ── Insert PR Item Details ─────────────────────────────────────────
        -- Unchanged from v3 — service_sno/agreement_sno logic preserved
        -- byte-for-byte.
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

-- ── vw_PR_Basic_Info: surface category alongside the rest of the header ────
-- Additive-only — every existing consumer gets one new field, nothing removed
-- or renamed. Base definition copied from 06b_vw_pr_basic_info_service_lines.sql.

CREATE OR ALTER VIEW dbo.vw_PR_Basic_Info
AS
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
    vve.ename                   AS created_by_name,
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
    pbf.category,
    pbf.source_invoice_sno,

    -- group number of this split row (NULL when the PR has no items)
    g.grp                       AS [group],

    -- append /group ONLY when the PR is actually split into >1 group
    CASE
       WHEN g.grp IS NOT NULL AND g.group_count > 1
            THEN pbf.pr_no + '/' + CAST(g.grp AS VARCHAR(10))
        ELSE pbf.pr_no
    END                         AS pr_no,

    pbf.workflow_types_id,
    pbf.current_approver_id,
    pbf.status,

    -- PR Item Details as JSON array (only items of THIS group)
    (
        SELECT
            pid.pr_item_sno,
            pid.pr_basic_sno,
            pid.item_type,
            pid.prod_sno,
            pm.prod_name,
            pm.prod_code,
            pm.prod_notes,
            pid.service_sno,
            sm.service_name,
            sm.service_code,
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
        LEFT JOIN uom_master uom
            ON uom.uom_sno = pid.unit
        LEFT JOIN product_master pm
            ON pid.prod_sno = pm.prod_sno
        LEFT JOIN service_master sm
            ON pid.service_sno = sm.service_sno
        WHERE pid.pr_basic_sno = pbf.pr_basic_sno
          AND pid.is_active = 'Y'
          AND (pid.[group] = g.grp OR (pid.[group] IS NULL AND g.grp IS NULL))
        FOR JSON PATH
    ) AS pr_item_details,

    -- Workflow stage JSON
    (
        SELECT
            ws.stage_order_json
        FROM workflow_stage ws
        WHERE ws.workflow_types_id = pbf.workflow_types_id
          AND ws.is_active = 'Y'
    ) AS stage_order_json,

    (
        SELECT
            phd.status_by, vve.ename, phd.status_date, phd.commends, phd.pr_edit_data
        FROM pr_history_data phd
        INNER JOIN vw_verified_employees vve
            ON phd.status_by = vve.ecno
        WHERE phd.pr_basic_sno = pbf.pr_basic_sno
        FOR JSON PATH
    ) AS pr_history_data

FROM pr_basic_info pbf
INNER JOIN workflow_types wt
    ON pbf.workflow_types_id = wt.workflow_types_id
INNER JOIN vw_ActiveDeptRecords vadr
    ON pbf.brn_sno   = vadr.brn_sno
   AND pbf.dept_sno  = vadr.dept_sno
INNER JOIN vw_verified_employees vve
    ON pbf.created_by = vve.ecno
OUTER APPLY (
    -- one row per distinct group in this PR; group_count = number of groups
    SELECT
        pid.[group]      AS grp,
        COUNT(*) OVER () AS group_count
    FROM pr_item_details pid
    WHERE pid.pr_basic_sno = pbf.pr_basic_sno
      AND pid.is_active = 'Y'
    GROUP BY pid.[group]
) g;
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM sys.columns WHERE object_id = OBJECT_ID('dbo.pr_basic_info') AND name IN ('category','source_invoice_sno');
--   SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID('dbo.usp_InsertPurchaseRequest');
--
-- Manual smoke test — create a PR via CivilWorksRequisitionPage and confirm:
--   SELECT TOP 1 pr_no, category, source_invoice_sno FROM pr_basic_info ORDER BY pr_basic_sno DESC;
-- should show category='CIVIL'.
-- ============================================================
