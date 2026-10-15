-- ============================================================
-- 124_approval_entity_routing.sql  (Non_trade_Dev)
--
-- WHY
-- ---
-- Which approval workflow a request uses is decided by approval_workflow_master.entity_type.
-- Until now each create-SP hard-coded that string ('ServiceAgreement', 'PurchaseRequisition',
-- ...), so "Fixed" and "Unfixed" agreements (or Regular and Vendor-driven PRs) could only share a
-- workflow or be split by editing stored procedures.
--
-- WHAT
-- ----
-- A routing table: (module, variant) -> entity_type, edited on the Approval Workflows screen.
--   module   = the kind of request   (PurchaseRequisition, ServiceAgreement, ServicePO)
--   variant  = what tells them apart (PR: NORMAL / VENDOR_DRIVEN; services: every row of
--              service_type_master, so a NEW service type appears here with no code change)
--   entity   = a row of entity_master. To give Fixed its own approvers: create a dedicated entity
--              (e.g. ServiceAgreement_FIXED_RECURRING), point the route at it, then create the
--              workflow for that entity like any other.
-- Defaults reproduce today's behaviour exactly (every service type -> ServiceAgreement / ServicePO,
-- Regular PR -> PurchaseRequisition, Vendor-driven -> VendorDrivenPurchaseRequisition).
-- A variant with no route resolves to the module's own entity, so nothing can be left unrouted.
--
-- Condition fields (amount / category / priority ...) are keyed by entity: a dedicated variant
-- entity with no fields of its own inherits its module's (fn_approval_field_entity).
--
-- NOT in this file: the conditional-stage ENGINE (stage conditions, forward/send-back) is still PR
-- only (sql/99) - Service Agreement / Service PO / PO still advance through their own linear logic.
-- ============================================================

-- entity_master: which module an entity serves
IF COL_LENGTH('dbo.entity_master', 'route_module_code') IS NULL
    ALTER TABLE dbo.entity_master ADD route_module_code NVARCHAR(50) NULL;
GO
UPDATE dbo.entity_master SET route_module_code = N'PurchaseRequisition'
 WHERE entity_code IN (N'PurchaseRequisition', N'VendorDrivenPurchaseRequisition') AND route_module_code IS NULL;
UPDATE dbo.entity_master SET route_module_code = entity_code
 WHERE entity_code IN (N'ServiceAgreement', N'ServicePO') AND route_module_code IS NULL;
GO

-- modules + static variants
IF OBJECT_ID('dbo.approval_route_module', 'U') IS NULL
CREATE TABLE dbo.approval_route_module (
    module_code   NVARCHAR(50)  NOT NULL PRIMARY KEY,
    module_label  NVARCHAR(100) NOT NULL,
    variant_label NVARCHAR(60)  NOT NULL,
    description   NVARCHAR(300) NULL,
    sort_order    INT           NOT NULL DEFAULT 0
);
GO
IF OBJECT_ID('dbo.approval_route_variant', 'U') IS NULL
CREATE TABLE dbo.approval_route_variant (
    module_code   NVARCHAR(50) NOT NULL,
    variant_code  NVARCHAR(50) NOT NULL,
    variant_label NVARCHAR(100) NOT NULL,
    sort_order    INT NOT NULL DEFAULT 0,
    CONSTRAINT PK_approval_route_variant PRIMARY KEY (module_code, variant_code)
);
GO
MERGE dbo.approval_route_module AS t
USING (VALUES
    (N'PurchaseRequisition', N'Purchase Requisition', N'Request type',   N'Regular PR vs Vendor-driven PR',          1),
    (N'ServiceAgreement',    N'Service Agreement',    N'Agreement type', N'One variant per Service Type master row', 2),
    (N'ServicePO',           N'Service PO',           N'Agreement type', N'Per-cycle PO of each Service Type',       3)
) AS s(module_code, module_label, variant_label, description, sort_order)
ON t.module_code = s.module_code
WHEN NOT MATCHED THEN INSERT (module_code, module_label, variant_label, description, sort_order)
     VALUES (s.module_code, s.module_label, s.variant_label, s.description, s.sort_order);
GO
MERGE dbo.approval_route_variant AS t
USING (VALUES
    (N'PurchaseRequisition', N'NORMAL',        N'Regular',       1),
    (N'PurchaseRequisition', N'VENDOR_DRIVEN', N'Vendor driven', 2)
) AS s(module_code, variant_code, variant_label, sort_order)
ON t.module_code = s.module_code AND t.variant_code = s.variant_code
WHEN NOT MATCHED THEN INSERT (module_code, variant_code, variant_label, sort_order)
     VALUES (s.module_code, s.variant_code, s.variant_label, s.sort_order);
GO

-- Variants = the static ones + every service type (a new service type needs no code or seed).
CREATE OR ALTER VIEW dbo.vw_approval_route_variant AS
SELECT v.module_code, v.variant_code, v.variant_label, v.sort_order
FROM dbo.approval_route_variant v
UNION ALL
SELECT m.module_code,
       CAST(st.service_type_code AS NVARCHAR(50)),
       CAST(st.service_type_name AS NVARCHAR(100)),
       100 + st.service_type_sno
FROM dbo.service_type_master st
CROSS JOIN (SELECT module_code FROM dbo.approval_route_module WHERE module_code IN (N'ServiceAgreement', N'ServicePO')) m
WHERE st.is_active = 'Y';
GO

-- the routing table
IF OBJECT_ID('dbo.approval_entity_route', 'U') IS NULL
CREATE TABLE dbo.approval_entity_route (
    route_id     INT IDENTITY(1,1) PRIMARY KEY,
    module_code  NVARCHAR(50) NOT NULL,
    variant_code NVARCHAR(50) NOT NULL,            -- a variant, or '*' = every variant without its own row
    entity_code  NVARCHAR(50) NOT NULL,
    is_active    CHAR(1) NOT NULL DEFAULT 'Y',
    modified_by  VARCHAR(20) NULL,
    modified_at  DATETIME NOT NULL DEFAULT GETDATE(),
    CONSTRAINT UQ_approval_entity_route UNIQUE (module_code, variant_code)
);
GO
INSERT INTO dbo.approval_entity_route (module_code, variant_code, entity_code, modified_by)
SELECT s.module_code, s.variant_code, s.entity_code, N'system'
FROM (
    SELECT N'PurchaseRequisition' module_code, N'NORMAL' variant_code, N'PurchaseRequisition' entity_code
    UNION ALL SELECT N'PurchaseRequisition', N'VENDOR_DRIVEN', N'VendorDrivenPurchaseRequisition'
    UNION ALL SELECT m.module_code, CAST(st.service_type_code AS NVARCHAR(50)), m.module_code
              FROM dbo.service_type_master st
              CROSS JOIN (SELECT N'ServiceAgreement' module_code UNION ALL SELECT N'ServicePO') m
) s
WHERE NOT EXISTS (SELECT 1 FROM dbo.approval_entity_route r WHERE r.module_code = s.module_code AND r.variant_code = s.variant_code);
GO

-- resolvers
-- (module, variant) -> entity_type: own row, else the '*' row, else the module's own entity.
CREATE OR ALTER FUNCTION dbo.fn_resolve_approval_entity (@module VARCHAR(50), @variant VARCHAR(50))
RETURNS VARCHAR(50)
AS
BEGIN
    RETURN ISNULL((
        SELECT TOP 1 r.entity_code
        FROM dbo.approval_entity_route r
        WHERE r.is_active = 'Y' AND r.module_code = @module AND r.variant_code IN (ISNULL(@variant, N'*'), N'*')
        ORDER BY CASE WHEN r.variant_code = @variant THEN 0 ELSE 1 END
    ), @module);
END;
GO
-- Which entity's approval_condition_field rows describe this entity: its own if it has any, else
-- the module it serves (a dedicated "Fixed" entity offers the same condition fields).
CREATE OR ALTER FUNCTION dbo.fn_approval_field_entity (@entity VARCHAR(50))
RETURNS VARCHAR(50)
AS
BEGIN
    RETURN CASE
        WHEN EXISTS (SELECT 1 FROM dbo.approval_condition_field WHERE entity_type = @entity AND is_active = 'Y') THEN @entity
        ELSE ISNULL((SELECT route_module_code FROM dbo.entity_master WHERE entity_code = @entity), @entity)
    END;
END;
GO

-- entity list now carries route_module_code
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetEntityRecords
AS
BEGIN
    SET NOCOUNT ON;
    SELECT entity_sno, entity_name, entity_code, entity_desc, is_active, route_module_code
    FROM dbo.entity_master
    WHERE is_active = 'Y'
    ORDER BY entity_name;
END;
GO

-- read the matrix
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetApprovalRoutes
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.module_code, m.module_label, m.variant_label AS variants_called,
           v.variant_code, v.variant_label,
           x.entity_code, em.entity_name,
           CAST(CASE WHEN r.route_id IS NULL THEN 0 ELSE 1 END AS BIT) AS has_route,
           (SELECT COUNT(*) FROM dbo.vw_approval_route_variant v2
             WHERE v2.module_code = v.module_code AND v2.variant_code <> v.variant_code
               AND dbo.fn_resolve_approval_entity(v2.module_code, v2.variant_code) = x.entity_code) AS shared_with,
           (SELECT COUNT(*) FROM dbo.approval_workflow_master w WHERE w.is_active = 'Y' AND w.entity_type = x.entity_code) AS workflows_configured,
           (SELECT e.entity_code, e.entity_name
              FROM dbo.entity_master e
             WHERE e.is_active = 'Y' AND e.route_module_code = m.module_code
             ORDER BY e.entity_name FOR JSON PATH) AS eligible_entities
    FROM dbo.approval_route_module m
    JOIN dbo.vw_approval_route_variant v ON v.module_code = m.module_code
    CROSS APPLY (SELECT dbo.fn_resolve_approval_entity(v.module_code, v.variant_code) AS entity_code) x
    LEFT JOIN dbo.approval_entity_route r ON r.module_code = v.module_code AND r.variant_code = v.variant_code AND r.is_active = 'Y'
    LEFT JOIN dbo.entity_master em ON em.entity_code = x.entity_code
    ORDER BY m.sort_order, v.sort_order, v.variant_code;
END;
GO

-- point a variant at an entity
-- {"module_code","variant_code","entity_code","modified_by","force"}
-- Re-pointing is held back (NEEDS_CONFIRM) while org scopes that have a workflow today would be left
-- with none under the new entity - creating that request there would then throw "no workflow".
CREATE OR ALTER PROCEDURE dbo.sp_nt_SaveApprovalRoute
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 52101, N'Invalid JSON payload.', 1;
    DECLARE @module NVARCHAR(50) = JSON_VALUE(@jsonInput, '$.module_code'),
            @variant NVARCHAR(50) = JSON_VALUE(@jsonInput, '$.variant_code'),
            @entity NVARCHAR(50) = JSON_VALUE(@jsonInput, '$.entity_code'),
            @by VARCHAR(20) = JSON_VALUE(@jsonInput, '$.modified_by'),
            @force BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.force') IN ('true','1') THEN 1 ELSE 0 END;

    IF @module IS NULL OR @variant IS NULL OR @entity IS NULL THROW 52102, N'module_code, variant_code and entity_code are required.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.vw_approval_route_variant WHERE module_code = @module AND variant_code = @variant)
        THROW 52103, N'Unknown request type / variant.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.entity_master WHERE entity_code = @entity AND is_active = 'Y' AND route_module_code = @module)
        THROW 52104, N'That approval type is not available for this kind of request.', 1;

    DECLARE @old NVARCHAR(50) = dbo.fn_resolve_approval_entity(@module, @variant);
    IF @old = @entity
    BEGIN
        SELECT N'UNCHANGED' AS status, @entity AS entity_code, CAST(0 AS INT) AS scopes_missing;
        RETURN;
    END;

    DECLARE @missing INT = (
        SELECT COUNT(*) FROM (
            SELECT DISTINCT wt.com_sno, wt.div_sno, wt.brn_sno, wt.dept_sno
            FROM dbo.workflow_types wt JOIN dbo.approval_workflow_master a ON a.workflow_id = wt.workflow_id
            WHERE a.entity_type = @old AND a.is_active = 'Y' AND wt.is_active = 'Y'
        ) o
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.workflow_types w2 JOIN dbo.approval_workflow_master b ON b.workflow_id = w2.workflow_id
            WHERE b.entity_type = @entity AND b.is_active = 'Y' AND w2.is_active = 'Y'
              AND w2.com_sno = o.com_sno AND w2.div_sno = o.div_sno AND w2.brn_sno = o.brn_sno AND w2.dept_sno = o.dept_sno));

    IF @missing > 0 AND @force = 0
    BEGIN
        SELECT N'NEEDS_CONFIRM' AS status, @entity AS entity_code, @missing AS scopes_missing;
        RETURN;
    END;

    MERGE dbo.approval_entity_route AS t
    USING (SELECT @module AS module_code, @variant AS variant_code) AS s
       ON t.module_code = s.module_code AND t.variant_code = s.variant_code
    WHEN MATCHED THEN UPDATE SET entity_code = @entity, is_active = 'Y', modified_by = @by, modified_at = GETDATE()
    WHEN NOT MATCHED THEN INSERT (module_code, variant_code, entity_code, modified_by) VALUES (@module, @variant, @entity, @by);

    SELECT N'SUCCESS' AS status, @entity AS entity_code, @missing AS scopes_missing;
END;
GO

-- create a dedicated approval type for one variant
-- {"module_code","variant_code","created_by"}  -> entity "<module>_<variant>" (idempotent).
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateApprovalVariantEntity
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 52101, N'Invalid JSON payload.', 1;
    DECLARE @module NVARCHAR(50) = JSON_VALUE(@jsonInput, '$.module_code'),
            @variant NVARCHAR(50) = JSON_VALUE(@jsonInput, '$.variant_code'),
            @by VARCHAR(20) = JSON_VALUE(@jsonInput, '$.created_by');
    DECLARE @vlabel NVARCHAR(100), @mlabel NVARCHAR(100);
    SELECT @vlabel = v.variant_label, @mlabel = m.module_label
    FROM dbo.vw_approval_route_variant v JOIN dbo.approval_route_module m ON m.module_code = v.module_code
    WHERE v.module_code = @module AND v.variant_code = @variant;
    IF @vlabel IS NULL THROW 52103, N'Unknown request type / variant.', 1;

    DECLARE @code NVARCHAR(50) = LEFT(@module + N'_' + @variant, 50);
    IF NOT EXISTS (SELECT 1 FROM dbo.entity_master WHERE entity_code = @code)
        INSERT INTO dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by, route_module_code)
        VALUES (LEFT(@mlabel + N' - ' + @vlabel, 100), @code, N'Dedicated approval type for ' + @mlabel + N' / ' + @vlabel, 'Y', @by, @module);
    ELSE
        UPDATE dbo.entity_master SET is_active = 'Y', route_module_code = @module WHERE entity_code = @code;

    SELECT entity_sno, entity_code, entity_name FROM dbo.entity_master WHERE entity_code = @code;
END;
GO

-- ── usp_InsertPurchaseRequest: route Regular PRs through the mapping ──────
CREATE OR ALTER PROCEDURE [dbo].[usp_InsertPurchaseRequest]
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
            @created_by         = JSON_VALUE(@jsonInput, '$.ecno');

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
  AND awm.entity_type  = dbo.fn_resolve_approval_entity('PurchaseRequisition', 'NORMAL');
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

-- ── usp_InsertVendorDrivenPurchaseRequest: route Vendor-driven PRs through the mapping ───
CREATE OR ALTER PROCEDURE dbo.usp_InsertVendorDrivenPurchaseRequest
    @jsonInput NVARCHAR(MAX),
    @pr_no     VARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ------------------------------------------------------------------
    -- 1. Parse input JSON
    -- ------------------------------------------------------------------
    DECLARE
        @com_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.com_sno') AS INT),
        @div_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.div_sno') AS INT),
        @brn_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.brn_sno') AS INT),
        @dept_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.dept_sno') AS INT),
        @reg_date           DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.req_date') AS DATE),
        @required_date      DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.required_date') AS DATE),
        @priority_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.priority_sno') AS INT),
        @purpose            NVARCHAR(500) = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.purpose'), ''),
        @vendor_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.vendor_sno') AS INT),
        @payment_cycle_days INT           = COALESCE(TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.payment_cycle_days') AS INT), 15),
        @attachment         NVARCHAR(500) = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.attachment'), ''),
        @created_by         VARCHAR(20)   = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.created_by'), ''),
        @items              NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items'),

        @workflow_types_id  INT,
        @workflow_id        INT,
        @first_approver     VARCHAR(20),
        @pr_basic_sno       INT,
        @financial_year     VARCHAR(10),
        @sequence_number    INT,
        @items_inserted     INT;

    DECLARE @insertedItems TABLE
    (
        pr_item_sno    INT,
        item_rate      DECIMAL(18,4),
        gst_pct        DECIMAL(5,2),
        discount_pct   DECIMAL(5,2),
        taxable_amount DECIMAL(18,2),
        gst_amount     DECIMAL(18,2)
    );

    -- ------------------------------------------------------------------
    -- 2. Validate input
    -- ------------------------------------------------------------------
    IF ISJSON(@jsonInput) <> 1
        THROW 59001, 'Invalid vendor-driven requisition payload.', 1;

    IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
       OR @reg_date IS NULL OR @required_date IS NULL OR @priority_sno IS NULL
       OR @vendor_sno IS NULL OR @created_by IS NULL
        THROW 59002, 'Company, division, branch, department, dates, priority, supplier and creator are required.', 1;

    IF @payment_cycle_days < 1 OR @payment_cycle_days > 365
        THROW 59003, 'payment_cycle_days must be between 1 and 365.', 1;

    IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
        THROW 59004, 'At least one vendor-driven item is required.', 1;

    IF @attachment IS NULL
        THROW 59009, 'A verification document (bill/receipt) for the requisition is required.', 1;

    IF EXISTS (
        SELECT 1
        FROM OPENJSON(@items)
        WHERE TRY_CAST(JSON_VALUE(value, '$.prod_sno') AS INT) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.unit_sno') AS INT) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)) <= 0
           OR TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)) < 0
           OR (
                JSON_VALUE(value, '$.discount_pct') IS NOT NULL
                AND (
                    TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)) IS NULL
                    OR TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)) < 0
                    OR TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)) > 100
                )
              )
    )
        THROW 59005, 'Every vendor-driven item requires product, unit, positive quantity, rate, and (if present) a discount_pct between 0 and 100.', 1;

    -- ------------------------------------------------------------------
    -- 3. Resolve approval workflow
    -- ------------------------------------------------------------------
    SELECT
        @workflow_id       = wt.workflow_id,
        @workflow_types_id = wt.workflow_types_id
    FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE wt.com_sno  = @com_sno
      AND wt.div_sno  = @div_sno
      AND wt.brn_sno  = @brn_sno
      AND wt.dept_sno = @dept_sno
      AND awm.entity_type = dbo.fn_resolve_approval_entity('PurchaseRequisition', 'VENDOR_DRIVEN');

    IF @workflow_types_id IS NULL
        THROW 59006, 'No VendorDrivenPurchaseRequisition workflow is configured for this organisation scope.', 1;

    SELECT @first_approver = JSON_VALUE(stage_member.value, '$.approver_ecno')
    FROM dbo.vw_workflow_stages ws
    CROSS APPLY OPENJSON(ws.stages_json) stage_group
    CROSS APPLY OPENJSON(JSON_VALUE(stage_group.value, '$.stage_order_json')) stage_member
    WHERE ws.workflow_types_id = @workflow_types_id
      AND stage_group.[key]  = '0'
      AND stage_member.[key] = '0';

    IF @first_approver IS NULL
        THROW 59007, 'The VendorDrivenPurchaseRequisition workflow has no first approver.', 1;

    -- ------------------------------------------------------------------
    -- 4. Create the requisition
    -- ------------------------------------------------------------------
    BEGIN TRANSACTION;
    BEGIN TRY

        SET @financial_year = dbo.fn_GetFinancialYear(GETDATE());

        SELECT @sequence_number = ISNULL(MAX(TRY_CAST(RIGHT(pr_no, 4) AS INT)), 0) + 1
        FROM dbo.pr_basic_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE 'VPR' + @financial_year + '-%';

        SET @pr_no = 'VPR' + @financial_year + '-' + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);

        INSERT INTO dbo.pr_basic_info
        (
            pr_no, com_sno, div_sno, brn_sno, dept_sno, reg_date, required_date,
            priority_sno, purpose, request_mode, vendor_sno, payment_cycle_days,
            is_active, created_by, created_date, workflow_types_id, current_approver_id, status
        )
        VALUES
        (
            @pr_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @reg_date, @required_date,
            @priority_sno, @purpose, 'VENDOR_DRIVEN', @vendor_sno, @payment_cycle_days,
            'Y', @created_by, GETDATE(), @workflow_types_id, @first_approver, 'P'
        );

        SET @pr_basic_sno = SCOPE_IDENTITY();

        INSERT INTO dbo.pr_item_details
        (
            pr_no, pr_basic_sno, prod_sno, qty, unit, est_cost, total_cost,
            remarks, specification, item_type, is_active,
            created_by, created_date, item_description, item_rate, gst_pct,
            discount_pct, taxable_amount, gst_amount
        )
        OUTPUT
            inserted.pr_item_sno, inserted.item_rate, inserted.gst_pct,
            inserted.discount_pct, inserted.taxable_amount, inserted.gst_amount
        INTO @insertedItems
        SELECT
            @pr_no,
            @pr_basic_sno,
            TRY_CAST(JSON_VALUE(value, '$.prod_sno') AS INT),
            TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)),
            TRY_CAST(JSON_VALUE(value, '$.unit_sno') AS INT),
            TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
            t.taxable_amount + g2.gst_amount,
            NULLIF(JSON_VALUE(value, '$.remarks'), ''),
            NULLIF(JSON_VALUE(value, '$.specification'), ''),
            'vendor_driven',
            'Y',
            @created_by,
            GETDATE(),
            NULLIF(JSON_VALUE(value, '$.prod_name'), ''),
            TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
            base.gst_pct_val,
            base.disc_pct,
            t.taxable_amount,
            g2.gst_amount
        FROM OPENJSON(@items)
        CROSS APPLY (
            SELECT
                gross       = TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4))
                              * TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
                disc_pct    = COALESCE(TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)), 0),
                gst_pct_val = COALESCE(TRY_CAST(JSON_VALUE(value, '$.gst_pct') AS DECIMAL(5,2)), 0)
        ) base
        CROSS APPLY (
            SELECT taxable_amount = ROUND(base.gross * (1 - base.disc_pct / 100), 2)
        ) t
        CROSS APPLY (
            SELECT gst_amount = ROUND(t.taxable_amount * base.gst_pct_val / 100, 2)
        ) g2;

        SET @items_inserted = @@ROWCOUNT;
        IF @items_inserted = 0
            THROW 59008, 'No vendor-driven items were inserted.', 1;

        INSERT INTO dbo.pr_vendor_driven_info (pr_basic_sno, vendor_sno, payment_cycle_days, attachment, created_by, created_date)
        VALUES (@pr_basic_sno, @vendor_sno, @payment_cycle_days, @attachment, @created_by, GETDATE());

        INSERT INTO dbo.pr_vendor_driven_item_details (pr_item_sno, item_rate, gst_pct, discount_pct, taxable_amount, gst_amount)
        SELECT pr_item_sno, item_rate, gst_pct, discount_pct, taxable_amount, gst_amount
        FROM @insertedItems;

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    -- ------------------------------------------------------------------
    -- 5. Return result
    -- ------------------------------------------------------------------
    SELECT
        @pr_basic_sno   AS pr_basic_sno,
        @pr_no          AS pr_no,
        @items_inserted AS items_inserted,
        'SUCCESS'       AS result;

END;
GO

-- ── sp_nt_CreateServiceAgreement: route by agreement type ─────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @com_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @service_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @vendor_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @qty                DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4));
        DECLARE @rate_amount        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @rate_uom_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_uom_sno') AS INT);
        DECLARE @recurrence_cadence_sno INT       = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_cadence_sno') AS INT);
        DECLARE @po_generation_day  SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_generation_day') AS SMALLINT);
        DECLARE @notify_days_before SMALLINT      = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.notify_days_before') AS SMALLINT), 0);
        DECLARE @period_start_date  DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url  NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @terms_conditions   NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.terms_conditions');
        DECLARE @ceiling_amount     DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @created_by         VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
        DECLARE @vendors_json       NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.vendors');
        DECLARE @statutory_json     NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.statutory');

        -- The first supplier in the split is the primary (service_agreement.vendor_sno).
        IF @vendors_json IS NOT NULL AND ISJSON(@vendors_json) = 1
            SET @vendor_sno = ISNULL(TRY_CAST(JSON_VALUE(@vendors_json, '$[0].vendor_sno') AS INT), @vendor_sno);

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @service_sno IS NULL OR @vendor_sno IS NULL OR @created_by IS NULL
            THROW 58101, 'com_sno, div_sno, brn_sno, dept_sno, service_sno, at least one supplier and created_by are required.', 1;

        IF @qty IS NULL OR @qty <= 0
            THROW 58102, 'qty must be a positive quantity.', 1;

        IF @rate_amount IS NULL OR @rate_amount <= 0
            THROW 58103, 'rate_amount must be a positive amount (an approximate value is fine for an Unfixed or Statutory agreement).', 1;

        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 58104, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;

        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 58105, 'agreement_doc_url is required — upload the agreement document before submitting.', 1;

        IF @recurrence_cadence_sno IS NULL
            THROW 58106, 'recurrence_cadence_sno is required — see sp_nt_GetRecurrenceCadenceRecords for valid options.', 1;

        DECLARE @interval_unit VARCHAR(10);
        SELECT @interval_unit = interval_unit FROM dbo.recurrence_cadence_master WHERE recurrence_cadence_sno = @recurrence_cadence_sno AND is_active = 'Y';
        IF @interval_unit IS NULL
            THROW 58107, 'recurrence_cadence_sno does not reference an active recurrence cadence.', 1;

        IF @interval_unit = 'MONTH'
        BEGIN
            IF @po_generation_day IS NULL OR @po_generation_day NOT BETWEEN 1 AND 31
                THROW 58108, 'po_generation_day (1-31) is required for a month-based recurrence cadence.', 1;
        END
        ELSE
            SET @po_generation_day = NULL;

        DECLARE @service_type_code VARCHAR(30);
        SELECT @service_type_code = st.service_type_code
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';

        IF @service_type_code IS NULL OR @service_type_code NOT IN ('FIXED_RECURRING', 'VARIABLE_RECURRING', 'STATUTORY')
            THROW 58109, 'service_sno must reference an active Fixed, Unfixed or Statutory service.', 1;

        IF @service_type_code = 'FIXED_RECURRING'
            SET @ceiling_amount = NULL;
        ELSE IF @ceiling_amount IS NOT NULL AND @ceiling_amount <= 0
            THROW 58112, 'ceiling_amount must be a positive amount when provided.', 1;

        -- ── Resolve the ServiceAgreement workflow for this org scope ───────
        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = dbo.fn_resolve_approval_entity('ServiceAgreement', @service_type_code);

        IF @workflow_types_id IS NULL
            THROW 58110, 'No ServiceAgreement workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key] = '0' AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 58111, 'No approver found for the first stage of the ServiceAgreement workflow.', 1;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(agreement_no, 4) AS INT)), 0) + 1
        FROM dbo.service_agreement WITH (UPDLOCK, HOLDLOCK)
        WHERE agreement_no LIKE 'AGR-' + @year + '-%';
        DECLARE @agreement_no VARCHAR(30) = 'AGR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.service_agreement (
            agreement_no, com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
            qty, rate_amount, rate_uom_sno, recurrence_cadence_sno, po_generation_day, notify_days_before,
            period_start_date, period_end_date, agreement_doc_url, remarks, terms_conditions, ceiling_amount,
            workflow_types_id, current_approver_id, status, is_active, created_by
        )
        VALUES (
            @agreement_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @service_sno, @vendor_sno,
            @qty, @rate_amount, @rate_uom_sno, @recurrence_cadence_sno, @po_generation_day, @notify_days_before,
            @period_start_date, @period_end_date, @agreement_doc_url, @remarks, @terms_conditions, @ceiling_amount,
            @workflow_types_id, @first_approver, 'P', 'Y', @created_by
        );

        DECLARE @agreement_sno INT = SCOPE_IDENTITY();

        DECLARE @total_per_cycle DECIMAL(18,2) = ROUND(@rate_amount * @qty, 2), @primary_vendor INT;
        EXEC dbo.sp_nt_SaveServiceAgreementSuppliers
            @agreement_sno = @agreement_sno, @vendors_json = @vendors_json, @fallback_vendor_sno = @vendor_sno,
            @total_amount = @total_per_cycle, @out_primary_vendor_sno = @primary_vendor OUTPUT;
        IF @primary_vendor IS NOT NULL AND @primary_vendor <> @vendor_sno
            UPDATE dbo.service_agreement SET vendor_sno = @primary_vendor WHERE agreement_sno = @agreement_sno;

        EXEC dbo.sp_nt_SaveServiceAgreementStatutory
            @agreement_sno = @agreement_sno, @service_type_code = @service_type_code, @statutory_json = @statutory_json;

        DECLARE @version_no INT;
        EXEC dbo.sp_nt_SnapshotServiceAgreementVersion
            @agreement_sno = @agreement_sno, @action_type = 'SUBMITTED', @submitted_by = @created_by,
            @out_version_no = @version_no OUTPUT;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
        VALUES (@agreement_sno, 'SUBMITTED', @created_by, NULL, @version_no);

        COMMIT TRANSACTION;

        SELECT @agreement_sno AS agreement_sno, @agreement_no AS agreement_no, 'SUCCESS' AS result,
               N'Service agreement submitted for approval.' AS message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── sp_nt_UpdateServiceAgreement: route by agreement type ─────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @agreement_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
        DECLARE @com_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @service_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @vendor_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @qty                DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4));
        DECLARE @rate_amount        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @rate_uom_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_uom_sno') AS INT);
        DECLARE @recurrence_cadence_sno INT       = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_cadence_sno') AS INT);
        DECLARE @po_generation_day  SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_generation_day') AS SMALLINT);
        DECLARE @notify_days_before SMALLINT      = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.notify_days_before') AS SMALLINT), 0);
        DECLARE @period_start_date  DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url  NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @terms_conditions   NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.terms_conditions');
        DECLARE @ceiling_amount     DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @edited_by          VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.edited_by');
        DECLARE @vendors_json       NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.vendors');
        DECLARE @statutory_json     NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.statutory');

        IF @vendors_json IS NOT NULL AND ISJSON(@vendors_json) = 1
            SET @vendor_sno = ISNULL(TRY_CAST(JSON_VALUE(@vendors_json, '$[0].vendor_sno') AS INT), @vendor_sno);

        IF @agreement_sno IS NULL OR @edited_by IS NULL
            THROW 58120, 'agreement_sno and edited_by are required.', 1;

        DECLARE @current_status CHAR(1), @old_period_end DATE;
        SELECT @current_status = status, @old_period_end = period_end_date
        FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno AND is_active = 'Y';
        IF @current_status IS NULL
            THROW 58121, 'Service agreement not found or inactive.', 1;
        IF @current_status NOT IN ('A', 'R', 'X')
            THROW 58122, 'Only an Approved, Rejected or Expired agreement can be edited or renewed (it is currently Pending approval).', 1;

        DECLARE @is_renewal BIT = CASE WHEN @current_status = 'X' THEN 1 ELSE 0 END;

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @service_sno IS NULL OR @vendor_sno IS NULL
            THROW 58123, 'com_sno, div_sno, brn_sno, dept_sno, service_sno and at least one supplier are required.', 1;
        IF @qty IS NULL OR @qty <= 0
            THROW 58124, 'qty must be a positive quantity.', 1;
        IF @rate_amount IS NULL OR @rate_amount <= 0
            THROW 58125, 'rate_amount must be a positive amount.', 1;
        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 58126, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;
        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 58127, 'agreement_doc_url is required.', 1;

        IF @is_renewal = 1
        BEGIN
            IF @period_start_date <= @old_period_end
            BEGIN
                DECLARE @renew_msg NVARCHAR(300) = N'A renewal must start after the expired term ended (' + CONVERT(NVARCHAR(10), @old_period_end, 23) + N').';
                THROW 58133, @renew_msg, 1;
            END
            IF @period_end_date < CAST(GETDATE() AS DATE)
                THROW 58134, 'The renewed period has already ended — choose a term that runs beyond today.', 1;
        END

        DECLARE @interval_unit VARCHAR(10);
        SELECT @interval_unit = interval_unit FROM dbo.recurrence_cadence_master WHERE recurrence_cadence_sno = @recurrence_cadence_sno AND is_active = 'Y';
        IF @interval_unit IS NULL
            THROW 58128, 'recurrence_cadence_sno does not reference an active recurrence cadence.', 1;
        IF @interval_unit = 'MONTH'
        BEGIN
            IF @po_generation_day IS NULL OR @po_generation_day NOT BETWEEN 1 AND 31
                THROW 58129, 'po_generation_day (1-31) is required for a month-based recurrence cadence.', 1;
        END
        ELSE
            SET @po_generation_day = NULL;

        DECLARE @service_type_code VARCHAR(30);
        SELECT @service_type_code = st.service_type_code
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';
        IF @service_type_code IS NULL OR @service_type_code NOT IN ('FIXED_RECURRING', 'VARIABLE_RECURRING', 'STATUTORY')
            THROW 58135, 'service_sno must reference an active Fixed, Unfixed or Statutory service.', 1;
        IF @service_type_code = 'FIXED_RECURRING'
            SET @ceiling_amount = NULL;
        ELSE IF @ceiling_amount IS NOT NULL AND @ceiling_amount <= 0
            THROW 58132, 'ceiling_amount must be a positive amount when provided.', 1;

        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = dbo.fn_resolve_approval_entity('ServiceAgreement', @service_type_code);
        IF @workflow_types_id IS NULL
            THROW 58130, 'No ServiceAgreement workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id AND s.[key] = '0' AND s2.[key] = '0';
        IF @first_approver IS NULL
            THROW 58131, 'No approver found for the first stage of the ServiceAgreement workflow.', 1;

        UPDATE dbo.service_agreement
        SET com_sno = @com_sno, div_sno = @div_sno, brn_sno = @brn_sno, dept_sno = @dept_sno,
            service_sno = @service_sno, vendor_sno = @vendor_sno, qty = @qty, rate_amount = @rate_amount,
            rate_uom_sno = @rate_uom_sno, recurrence_cadence_sno = @recurrence_cadence_sno,
            po_generation_day = @po_generation_day, notify_days_before = @notify_days_before,
            period_start_date = @period_start_date, period_end_date = @period_end_date,
            agreement_doc_url = @agreement_doc_url, remarks = @remarks, terms_conditions = @terms_conditions,
            ceiling_amount = @ceiling_amount,
            workflow_types_id = @workflow_types_id, current_approver_id = @first_approver,
            status = 'P', modified_by = @edited_by, modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno;

        DECLARE @total_per_cycle DECIMAL(18,2) = ROUND(@rate_amount * @qty, 2), @primary_vendor INT;
        EXEC dbo.sp_nt_SaveServiceAgreementSuppliers
            @agreement_sno = @agreement_sno, @vendors_json = @vendors_json, @fallback_vendor_sno = @vendor_sno,
            @total_amount = @total_per_cycle, @out_primary_vendor_sno = @primary_vendor OUTPUT;
        IF @primary_vendor IS NOT NULL AND @primary_vendor <> @vendor_sno
            UPDATE dbo.service_agreement SET vendor_sno = @primary_vendor WHERE agreement_sno = @agreement_sno;

        EXEC dbo.sp_nt_SaveServiceAgreementStatutory
            @agreement_sno = @agreement_sno, @service_type_code = @service_type_code, @statutory_json = @statutory_json;

        DECLARE @edit_action VARCHAR(20) = CASE WHEN @is_renewal = 1 THEN 'RENEWED' ELSE 'RESUBMITTED' END;
        DECLARE @version_no INT;
        EXEC dbo.sp_nt_SnapshotServiceAgreementVersion
            @agreement_sno = @agreement_sno, @action_type = @edit_action, @submitted_by = @edited_by,
            @out_version_no = @version_no OUTPUT;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
        VALUES (@agreement_sno, @edit_action, @edited_by, NULL, @version_no);

        COMMIT TRANSACTION;

        SELECT @agreement_sno AS agreement_sno, @version_no AS version_no, 'SUCCESS' AS result,
               CASE WHEN @is_renewal = 1 THEN N'Service agreement renewed and submitted for approval.'
                    ELSE N'Service agreement updated and resubmitted for approval.' END AS message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── sp_nt_ResolveServicePoWorkflow: optional service type ─────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_ResolveServicePoWorkflow
    @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT,
    @workflow_types_id INT OUTPUT,
    @first_approver VARCHAR(30) OUTPUT,
    @service_type_code VARCHAR(30) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @entity VARCHAR(50) = dbo.fn_resolve_approval_entity('ServicePO', @service_type_code);

    SELECT @workflow_types_id = wt.workflow_types_id
    FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
      AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
      AND awm.entity_type = @entity;

    IF @workflow_types_id IS NULL
        THROW 58310, 'No ServicePO workflow configuration found for this company/division/branch/department (approval type for this agreement type).', 1;

    SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
    FROM dbo.vw_workflow_stages AS ws
    CROSS APPLY OPENJSON(ws.stages_json) AS s
    CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
    WHERE ws.workflow_types_id = @workflow_types_id
      AND s.[key] = '0' AND s2.[key] = '0';

    IF @first_approver IS NULL
        THROW 58311, 'No approver found for the first stage of the ServicePO workflow.', 1;
END;
GO

-- ── sp_nt_IssueRecurringServicePOCycle: pass the agreement type ───────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_IssueRecurringServicePOCycle
    @jsonInput NVARCHAR(MAX),
    @silent BIT = 0,
    @out_result VARCHAR(30) = NULL OUTPUT,
    @out_po_basic_sno INT = NULL OUTPUT,
    @out_po_no VARCHAR(50) = NULL OUTPUT,
    @out_pr_basic_sno INT = NULL OUTPUT,
    @out_pr_no VARCHAR(20) = NULL OUTPUT,
    @out_cycle_sno INT = NULL OUTPUT,
    @out_cycle_status VARCHAR(20) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @agreement_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
    DECLARE @billing_period_start DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.billing_period_start') AS DATE);
    DECLARE @issued_by VARCHAR(20) = ISNULL(JSON_VALUE(@jsonInput, '$.issued_by'), 'SYSTEM');

    -- Captured before any statement that could fail, so the CATCH block can
    -- always tell (a) whether a caller transaction was already open, and
    -- (b) whether THIS proc actually opened a transaction/savepoint of its
    -- own that it is responsible for undoing.
    DECLARE @outer_trancount INT = @@TRANCOUNT;
    DECLARE @own_scope_opened BIT = 0;

    BEGIN TRY
        IF @agreement_sno IS NULL OR @billing_period_start IS NULL
            THROW 58210, 'agreement_sno and billing_period_start are required.', 1;

        IF EXISTS (SELECT 1 FROM dbo.service_agreement_recurring_pr_log WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start)
        BEGIN
            SET @out_result = 'SKIPPED_ALREADY_CLAIMED';
            IF @silent = 0 SELECT @out_result AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start;
            RETURN;
        END

        DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @service_sno INT, @vendor_sno INT,
                @qty DECIMAL(18,4), @rate_amount DECIMAL(18,2), @rate_uom_sno INT, @agreement_no VARCHAR(30),
                @service_name NVARCHAR(150), @agr_status CHAR(1), @period_end DATE, @service_type_code VARCHAR(30);

        SELECT @com_sno = sa.com_sno, @div_sno = sa.div_sno, @brn_sno = sa.brn_sno, @dept_sno = sa.dept_sno,
               @service_sno = sa.service_sno, @vendor_sno = sa.vendor_sno, @qty = sa.qty, @rate_amount = sa.rate_amount,
               @rate_uom_sno = sa.rate_uom_sno, @agreement_no = sa.agreement_no, @agr_status = sa.status,
               @period_end = sa.period_end_date, @service_name = sm.service_name, @service_type_code = st.service_type_code
        FROM dbo.service_agreement sa
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sa.agreement_sno = @agreement_sno;

        IF @agr_status IS NULL THROW 58211, 'Agreement not found.', 1;
        IF @agr_status <> 'A' THROW 58212, 'Agreement is not Approved.', 1;

        -- sql/89: a Statutory agreement is a LOAN. It raises no PR / PO / cycle -- interest
        -- is billed through Bank Payment Vouchers (Loan Payments) instead.
        IF @service_type_code = 'STATUTORY'
        BEGIN
            SET @out_result = 'SKIPPED_STATUTORY';
            IF @silent = 0 SELECT @out_result AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start;
            RETURN;
        END
        IF @billing_period_start > @period_end THROW 58213, 'billing_period_start is past the agreement period_end_date.', 1;

        -- Claim the slot before doing any real work, outside the main
        -- transaction, so it survives a rollback and guarantees idempotency
        -- even under a concurrent sweep.
        INSERT INTO dbo.service_agreement_recurring_pr_log (agreement_sno, billing_period_start, status)
        VALUES (@agreement_sno, @billing_period_start, 'PENDING');

        -- Nestable-safe: reuse the caller's transaction via a savepoint
        -- instead of opening our own when one is already open (see file
        -- header) — a failure below then only undoes this proc's own
        -- work, never the caller's.
        IF @outer_trancount = 0
            BEGIN TRANSACTION;
        ELSE
            SAVE TRANSACTION svp_IssueCycle;
        SET @own_scope_opened = 1;

        DECLARE @default_priority_sno INT;
        SELECT TOP 1 @default_priority_sno = priority_sno
        FROM dbo.priority_master
        WHERE is_active = 'Y'
        ORDER BY CASE WHEN priority_name = 'Medium' THEN 0 ELSE 1 END, priority_sno;
        IF @default_priority_sno IS NULL
            THROW 58214, 'No active priority_master row found to assign to the auto-generated PR.', 1;

        DECLARE @current_year VARCHAR(10) = dbo.fn_GetFinancialYear(GETDATE());
        DECLARE @pr_prefix VARCHAR(20) = 'PR' + @current_year;
        DECLARE @pr_seq INT;
        SELECT @pr_seq = ISNULL(MAX(CASE WHEN pr_no LIKE @pr_prefix + '%' THEN TRY_CAST(SUBSTRING(pr_no, LEN(@pr_prefix) + 1, LEN(pr_no)) AS INT) ELSE 0 END), 0) + 1
        FROM dbo.pr_basic_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE @pr_prefix + '%';
        DECLARE @pr_no VARCHAR(20) = @pr_prefix + RIGHT('0000' + CAST(@pr_seq AS VARCHAR(4)), 4);

        -- Auto-approved: status='A', no workflow — same audit-trail-only PR
        -- as before this file, untouched.
        INSERT INTO dbo.pr_basic_info (
            pr_no, com_sno, div_sno, brn_sno, dept_sno, reg_date, required_date, priority_sno, purpose,
            is_active, created_by, created_date, workflow_types_id, current_approver_id, status
        )
        VALUES (
            @pr_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @billing_period_start, @billing_period_start, @default_priority_sno,
            N'Auto-generated recurring PR — Service Agreement ' + @agreement_no,
            'Y', @issued_by, GETDATE(), NULL, NULL, 'A'
        );
        DECLARE @pr_basic_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.pr_item_details (
            pr_no, pr_basic_sno, prod_sno, qty, unit, est_cost, total_cost, remarks, specification,
            item_type, service_sno, agreement_sno, is_active, created_by, created_date
        )
        VALUES (
            @pr_no, @pr_basic_sno, NULL, @qty, @rate_uom_sno, @rate_amount, @rate_amount * @qty, '', '',
            'service', @service_sno, @agreement_sno, 'Y', @issued_by, GETDATE()
        );

        -- ── Queue a service_po_cycle instead of issuing the PO directly.
        --    Fixed: nothing to enter, straight to Pending Approval with the
        --    agreement's already-agreed rate/qty. Unfixed: Pending Entry,
        --    rate resolved later by sp_nt_SubmitServicePoEntry. ───────────
        DECLARE @cycle_status VARCHAR(20), @cycle_workflow_types_id INT = NULL, @cycle_approver VARCHAR(30) = NULL,
                @cycle_rate DECIMAL(18,2) = NULL, @cycle_net_cost DECIMAL(18,2) = NULL;

        IF @service_type_code = 'FIXED_RECURRING'
        BEGIN
            SET @cycle_status = 'PENDING_APPROVAL';
            SET @cycle_rate = @rate_amount;
            SET @cycle_net_cost = @rate_amount * @qty;
            EXEC dbo.sp_nt_ResolveServicePoWorkflow
                @com_sno = @com_sno, @div_sno = @div_sno, @brn_sno = @brn_sno, @dept_sno = @dept_sno,
                @workflow_types_id = @cycle_workflow_types_id OUTPUT, @first_approver = @cycle_approver OUTPUT,
                @service_type_code = @service_type_code;
        END
        ELSE
            SET @cycle_status = 'PENDING_ENTRY';

        INSERT INTO dbo.service_po_cycle (
            agreement_sno, com_sno, div_sno, brn_sno, dept_sno, billing_period_start,
            pr_basic_sno, pr_no, qty, rate_amount, net_cost, status,
            workflow_types_id, current_approver_id
        )
        VALUES (
            @agreement_sno, @com_sno, @div_sno, @brn_sno, @dept_sno, @billing_period_start,
            @pr_basic_sno, @pr_no, @qty, @cycle_rate, @cycle_net_cost, @cycle_status,
            @cycle_workflow_types_id, @cycle_approver
        );
        DECLARE @cycle_sno INT = SCOPE_IDENTITY();

        -- sql/88: a Fixed cycle already knows its rate, so split it across the
        -- agreement's suppliers now (Unfixed/Statutory do this when the rate is entered).
        IF @cycle_status = 'PENDING_APPROVAL'
        BEGIN
            DECLARE @split_net DECIMAL(18,2);
            EXEC dbo.sp_nt_BuildServicePoCycleSplit
                @cycle_sno = @cycle_sno, @agreement_sno = @agreement_sno, @rate_amount = @rate_amount, @qty = @qty,
                @discount_pct = 0, @gst_pct = 0, @out_net_cost = @split_net OUTPUT;
            UPDATE dbo.service_po_cycle SET net_cost = @split_net WHERE cycle_sno = @cycle_sno;
        END

        INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
        VALUES (@cycle_sno, 'CYCLE_CREATED', @issued_by,
                CASE WHEN @cycle_status = 'PENDING_APPROVAL' THEN N'Fixed agreement — queued directly for approval.' ELSE N'Unfixed agreement — awaiting rate/GST entry.' END);

        UPDATE dbo.service_agreement_recurring_pr_log
        SET status = 'CREATED', pr_basic_sno = @pr_basic_sno, pr_no = @pr_no, modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start;

        IF @outer_trancount = 0
            COMMIT TRANSACTION;

        SET @out_result = 'SUCCESS';
        SET @out_pr_basic_sno = @pr_basic_sno;
        SET @out_pr_no = @pr_no;
        SET @out_cycle_sno = @cycle_sno;
        SET @out_cycle_status = @cycle_status;

        IF @silent = 0
            SELECT 'SUCCESS' AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start,
                   @pr_basic_sno AS pr_basic_sno, @pr_no AS pr_no, @cycle_sno AS cycle_sno, @cycle_status AS cycle_status;
    END TRY
    BEGIN CATCH
        IF @own_scope_opened = 1 AND XACT_STATE() <> 0
        BEGIN
            IF @outer_trancount = 0 OR XACT_STATE() = -1
                ROLLBACK TRANSACTION;
            ELSE
                ROLLBACK TRANSACTION svp_IssueCycle;
        END

        UPDATE dbo.service_agreement_recurring_pr_log
        SET status = 'FAILED', error_message = ERROR_MESSAGE(), modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start AND status = 'PENDING';

        SET @out_result = 'ERROR';
        IF @silent = 0 THROW;
    END CATCH
END;
GO

-- ── sp_nt_SubmitServicePoEntry: pass the agreement type ───────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_SubmitServicePoEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @cycle_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.cycle_sno') AS INT);
        DECLARE @rate_amount  DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @discount_pct DECIMAL(5,2)  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.discount_pct') AS DECIMAL(5,2)), 0);
        DECLARE @gst_pct      DECIMAL(5,2)  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.gst_pct') AS DECIMAL(5,2)), 0);
        DECLARE @remarks      NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @submitted_by VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.submitted_by');

        IF @cycle_sno IS NULL OR @rate_amount IS NULL OR @rate_amount <= 0 OR @submitted_by IS NULL
            THROW 58320, 'cycle_sno, rate_amount and submitted_by are required.', 1;
        IF @discount_pct < 0 OR @discount_pct > 100 OR @gst_pct < 0 OR @gst_pct > 100
            THROW 58324, 'discount_pct and gst_pct must be between 0 and 100.', 1;

        DECLARE @agreement_sno INT, @qty DECIMAL(18,4), @status VARCHAR(20),
                @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @ceiling_amount DECIMAL(18,2);
        SELECT @agreement_sno = spc.agreement_sno, @qty = spc.qty, @status = spc.status,
               @com_sno = spc.com_sno, @div_sno = spc.div_sno, @brn_sno = spc.brn_sno, @dept_sno = spc.dept_sno,
               @ceiling_amount = sa.ceiling_amount
        FROM dbo.service_po_cycle spc
        JOIN dbo.service_agreement sa ON sa.agreement_sno = spc.agreement_sno
        WHERE spc.cycle_sno = @cycle_sno;

        IF @agreement_sno IS NULL THROW 58321, 'Service PO cycle not found.', 1;
        IF @status <> 'PENDING_ENTRY' THROW 58322, 'This cycle is not awaiting entry.', 1;

        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30), @st_code VARCHAR(30);
        SELECT @st_code = st.service_type_code
        FROM dbo.service_agreement sa
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sa.agreement_sno = @agreement_sno;
        EXEC dbo.sp_nt_ResolveServicePoWorkflow
            @com_sno = @com_sno, @div_sno = @div_sno, @brn_sno = @brn_sno, @dept_sno = @dept_sno,
            @workflow_types_id = @workflow_types_id OUTPUT, @first_approver = @first_approver OUTPUT,
            @service_type_code = @st_code;

        BEGIN TRANSACTION;

        DECLARE @net_cost DECIMAL(18,2);
        EXEC dbo.sp_nt_BuildServicePoCycleSplit
            @cycle_sno = @cycle_sno, @agreement_sno = @agreement_sno, @rate_amount = @rate_amount, @qty = @qty,
            @discount_pct = @discount_pct, @gst_pct = @gst_pct, @out_net_cost = @net_cost OUTPUT;

        IF @ceiling_amount IS NOT NULL AND @net_cost > @ceiling_amount
            THROW 58323, 'Entered amount exceeds the agreement''s ceiling amount.', 1;

        UPDATE dbo.service_po_cycle
        SET rate_amount = @rate_amount, discount_pct = @discount_pct, gst_pct = @gst_pct, net_cost = @net_cost,
            remarks = @remarks, status = 'PENDING_APPROVAL',
            workflow_types_id = @workflow_types_id, current_approver_id = @first_approver,
            entered_by = @submitted_by, entered_at = GETDATE()
        WHERE cycle_sno = @cycle_sno;

        INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
        VALUES (@cycle_sno, 'ENTRY_SUBMITTED', @submitted_by,
                N'Rate ' + CAST(@rate_amount AS VARCHAR(30)) + N', GST ' + CAST(@gst_pct AS VARCHAR(10)) + N'%, Net ' + CAST(@net_cost AS VARCHAR(30)));

        COMMIT TRANSACTION;

        SELECT 'SUCCESS' AS result, @cycle_sno AS cycle_sno, @net_cost AS net_cost;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── sp_nt_GetApprovalConditionFields: variants inherit their module's fields ───
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetApprovalConditionFields
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @entity_type VARCHAR(50) = CASE WHEN ISJSON(@jsonInput) = 1 THEN JSON_VALUE(@jsonInput, '$.entity_type') END;

    SELECT field_key, field_label, value_kind, option_source, unit, help_text, sort_order
    FROM dbo.approval_condition_field
    WHERE is_active = 'Y' AND entity_type = dbo.fn_approval_field_entity(@entity_type)
    ORDER BY sort_order, field_key;
END
GO

-- ── sp_nt_PrApprovalContext: same inheritance for the field dictionary ────
CREATE OR ALTER PROCEDURE dbo.sp_nt_PrApprovalContext
    @pr_no VARCHAR(30),
    @ecno  VARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @base VARCHAR(30) = LEFT(@pr_no, CASE WHEN CHARINDEX('/', @pr_no) > 0 THEN CHARINDEX('/', @pr_no) - 1 ELSE LEN(@pr_no) END);
    DECLARE @pr_sno INT, @pr_status CHAR(1), @created_by VARCHAR(20), @mode VARCHAR(30), @wf INT, @entity_type VARCHAR(50);
    SELECT @pr_sno = pr_basic_sno, @pr_status = status, @created_by = created_by, @mode = request_mode, @wf = workflow_types_id
    FROM dbo.pr_basic_info WHERE pr_no = @base AND is_active = 'Y';
    IF @pr_sno IS NULL THROW 52005, N'Purchase Request not found or inactive.', 1;

    SELECT @entity_type = m.entity_type
    FROM dbo.workflow_types wt JOIN dbo.approval_workflow_master m ON m.workflow_id = wt.workflow_id
    WHERE wt.workflow_types_id = @wf;

    DECLARE @inst INT, @stages NVARCHAR(MAX), @cycle INT, @cur INT, @ret INT, @await BIT, @since DATETIME, @istatus CHAR(1), @floor INT;
    SELECT @inst = instance_id, @stages = stages_json, @cycle = cycle_no, @cur = current_seq, @ret = return_to_seq,
           @await = awaiting_requester, @since = current_since, @istatus = status, @floor = history_floor
    FROM dbo.approval_instance WHERE entity_type = 'PurchaseRequisition' AND entity_ref_id = @pr_sno;

    DECLARE @amount DECIMAL(18,3), @priority INT, @cats NVARCHAR(MAX), @subcats NVARCHAR(MAX), @ctx NVARCHAR(MAX);
    SELECT @amount = amount, @priority = priority_sno, @cats = cats, @subcats = subcats, @ctx = context_json
    FROM dbo.fn_pr_approval_context(@pr_sno);

    CREATE TABLE #stg (seq INT PRIMARY KEY, stage_name NVARCHAR(100), approver_ecno VARCHAR(30), approver_name NVARCHAR(200),
                       alternates_json NVARCHAR(MAX), alternate_names NVARCHAR(MAX), escalation_hours INT,
                       can_forward CHAR(1), can_backward CHAR(1), can_edit_data CHAR(1),
                       condition_json NVARCHAR(MAX), condition_met BIT, state VARCHAR(16),
                       acted_by VARCHAR(30), acted_by_name NVARCHAR(200), acted_at DATETIME, comments NVARCHAR(1000));
    CREATE TABLE #codes (code VARCHAR(50) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
    CREATE TABLE #people (code VARCHAR(50) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, name NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL);

    DECLARE @my_role VARCHAR(20) = 'NONE', @alt_at DATETIME = NULL, @stage NVARCHAR(MAX), @primary VARCHAR(30), @esc_h INT;
    DECLARE @can_act BIT = 0, @can_forward BIT = 0, @can_back BIT = 0, @can_edit BIT = 0, @can_resubmit BIT = 0;

    IF @inst IS NOT NULL
    BEGIN
        INSERT INTO #stg (seq, stage_name, approver_ecno, alternates_json, escalation_hours, can_forward, can_backward, can_edit_data, condition_json)
        SELECT CAST(s.[key] AS INT), JSON_VALUE(s.value, '$.stage'), JSON_VALUE(s.value, '$.approver_ecno'), JSON_QUERY(s.value, '$.alternates'),
               ISNULL(TRY_CAST(JSON_VALUE(s.value, '$.escalation_hours') AS INT), 24),
               ISNULL(JSON_VALUE(s.value, '$.can_forward'), 'N'), ISNULL(JSON_VALUE(s.value, '$.can_backward'), 'N'),
               ISNULL(JSON_VALUE(s.value, '$.can_edit_data'), 'N'), JSON_QUERY(s.value, '$.condition')
        FROM OPENJSON(@stages) s;

        UPDATE o SET condition_met = dbo.fn_approval_condition_met(o.condition_json, @ctx)
        FROM #stg o;

        -- state of each stage in THIS cycle: the latest thing that happened to it, else where it sits in the path
        UPDATE o
        SET state = CASE
                        WHEN @istatus = 'P' AND o.seq = @cur THEN CASE WHEN @await = 1 THEN 'SENT_BACK' ELSE 'CURRENT' END
                        WHEN la.action = 'REJECT'   THEN 'REJECTED'
                        WHEN la.action = 'APPROVE'  THEN 'DONE'
                        WHEN la.action = 'FORWARD'  THEN 'FORWARDED'
                        WHEN la.action = 'SKIP'     THEN 'SKIPPED'
                        WHEN la.action = 'SEND_BACK' THEN 'SENT_BACK'
                        WHEN @istatus = 'P' AND o.seq > @cur THEN CASE WHEN o.condition_met = 1 THEN 'UPCOMING' ELSE 'NOT_REQUIRED' END
                        WHEN @istatus = 'P' AND o.seq < @cur THEN 'DONE'
                        ELSE 'NOT_REQUIRED'
                    END,
            acted_by = la.acted_by, acted_at = la.acted_at, comments = la.comments
        FROM #stg o
        OUTER APPLY (SELECT TOP 1 l.action, l.acted_by, l.acted_at, l.comments
                     FROM dbo.approval_action_log l
                     WHERE l.instance_id = @inst AND l.cycle_no = @cycle AND l.from_seq = o.seq
                       AND l.action IN ('APPROVE','FORWARD','REJECT','SKIP','SEND_BACK')
                     ORDER BY l.log_id DESC) la;

        INSERT INTO #codes (code)
        SELECT DISTINCT LTRIM(RTRIM(c)) FROM (
            SELECT @created_by AS c
            UNION SELECT approver_ecno FROM #stg
            UNION SELECT a.value COLLATE DATABASE_DEFAULT FROM #stg o CROSS APPLY OPENJSON(o.alternates_json) a
            UNION SELECT acted_by FROM #stg
            UNION SELECT acted_by FROM dbo.approval_action_log WHERE instance_id = @inst
            UNION SELECT target_ecno FROM dbo.approval_action_log WHERE instance_id = @inst
        ) x WHERE c IS NOT NULL AND LTRIM(RTRIM(c)) <> '';

        INSERT INTO #people (code, name)
        SELECT c.code, MAX(COALESCE(NULLIF(LTRIM(RTRIM(e.ename)), ''), ns.full_name))
        FROM #codes c
        LEFT JOIN dbo.vw_verified_employees e ON e.ecno = c.code
        LEFT JOIN dbo.nt_nonstaff_login ns ON ns.login_id = c.code
        GROUP BY c.code;

        UPDATE o SET approver_name = ISNULL(p.name, o.approver_ecno), acted_by_name = ISNULL(pa.name, o.acted_by),
                     alternate_names = (SELECT STRING_AGG(ISNULL(pp.name, a.value COLLATE DATABASE_DEFAULT), N', ') FROM OPENJSON(o.alternates_json) a LEFT JOIN #people pp ON pp.code = a.value COLLATE DATABASE_DEFAULT)
        FROM #stg o LEFT JOIN #people p ON p.code = o.approver_ecno LEFT JOIN #people pa ON pa.code = o.acted_by;

        -- what may the caller do right now
        IF @istatus = 'P'
        BEGIN
            SELECT @stage = (SELECT s.value FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@cur AS NVARCHAR(10)));
            SELECT @primary = JSON_VALUE(@stage, '$.approver_ecno'), @esc_h = ISNULL(TRY_CAST(JSON_VALUE(@stage, '$.escalation_hours') AS INT), 24);

            IF @await = 1
                SET @my_role = CASE WHEN @ecno = @created_by THEN 'REQUESTER' ELSE 'NONE' END;
            ELSE IF @ecno = @primary
                SET @my_role = 'PRIMARY';
            ELSE IF EXISTS (SELECT 1 FROM OPENJSON(@stage, '$.alternates') a WHERE a.value COLLATE DATABASE_DEFAULT = @ecno)
            BEGIN
                SET @alt_at = DATEADD(HOUR, @esc_h, @since);
                SET @my_role = CASE WHEN GETDATE() >= @alt_at THEN 'ALTERNATE' ELSE 'ALTERNATE_WAITING' END;
            END

            SET @can_act = CASE WHEN @my_role IN ('PRIMARY','ALTERNATE') THEN 1 ELSE 0 END;
            SET @can_forward = CASE WHEN @can_act = 1 AND EXISTS (SELECT 1 FROM #stg WHERE seq = @cur AND can_forward = 'Y')
                                         AND EXISTS (SELECT 1 FROM #stg WHERE seq > @cur) THEN 1 ELSE 0 END;
            SET @can_back = CASE WHEN @can_act = 1 AND EXISTS (SELECT 1 FROM #stg WHERE seq = @cur AND can_backward = 'Y') THEN 1 ELSE 0 END;
            SET @can_edit = CASE WHEN @mode = 'VENDOR_DRIVEN' THEN 0
                                 WHEN @my_role = 'REQUESTER' THEN 1
                                 WHEN @can_act = 1 AND EXISTS (SELECT 1 FROM #stg WHERE seq = @cur AND can_edit_data = 'Y') THEN 1
                                 ELSE 0 END;
            SET @can_resubmit = CASE WHEN @my_role = 'REQUESTER' THEN 1 ELSE 0 END;
        END
    END

    -- RS1
    SELECT @pr_sno AS pr_basic_sno, @base AS pr_no, @pr_status AS pr_status, CAST(CASE WHEN @inst IS NULL THEN 0 ELSE 1 END AS BIT) AS has_instance,
           @cycle AS cycle_no, @cur AS current_seq, @ret AS return_to_seq, @await AS awaiting_requester, @since AS current_since,
           @my_role AS my_role, @alt_at AS alternate_available_at,
           @can_act AS can_approve, @can_act AS can_reject, @can_forward AS can_forward, @can_back AS can_send_back,
           @can_edit AS can_edit, @can_resubmit AS can_resubmit,
           @mode AS request_mode, @entity_type AS entity_type, @created_by AS created_by, (SELECT name FROM #people WHERE code = @created_by) AS created_by_name,
           @amount AS amount, @priority AS priority_sno, @cats AS category_ids, @subcats AS subcategory_ids, @floor AS history_floor;

    -- RS2
    SELECT seq, stage_name, approver_ecno, approver_name, alternates_json, alternate_names, escalation_hours,
           can_forward, can_backward, can_edit_data, condition_json, condition_met, state,
           acted_by, acted_by_name, acted_at, comments
    FROM #stg ORDER BY seq;

    -- RS3: later stages — including ones the rules did not require
    SELECT seq, stage_name, approver_ecno, approver_name, condition_met AS required_by_rule
    FROM #stg WHERE @can_forward = 1 AND seq > @cur ORDER BY seq;

    -- RS4: the requester + every stage that already acted in this cycle
    SELECT CAST(NULL AS INT) AS seq, N'Requester (entry by)' AS stage_name, @created_by AS approver_ecno,
           (SELECT name FROM #people WHERE code = @created_by) AS approver_name, 'REQUESTER' AS target_type
    WHERE @can_back = 1
    UNION ALL
    SELECT o.seq, o.stage_name, o.approver_ecno, o.approver_name, 'STAGE'
    FROM #stg o
    WHERE @can_back = 1 AND o.seq < @cur
      AND EXISTS (SELECT 1 FROM dbo.approval_action_log l
                  WHERE l.instance_id = @inst AND l.cycle_no = @cycle AND l.from_seq = o.seq AND l.action IN ('APPROVE','FORWARD'))
    ORDER BY seq;

    -- RS5
    SELECT l.log_id, l.cycle_no, l.action, l.from_seq, l.to_seq, l.stage_name, l.acted_by, ISNULL(pa.name, l.acted_by) AS acted_by_name,
           l.acted_as, l.target_ecno, ISNULL(pt.name, l.target_ecno) AS target_name, l.comments, l.before_json, l.after_json, l.acted_at
    FROM dbo.approval_action_log l
    LEFT JOIN #people pa ON pa.code = l.acted_by
    LEFT JOIN #people pt ON pt.code = l.target_ecno
    WHERE l.instance_id = ISNULL(@inst, -1)
    ORDER BY l.log_id;

    -- RS6: the dictionary for the rules above (labels, kinds, where the choices come from)
    SELECT field_key, field_label, value_kind, option_source, unit, help_text, sort_order
    FROM dbo.approval_condition_field
    WHERE is_active = 'Y' AND entity_type = dbo.fn_approval_field_entity(@entity_type)
    ORDER BY sort_order, field_key;

    DROP TABLE #stg; DROP TABLE #codes; DROP TABLE #people;
END
GO
-- After running: EXEC dbo.sp_nt_GetApprovalRoutes;
-- Rollback: sql/backups/pre_approval_entity_routing_2026-10-07_ROLLBACK.sql
