-- ============================================================
-- Variable-Recurring service authorization: extend service_agreement,
-- gate sp_nt_CreateServicePO on it, add a ceiling/tolerance revision proc
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/ServiceAgreement, backend-stpl/src/ServicePO
--
-- Why this is needed
-- ------------------
-- Only FIXED_RECURRING services (Rent, AMC) have an upstream authorization
-- record today (service_agreement, sql/10_service_agreement.sql) — a
-- VARIABLE_RECURRING service PO (AWS, electricity) has its ceiling_amount/
-- variance_tolerance_pct set once, directly, at PO-creation time
-- (sp_nt_CreateServicePO, sql/11_service_po_direct_issue.sql), with no
-- separate "who authorized this ceiling" record and no way to revise it
-- later without editing the live PO row by hand.
--
-- Change 1 — extend service_agreement rather than add a parallel table.
-- Confirmed low-risk: the only FIXED_RECURRING-only gate in
-- sp_nt_CreateServiceAgreement is a single service_type_code check (error
-- 53006), and rate_amount is only NOT NULL at the column level (not
-- separately re-validated elsewhere), so both are cleanly relaxable without
-- touching the Fixed-Recurring code path. ceiling_amount/variance_tolerance_pct
-- mirror the columns already on po_request_info; rate_amount becomes
-- nullable since a Variable-Recurring agreement authorizes a ceiling, not a
-- fixed rate.
--
-- Change 2 — sp_nt_CreateServicePO gains a pre-check for VARIABLE_RECURRING
-- mirroring the FIXED_RECURRING gate already in usp_InsertPurchaseRequest v3
-- (sql/12_pr_agreement_autofill.sql): before creating a NEW PO (not an
-- append to an existing one, and not a call-off — those go through
-- sp_nt_CreateCallOffPO instead), require an Approved, in-period
-- service_agreement covering this org scope + at least one of the PO's item
-- service_sno values, and source ceiling_amount/variance_tolerance_pct from
-- that agreement rather than trusting the client payload — same
-- "server is the authority" pattern. Also closes a pre-existing gap where
-- requires_variance_tolerance (service_type_master) was never actually
-- checked, unlike requires_ceiling_amount which already was.
--
-- Change 3 — sp_nt_ReviseServicePOCeiling: a direct, audit-logged update of
-- an already-Approved Variable-Recurring PO's ceiling/tolerance, for the
-- "periodic ceiling/tolerance review" requirement. Deliberately NOT a new
-- approval workflow — this is administrative revision of an existing
-- authorization's terms, not a new procurement decision. Logs to
-- po_history_data with action_type='CEILING_REVISED', the same table
-- sp_nt_ApproveServicePO already writes APPROVED/REJECTED rows to.
-- ============================================================

-- ── Change 1: service_agreement extension ──────────────────────────────────

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_agreement') AND name = 'ceiling_amount')
    ALTER TABLE dbo.service_agreement ADD ceiling_amount DECIMAL(18,2) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_agreement') AND name = 'variance_tolerance_pct')
    ALTER TABLE dbo.service_agreement ADD variance_tolerance_pct DECIMAL(5,2) NULL;
GO

-- rate_amount: widen NOT NULL -> NULL. Existing rows are all FIXED_RECURRING
-- with a real rate_amount already, so this is a pure widening, no data loss.
IF EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.service_agreement') AND name = 'rate_amount' AND is_nullable = 0
)
    ALTER TABLE dbo.service_agreement ALTER COLUMN rate_amount DECIMAL(18,2) NULL;
GO

-- ── sp_nt_CreateServiceAgreement v2 — branch by service_type_code ──────────

IF OBJECT_ID('dbo.sp_nt_CreateServiceAgreement', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateServiceAgreement;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @com_sno              INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno              INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno              INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno             INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @service_sno          INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @vendor_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @rate_amount          DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @rate_uom_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_uom_sno') AS INT);
        DECLARE @ceiling_amount       DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @variance_tolerance_pct DECIMAL(5,2)= TRY_CAST(JSON_VALUE(@jsonInput, '$.variance_tolerance_pct') AS DECIMAL(5,2));
        DECLARE @recurrence_cadence   VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.recurrence_cadence');
        DECLARE @period_start_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date      DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url    NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks              NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @created_by           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @service_sno IS NULL OR @created_by IS NULL
            THROW 53001, 'com_sno, div_sno, brn_sno, dept_sno, service_sno and created_by are required.', 1;

        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 53003, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;

        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 53004, 'agreement_doc_url is required — upload the agreement document before submitting.', 1;

        DECLARE @service_type_code VARCHAR(30), @is_recurring BIT, @default_cadence VARCHAR(20);
        SELECT @service_type_code = st.service_type_code,
               @is_recurring      = sm.is_recurring,
               @default_cadence   = sm.recurrence_cadence
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';

        IF @service_type_code IS NULL
            THROW 53005, 'Unknown or inactive service_sno.', 1;

        IF ISNULL(@is_recurring, 0) = 0 OR @service_type_code NOT IN ('FIXED_RECURRING', 'VARIABLE_RECURRING')
            THROW 53006, 'service_sno must reference an active Fixed Recurring or Variable Recurring, recurring service.', 1;

        -- Branch by billing pattern: Fixed Recurring authorizes a rate,
        -- Variable Recurring authorizes a ceiling + tolerance. Same "which
        -- fields this service type requires" check sp_nt_CreateServicePO
        -- already applies via service_type_master's requires_ceiling_amount/
        -- requires_variance_tolerance flags.
        IF @service_type_code = 'FIXED_RECURRING'
        BEGIN
            IF @rate_amount IS NULL OR @rate_amount <= 0
                THROW 53002, 'rate_amount must be a positive amount.', 1;
        END
        ELSE -- VARIABLE_RECURRING
        BEGIN
            IF @ceiling_amount IS NULL OR @ceiling_amount <= 0
                THROW 53010, 'ceiling_amount must be a positive amount for a Variable Recurring agreement.', 1;
            IF @variance_tolerance_pct IS NULL
                THROW 53011, 'variance_tolerance_pct is required for a Variable Recurring agreement.', 1;
        END

        IF @recurrence_cadence IS NULL
            SET @recurrence_cadence = @default_cadence;

        -- ── Resolve the ServiceAgreement workflow for this org scope ───────
        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);

        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceAgreement';

        IF @workflow_types_id IS NULL
            THROW 53007, 'No ServiceAgreement workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key] = '0' AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 53008, 'No approver found for the first stage of the ServiceAgreement workflow.', 1;

        -- ── Number: AGR-YYYY-NNNN, same scheme as ServicePO's SVO-YYYY-NNNN ─
        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(agreement_no, 4) AS INT)), 0) + 1
        FROM dbo.service_agreement WITH (UPDLOCK, HOLDLOCK)
        WHERE agreement_no LIKE 'AGR-' + @year + '-%';
        DECLARE @agreement_no VARCHAR(30) = 'AGR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.service_agreement (
            agreement_no, com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
            rate_amount, rate_uom_sno, ceiling_amount, variance_tolerance_pct,
            recurrence_cadence, period_start_date, period_end_date,
            agreement_doc_url, remarks, workflow_types_id, current_approver_id, status,
            is_active, created_by
        )
        VALUES (
            @agreement_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @service_sno, @vendor_sno,
            @rate_amount, @rate_uom_sno, @ceiling_amount, @variance_tolerance_pct,
            @recurrence_cadence, @period_start_date, @period_end_date,
            @agreement_doc_url, @remarks, @workflow_types_id, @first_approver, 'P',
            'Y', @created_by
        );

        DECLARE @agreement_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, is_active)
        VALUES (@agreement_sno, 'SUBMITTED', @created_by, NULL, 'Y');

        COMMIT TRANSACTION;

        SELECT
            @agreement_sno AS agreement_sno,
            @agreement_no  AS agreement_no,
            'SUCCESS'      AS result,
            N'Service agreement submitted for approval.' AS message;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── Change 2: sp_nt_CreateServicePO v3 — VARIABLE_RECURRING authorization gate ──

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

        DECLARE @service_type_sno INT, @requires_ceiling BIT, @requires_tolerance BIT;
        SELECT @service_type_sno = service_type_sno, @requires_ceiling = requires_ceiling_amount,
               @requires_tolerance = requires_variance_tolerance
        FROM dbo.service_type_master
        WHERE service_type_code = @service_type_code AND is_active = 'Y';

        IF @service_type_sno IS NULL
            THROW 52004, 'Unknown or inactive service_type_code.', 1;

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

            -- VARIABLE_RECURRING authorization gate — only for a genuinely
            -- new, non-retrospective PO (a call-off against an already
            -- authorized STANDING PO goes through sp_nt_CreateCallOffPO
            -- instead, and never reaches this branch). Requires an Approved,
            -- in-period service_agreement covering this org scope and at
            -- least one of the PO's item service_sno values; sources
            -- ceiling/tolerance from it rather than the client payload —
            -- same "server is the authority" pattern usp_InsertPurchaseRequest
            -- v3 already uses for FIXED_RECURRING rate.
            IF @service_type_code = 'VARIABLE_RECURRING' AND @is_retrospective = 0
            BEGIN
                DECLARE @authorizing_agreement_sno INT;
                SELECT TOP 1 @authorizing_agreement_sno = sa.agreement_sno,
                       @ceiling_amount = sa.ceiling_amount,
                       @variance_tolerance_pct = sa.variance_tolerance_pct
                FROM OPENJSON(@items) j
                CROSS APPLY (SELECT TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT) AS item_service_sno) parsed
                JOIN dbo.service_agreement sa
                    ON sa.service_sno = parsed.item_service_sno
                   AND sa.com_sno = @com_sno AND sa.div_sno = @div_sno
                   AND sa.brn_sno = @brn_sno AND sa.dept_sno = @dept_sno
                   AND sa.status  = 'A'
                   AND CAST(GETDATE() AS DATE) BETWEEN sa.period_start_date AND sa.period_end_date
                ORDER BY sa.agreement_sno DESC;

                IF @authorizing_agreement_sno IS NULL
                    THROW 52009, 'No approved, in-period Variable Recurring Service Agreement found authorizing this org scope + service. Create and approve one before raising this Service PO.', 1;
            END

            IF @requires_ceiling = 1 AND @ceiling_amount IS NULL
                THROW 52005, 'ceiling_amount is required for this service type.', 1;

            IF @requires_tolerance = 1 AND @variance_tolerance_pct IS NULL
                THROW 52010, 'variance_tolerance_pct is required for this service type.', 1;

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

-- ── Change 3: sp_nt_ReviseServicePOCeiling ─────────────────────────────────
-- @jsonInput: { po_basic_sno, ceiling_amount, variance_tolerance_pct, revised_by, comments? }
-- Direct audit-logged update — not a new approval workflow (see file header).
-- Only permitted on an Approved (status='A') Variable Recurring PO.

IF OBJECT_ID('dbo.sp_nt_ReviseServicePOCeiling', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_ReviseServicePOCeiling;
GO
CREATE PROCEDURE dbo.sp_nt_ReviseServicePOCeiling
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @po_basic_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT);
        DECLARE @new_ceiling_amount     DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @new_variance_tolerance DECIMAL(5,2)  = TRY_CAST(JSON_VALUE(@jsonInput, '$.variance_tolerance_pct') AS DECIMAL(5,2));
        DECLARE @revised_by             VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.revised_by');
        DECLARE @comments               VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments');

        IF @po_basic_sno IS NULL OR @revised_by IS NULL
            THROW 52020, 'po_basic_sno and revised_by are required.', 1;

        IF @new_ceiling_amount IS NULL AND @new_variance_tolerance IS NULL
            THROW 52021, 'At least one of ceiling_amount or variance_tolerance_pct must be supplied.', 1;

        DECLARE @old_ceiling DECIMAL(18,2), @old_tolerance DECIMAL(5,2), @status CHAR(1), @service_type_code VARCHAR(30);
        SELECT @old_ceiling = po.ceiling_amount, @old_tolerance = po.variance_tolerance_pct, @status = po.status,
               @service_type_code = st.service_type_code
        FROM dbo.po_request_info po
        JOIN dbo.service_type_master st ON st.service_type_sno = po.service_type_sno
        WHERE po.po_basic_sno = @po_basic_sno AND po.is_active = 'Y';

        IF @status IS NULL
            THROW 52022, 'Service PO not found or inactive.', 1;

        IF @status <> 'A'
            THROW 52023, 'Only an Approved Service PO can have its ceiling/tolerance revised.', 1;

        IF @service_type_code <> 'VARIABLE_RECURRING'
            THROW 52024, 'Ceiling/tolerance revision only applies to Variable Recurring Service POs.', 1;

        UPDATE dbo.po_request_info
        SET ceiling_amount         = ISNULL(@new_ceiling_amount, ceiling_amount),
            variance_tolerance_pct = ISNULL(@new_variance_tolerance, variance_tolerance_pct)
        WHERE po_basic_sno = @po_basic_sno;

        -- Column list matches sp_nt_ApproveServicePO's own proven INSERT
        -- shape into this table (07_po_service_extensions.sql) — status/
        -- status_date are left to their column defaults, not supplied here.
        INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
        VALUES (
            @po_basic_sno, 'CEILING_REVISED', @revised_by,
            CONCAT(
                'Ceiling ', FORMAT(ISNULL(@old_ceiling, 0), 'N2'), ' -> ', FORMAT(ISNULL(@new_ceiling_amount, @old_ceiling), 'N2'),
                '; Tolerance% ', FORMAT(ISNULL(@old_tolerance, 0), 'N2'), ' -> ', FORMAT(ISNULL(@new_variance_tolerance, @old_tolerance), 'N2'),
                ISNULL(N'; ' + @comments, N'')
            ),
            'Y'
        );

        COMMIT TRANSACTION;

        SELECT
            @po_basic_sno AS po_basic_sno,
            ISNULL(@new_ceiling_amount, @old_ceiling)         AS ceiling_amount,
            ISNULL(@new_variance_tolerance, @old_tolerance)   AS variance_tolerance_pct,
            'SUCCESS' AS result;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_agreement') AND name IN ('ceiling_amount','variance_tolerance_pct');
--   SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.sp_nt_CreateServicePO')) LIKE '%52009%'; -- should be 1
--
-- Manual smoke test — a VARIABLE_RECURRING Service PO with NO approved
-- agreement for that org+service should now THROW 52009 instead of
-- accepting whatever ceiling_amount the client sends:
--   EXEC dbo.sp_nt_CreateServicePO @jsonInput = N'{"vendor_sno":1,"com_sno":1,
--     "div_sno":1,"brn_sno":1,"dept_sno":1,"service_type_code":"VARIABLE_RECURRING",
--     "pr_basic_sno":1,"created_by":"system","ceiling_amount":50000,
--     "variance_tolerance_pct":10,"items":[{"service_sno":<a VARIABLE_RECURRING service_sno>,"qty":1}]}';
--   -- expect: THROW 52009 (no agreement) until one is created via
--   -- sp_nt_CreateServiceAgreement + sp_approve_service_agreement first.
--
-- po_history_data note: this proc assumes a status_date column matching
-- sp_nt_ApproveServicePO's own INSERT shape into the same table — verify
-- with SELECT TOP 1 * FROM po_history_data if this proc's INSERT fails on
-- an unexpected column.
-- ============================================================
