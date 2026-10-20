-- ============================================================
-- 133_special_agreement.sql   (Non_trade_Dev)
--
-- SPECIAL AGREEMENT - product-based rate agreements, approved on-system instead of typed on A4 and
-- signed on paper.
--   FIXED   : supplier fixed AND rate per unit fixed for each product, for a period.
--   UNFIXED : supplier fixed for each product, the rate may change (no rate is stored).
-- One agreement = one supplier + a validity period + one or more products.
--
-- Own approval entity 'SpecialAgreement' (routable per Fixed / Unfixed on the Approval Routing
-- screen, like Service Agreement). Approval = approve / reject / forward / send back; stages are
-- read from the workflow on the server, only the current approver can act.
-- Not wired into PR / PO yet - sp_nt_GetSpecialAgreementRate is the lookup they can call later.
-- Re-runnable.
-- ============================================================

-- ── tables ──────────────────────────────────────────────────
IF OBJECT_ID('dbo.special_agreement', 'U') IS NULL
CREATE TABLE dbo.special_agreement (
    special_agreement_sno INT IDENTITY(1,1) PRIMARY KEY,
    agreement_no          VARCHAR(30)   NOT NULL,
    com_sno INT NOT NULL, div_sno INT NOT NULL, brn_sno INT NOT NULL, dept_sno INT NOT NULL,
    agreement_type        VARCHAR(10)   NOT NULL,            -- FIXED | UNFIXED
    vendor_sno            INT           NOT NULL,            -- kyc_basic_info_sno
    period_start_date     DATE          NOT NULL,
    period_end_date       DATE          NOT NULL,
    agreement_doc_url     NVARCHAR(500) NULL,
    remarks               NVARCHAR(500) NULL,
    terms_conditions      NVARCHAR(MAX) NULL,
    workflow_types_id     INT           NULL,
    current_approver_id   VARCHAR(30)   NULL,
    status                CHAR(1)       NOT NULL DEFAULT 'P', -- P pending, A approved, R rejected
    is_active             CHAR(1)       NOT NULL DEFAULT 'Y',
    version_no            INT           NOT NULL DEFAULT 1,
    created_by            VARCHAR(30)   NOT NULL,
    created_at            DATETIME      NOT NULL DEFAULT GETDATE(),
    modified_by           VARCHAR(30)   NULL,
    modified_at           DATETIME      NULL,
    CONSTRAINT CK_special_agreement_type CHECK (agreement_type IN ('FIXED', 'UNFIXED')),
    CONSTRAINT UQ_special_agreement_no UNIQUE (agreement_no)
);
GO
IF OBJECT_ID('dbo.special_agreement_item', 'U') IS NULL
CREATE TABLE dbo.special_agreement_item (
    item_sno              INT IDENTITY(1,1) PRIMARY KEY,
    special_agreement_sno INT           NOT NULL,
    prod_sno              INT           NOT NULL,
    rate_amount           DECIMAL(18,2) NULL,                -- per uom; required for FIXED, NULL for UNFIXED
    max_qty               DECIMAL(18,4) NULL,                -- optional cap on the quantity bought at this rate
    remarks               NVARCHAR(300) NULL,
    version_no            INT           NOT NULL DEFAULT 1,
    is_active             CHAR(1)       NOT NULL DEFAULT 'Y', -- 'N' = replaced by a later edit
    CONSTRAINT FK_special_agreement_item_hdr FOREIGN KEY (special_agreement_sno) REFERENCES dbo.special_agreement (special_agreement_sno)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_special_agreement_item_prod')
    CREATE INDEX IX_special_agreement_item_prod ON dbo.special_agreement_item (prod_sno, is_active) INCLUDE (special_agreement_sno);
GO
IF OBJECT_ID('dbo.special_agreement_history', 'U') IS NULL
CREATE TABLE dbo.special_agreement_history (
    history_sno           INT IDENTITY(1,1) PRIMARY KEY,
    special_agreement_sno INT           NOT NULL,
    action_type           VARCHAR(20)   NOT NULL,   -- SUBMITTED, RESUBMITTED, APPROVED, REJECTED, FORWARDED, SENT_BACK
    status_by             VARCHAR(30)   NULL,
    comment               NVARCHAR(500) NULL,
    version_no            INT           NULL,
    created_at            DATETIME      NOT NULL DEFAULT GETDATE()
);
GO

-- ── approval entity + routing ───────────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.entity_master WHERE entity_code = N'SpecialAgreement')
    INSERT INTO dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by, route_module_code)
    VALUES (N'Special Agreement', N'SpecialAgreement',
            N'Product rate agreements with a fixed supplier - Fixed (rate fixed) or Unfixed (rate may change)', 'Y', N'system', N'SpecialAgreement');
GO
IF NOT EXISTS (SELECT 1 FROM dbo.approval_route_module WHERE module_code = N'SpecialAgreement')
    INSERT INTO dbo.approval_route_module (module_code, module_label, variant_label, description, sort_order, variants_from_master)
    VALUES (N'SpecialAgreement', N'Special Agreement', N'Agreement type', N'Fixed-rate vs Unfixed-rate product agreements', 8, 0);
GO
MERGE dbo.approval_route_variant AS t
USING (VALUES (N'SpecialAgreement', N'FIXED', N'Fixed', 1), (N'SpecialAgreement', N'UNFIXED', N'Unfixed', 2))
      AS s(module_code, variant_code, variant_label, sort_order)
ON t.module_code = s.module_code AND t.variant_code = s.variant_code
WHEN NOT MATCHED THEN INSERT (module_code, variant_code, variant_label, sort_order)
     VALUES (s.module_code, s.variant_code, s.variant_label, s.sort_order);
GO
INSERT INTO dbo.approval_entity_route (module_code, variant_code, entity_code, modified_by)
SELECT s.m, s.v, N'SpecialAgreement', N'system'
FROM (VALUES (N'SpecialAgreement', N'FIXED'), (N'SpecialAgreement', N'UNFIXED')) s(m, v)
WHERE NOT EXISTS (SELECT 1 FROM dbo.approval_entity_route r WHERE r.module_code = s.m AND r.variant_code = s.v);
GO

-- ── screens ─────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'SpecialAgreementPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Special Agreements', 'S24', 'SpecialAgreementPage', 'FileCheck', 9, 25, 'Y');
IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'SpecialAgreementApprovalScreen')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Special Agreement Approvals', 'S24', 'SpecialAgreementApprovalScreen', 'FileCheck', 9, 26, 'Y');
GO

-- ── shared validation: products + overlap (called by create and update) ─────
CREATE OR ALTER PROCEDURE dbo.sp_nt_ValidateSpecialAgreementItems
    @items_json NVARCHAR(MAX), @agreement_type VARCHAR(10), @vendor_sno INT,
    @start DATE, @end DATE, @exclude_sno INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @items_json IS NULL OR ISJSON(@items_json) = 0 OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items_json))
        THROW 58301, 'Add at least one product to the agreement.', 1;

    DECLARE @i TABLE (prod_sno INT, rate DECIMAL(18,2), max_qty DECIMAL(18,4));
    INSERT INTO @i (prod_sno, rate, max_qty)
    SELECT TRY_CAST(JSON_VALUE(j.value, '$.prod_sno') AS INT),
           TRY_CAST(JSON_VALUE(j.value, '$.rate_amount') AS DECIMAL(18,2)),
           TRY_CAST(JSON_VALUE(j.value, '$.max_qty') AS DECIMAL(18,4))
    FROM OPENJSON(@items_json) j;

    IF EXISTS (SELECT 1 FROM @i WHERE prod_sno IS NULL)
        THROW 58302, 'Every line needs a product.', 1;
    IF EXISTS (SELECT prod_sno FROM @i GROUP BY prod_sno HAVING COUNT(*) > 1)
        THROW 58303, 'The same product is listed more than once.', 1;
    IF EXISTS (SELECT 1 FROM @i i WHERE NOT EXISTS (SELECT 1 FROM dbo.product_master p WHERE p.prod_sno = i.prod_sno AND p.prod_active = 'Y'))
        THROW 58304, 'One or more products are not active products.', 1;
    IF @agreement_type = 'FIXED' AND EXISTS (SELECT 1 FROM @i WHERE rate IS NULL OR rate <= 0)
        THROW 58305, 'A Fixed agreement needs a rate greater than zero for every product.', 1;
    IF EXISTS (SELECT 1 FROM @i WHERE max_qty IS NOT NULL AND max_qty <= 0)
        THROW 58306, 'Maximum quantity must be greater than zero when given.', 1;

    -- A product can only be under one live special agreement at a time (pending or approved, dates overlapping).
    IF EXISTS (
        SELECT 1
        FROM @i i
        JOIN dbo.special_agreement_item it ON it.prod_sno = i.prod_sno AND it.is_active = 'Y'
        JOIN dbo.special_agreement sa ON sa.special_agreement_sno = it.special_agreement_sno
        WHERE sa.is_active = 'Y' AND sa.status IN ('P', 'A')
          AND (@exclude_sno IS NULL OR sa.special_agreement_sno <> @exclude_sno)
          AND sa.period_start_date <= @end AND sa.period_end_date >= @start
    )
    BEGIN
        DECLARE @clash NVARCHAR(500) = (
            SELECT TOP 1 p.prod_name + N' is already under ' + sa.agreement_no + N' (' + CONVERT(NVARCHAR(10), sa.period_start_date, 105) + N' to ' + CONVERT(NVARCHAR(10), sa.period_end_date, 105) + N')'
            FROM @i i
            JOIN dbo.special_agreement_item it ON it.prod_sno = i.prod_sno AND it.is_active = 'Y'
            JOIN dbo.special_agreement sa ON sa.special_agreement_sno = it.special_agreement_sno
            JOIN dbo.product_master p ON p.prod_sno = i.prod_sno
            WHERE sa.is_active = 'Y' AND sa.status IN ('P', 'A')
              AND (@exclude_sno IS NULL OR sa.special_agreement_sno <> @exclude_sno)
              AND sa.period_start_date <= @end AND sa.period_end_date >= @start
        );
        THROW 58307, @clash, 1;
    END
END;
GO

-- ── create ──────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateSpecialAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @com_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT),
                @div_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT),
                @brn_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT),
                @dept_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT),
                @type VARCHAR(10) = UPPER(JSON_VALUE(@jsonInput, '$.agreement_type')),
                @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
                @start DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE),
                @end DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE),
                @doc NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.agreement_doc_url'))), ''),
                @remarks NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks'),
                @terms NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.terms_conditions'),
                @created_by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.created_by'),
                @items NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @vendor_sno IS NULL OR @created_by IS NULL
            THROW 58310, 'com_sno, div_sno, brn_sno, dept_sno, vendor_sno and created_by are required.', 1;
        IF @type IS NULL OR @type NOT IN ('FIXED', 'UNFIXED')
            THROW 58311, 'agreement_type must be FIXED or UNFIXED.', 1;
        IF @start IS NULL OR @end IS NULL OR @end < @start
            THROW 58312, 'A valid period is required, and it cannot end before it starts.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = @vendor_sno AND status = 'A' AND is_active = 'Y')
            THROW 58313, 'The supplier must be an approved (KYC) supplier.', 1;

        EXEC dbo.sp_nt_ValidateSpecialAgreementItems @items_json = @items, @agreement_type = @type, @vendor_sno = @vendor_sno,
             @start = @start, @end = @end, @exclude_sno = NULL;

        DECLARE @wf INT, @first_approver VARCHAR(30);
        SELECT @wf = wt.workflow_types_id
        FROM dbo.workflow_types wt
        JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = dbo.fn_resolve_approval_entity('SpecialAgreement', @type)
          AND wt.is_active = 'Y' AND awm.is_active = 'Y'
          AND EXISTS (SELECT 1 FROM dbo.workflow_stage s WHERE s.workflow_types_id = wt.workflow_types_id AND s.is_active = 'Y');
        IF @wf IS NULL
            THROW 58314, 'No Special Agreement workflow is configured for this company/division/branch/department - ask an admin to set one up under Approval Workflows.', 1;

        SELECT TOP 1 @first_approver = JSON_VALUE(s.stage_order_json, '$[0].approver_ecno')
        FROM dbo.workflow_stage s WHERE s.workflow_types_id = @wf AND s.is_active = 'Y';
        IF @first_approver IS NULL
            THROW 58315, 'The Special Agreement workflow has no approver on its first stage.', 1;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(agreement_no, 4) AS INT)), 0) + 1
        FROM dbo.special_agreement WITH (UPDLOCK, HOLDLOCK) WHERE agreement_no LIKE 'SPA-' + @year + '-%';
        DECLARE @no VARCHAR(30) = 'SPA-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.special_agreement (agreement_no, com_sno, div_sno, brn_sno, dept_sno, agreement_type, vendor_sno,
               period_start_date, period_end_date, agreement_doc_url, remarks, terms_conditions,
               workflow_types_id, current_approver_id, status, created_by)
        VALUES (@no, @com_sno, @div_sno, @brn_sno, @dept_sno, @type, @vendor_sno, @start, @end, @doc, @remarks, @terms,
               @wf, @first_approver, 'P', @created_by);
        DECLARE @sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.special_agreement_item (special_agreement_sno, prod_sno, rate_amount, max_qty, remarks, version_no)
        SELECT @sno, TRY_CAST(JSON_VALUE(j.value, '$.prod_sno') AS INT),
               CASE WHEN @type = 'FIXED' THEN TRY_CAST(JSON_VALUE(j.value, '$.rate_amount') AS DECIMAL(18,2)) END,
               TRY_CAST(JSON_VALUE(j.value, '$.max_qty') AS DECIMAL(18,4)), JSON_VALUE(j.value, '$.remarks'), 1
        FROM OPENJSON(@items) j;

        INSERT INTO dbo.special_agreement_history (special_agreement_sno, action_type, status_by, version_no)
        VALUES (@sno, 'SUBMITTED', @created_by, 1);

        COMMIT TRANSACTION;
        SELECT @sno AS special_agreement_sno, @no AS agreement_no, 'SUCCESS' AS result, @first_approver AS next_approver;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── update / resubmit (rejected, approved or expired agreements go back through approval) ──
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateSpecialAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.special_agreement_sno') AS INT),
                @com_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT),
                @div_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT),
                @brn_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT),
                @dept_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT),
                @type VARCHAR(10) = UPPER(JSON_VALUE(@jsonInput, '$.agreement_type')),
                @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
                @start DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE),
                @end DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE),
                @doc NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.agreement_doc_url'))), ''),
                @remarks NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks'),
                @terms NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.terms_conditions'),
                @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.modified_by'),
                @items NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');

        IF @sno IS NULL OR @by IS NULL OR @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @vendor_sno IS NULL
            THROW 58320, 'special_agreement_sno, the organisation, vendor_sno and modified_by are required.', 1;
        IF @type IS NULL OR @type NOT IN ('FIXED', 'UNFIXED')
            THROW 58311, 'agreement_type must be FIXED or UNFIXED.', 1;
        IF @start IS NULL OR @end IS NULL OR @end < @start
            THROW 58312, 'A valid period is required, and it cannot end before it starts.', 1;

        DECLARE @cur_status CHAR(1), @owner VARCHAR(30), @cur_ver INT;
        SELECT @cur_status = status, @owner = created_by, @cur_ver = version_no
        FROM dbo.special_agreement WITH (UPDLOCK) WHERE special_agreement_sno = @sno AND is_active = 'Y';
        IF @cur_status IS NULL THROW 58321, 'Special agreement not found.', 1;
        IF @cur_status = 'P' THROW 58322, 'This agreement is still awaiting approval - it can be edited once it is decided.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = @vendor_sno AND status = 'A' AND is_active = 'Y')
            THROW 58313, 'The supplier must be an approved (KYC) supplier.', 1;

        EXEC dbo.sp_nt_ValidateSpecialAgreementItems @items_json = @items, @agreement_type = @type, @vendor_sno = @vendor_sno,
             @start = @start, @end = @end, @exclude_sno = @sno;

        DECLARE @wf INT, @first_approver VARCHAR(30);
        SELECT @wf = wt.workflow_types_id
        FROM dbo.workflow_types wt
        JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = dbo.fn_resolve_approval_entity('SpecialAgreement', @type)
          AND wt.is_active = 'Y' AND awm.is_active = 'Y'
          AND EXISTS (SELECT 1 FROM dbo.workflow_stage s WHERE s.workflow_types_id = wt.workflow_types_id AND s.is_active = 'Y');
        IF @wf IS NULL
            THROW 58314, 'No Special Agreement workflow is configured for this company/division/branch/department - ask an admin to set one up under Approval Workflows.', 1;
        SELECT TOP 1 @first_approver = JSON_VALUE(s.stage_order_json, '$[0].approver_ecno')
        FROM dbo.workflow_stage s WHERE s.workflow_types_id = @wf AND s.is_active = 'Y';
        IF @first_approver IS NULL THROW 58315, 'The Special Agreement workflow has no approver on its first stage.', 1;

        DECLARE @new_ver INT = @cur_ver + 1;

        UPDATE dbo.special_agreement
        SET com_sno = @com_sno, div_sno = @div_sno, brn_sno = @brn_sno, dept_sno = @dept_sno,
            agreement_type = @type, vendor_sno = @vendor_sno, period_start_date = @start, period_end_date = @end,
            agreement_doc_url = ISNULL(@doc, agreement_doc_url), remarks = @remarks, terms_conditions = @terms,
            workflow_types_id = @wf, current_approver_id = @first_approver, status = 'P',
            version_no = @new_ver, modified_by = @by, modified_at = GETDATE()
        WHERE special_agreement_sno = @sno;

        -- previous lines are kept (is_active = 'N') so what an earlier version said is never lost
        UPDATE dbo.special_agreement_item SET is_active = 'N' WHERE special_agreement_sno = @sno AND is_active = 'Y';
        INSERT INTO dbo.special_agreement_item (special_agreement_sno, prod_sno, rate_amount, max_qty, remarks, version_no)
        SELECT @sno, TRY_CAST(JSON_VALUE(j.value, '$.prod_sno') AS INT),
               CASE WHEN @type = 'FIXED' THEN TRY_CAST(JSON_VALUE(j.value, '$.rate_amount') AS DECIMAL(18,2)) END,
               TRY_CAST(JSON_VALUE(j.value, '$.max_qty') AS DECIMAL(18,4)), JSON_VALUE(j.value, '$.remarks'), @new_ver
        FROM OPENJSON(@items) j;

        INSERT INTO dbo.special_agreement_history (special_agreement_sno, action_type, status_by, comment, version_no)
        VALUES (@sno, 'RESUBMITTED', @by, N'Resubmitted after ' + CASE @cur_status WHEN 'R' THEN N'rejection' WHEN 'A' THEN N'approval (changed)' ELSE N'expiry' END, @new_ver);

        COMMIT TRANSACTION;
        SELECT @sno AS special_agreement_sno, 'SUCCESS' AS result, @first_approver AS next_approver;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── approve / reject / forward / send back ──────────────────
CREATE OR ALTER PROCEDURE dbo.sp_approve_special_agreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.special_agreement_sno') AS INT),
                @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action VARCHAR(20) = LOWER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.action')))),
                @comments NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.comments'))), ''),
                @send_back_to VARCHAR(30) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.send_back_to'))), '');

        IF @sno IS NULL OR @by IS NULL THROW 58330, 'special_agreement_sno and approved_by are required.', 1;
        IF @action IS NULL OR @action NOT IN ('approve', 'reject', 'forward', 'send_back')
            THROW 58331, 'Invalid action. Must be approve, reject, forward or send_back.', 1;

        DECLARE @wf INT, @ver INT;
        SELECT @wf = workflow_types_id, @ver = version_no FROM dbo.special_agreement WITH (UPDLOCK)
        WHERE special_agreement_sno = @sno AND is_active = 'Y' AND status = 'P' AND current_approver_id = @by;
        IF @ver IS NULL THROW 58332, 'This agreement is not waiting for your approval.', 1;

        -- stages come from the workflow itself, never from the client
        DECLARE @st TABLE (seq_no INT, approver_ecno VARCHAR(30), can_forward CHAR(1), can_backward CHAR(1));
        INSERT INTO @st (seq_no, approver_ecno, can_forward, can_backward)
        SELECT CAST(j.[key] AS INT), JSON_VALUE(j.value, '$.approver_ecno'), JSON_VALUE(j.value, '$.can_forward'), JSON_VALUE(j.value, '$.can_backward')
        FROM dbo.workflow_stage ws CROSS APPLY OPENJSON(ws.stage_order_json) j
        WHERE ws.workflow_types_id = @wf AND ws.is_active = 'Y';

        DECLARE @cur_seq INT = (SELECT MIN(seq_no) FROM @st WHERE approver_ecno = @by);
        IF @cur_seq IS NULL THROW 58333, 'You are not an approver in this agreement''s workflow.', 1;

        IF @action IN ('forward', 'send_back')
        BEGIN
            DECLARE @target VARCHAR(30);
            IF @action = 'forward'
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM @st WHERE seq_no = @cur_seq AND can_forward = 'Y') THROW 58334, 'Forwarding is not enabled for your approval stage.', 1;
                SELECT TOP 1 @target = approver_ecno FROM @st WHERE seq_no > @cur_seq ORDER BY seq_no;
                IF @target IS NULL THROW 58335, 'There is no later approver to forward this to.', 1;
            END
            ELSE
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM @st WHERE seq_no = @cur_seq AND can_backward = 'Y') THROW 58336, 'Sending back is not enabled for your approval stage.', 1;
                IF @send_back_to IS NULL OR NOT EXISTS (SELECT 1 FROM @st WHERE approver_ecno = @send_back_to AND seq_no < @cur_seq)
                    THROW 58337, 'Choose an earlier approver in the workflow to send this back to.', 1;
                IF @comments IS NULL THROW 58338, 'A reason is required when sending back.', 1;
                SET @target = @send_back_to;
            END
            INSERT INTO dbo.special_agreement_history (special_agreement_sno, action_type, status_by, comment, version_no)
            VALUES (@sno, CASE WHEN @action = 'forward' THEN 'FORWARDED' ELSE 'SENT_BACK' END, @by,
                    CASE WHEN @action = 'forward' THEN N'Forwarded to ' ELSE N'Sent back to ' END + @target + ISNULL(N': ' + @comments, N''), @ver);
            UPDATE dbo.special_agreement SET current_approver_id = @target WHERE special_agreement_sno = @sno;
            -- the new holder must be told even if they were notified earlier in its life
            UPDATE dbo.approval_notice_log SET status = 'FAILED', error_message = N'Re-notify after ' + @action, modified_at = GETDATE()
            WHERE entity_type = 'SpecialAgreement' AND entity_id = @sno AND approver_ecno = @target AND status = 'SENT';
            COMMIT TRANSACTION;
            SELECT CASE WHEN @action = 'forward' THEN 'FORWARDED' ELSE 'SENT_BACK' END AS result, @sno AS special_agreement_sno, @target AS next_approver;
            RETURN;
        END

        IF @action = 'reject'
        BEGIN
            IF @comments IS NULL THROW 58339, 'A reason is required when rejecting.', 1;
            INSERT INTO dbo.special_agreement_history (special_agreement_sno, action_type, status_by, comment, version_no)
            VALUES (@sno, 'REJECTED', @by, @comments, @ver);
            UPDATE dbo.special_agreement SET status = 'R', current_approver_id = NULL WHERE special_agreement_sno = @sno;
            COMMIT TRANSACTION;
            SELECT 'REJECTED' AS result, @sno AS special_agreement_sno, NULL AS next_approver;
            RETURN;
        END

        DECLARE @next VARCHAR(30);
        SELECT TOP 1 @next = approver_ecno FROM @st WHERE seq_no > @cur_seq ORDER BY seq_no;
        INSERT INTO dbo.special_agreement_history (special_agreement_sno, action_type, status_by, comment, version_no)
        VALUES (@sno, 'APPROVED', @by, @comments, @ver);
        UPDATE dbo.special_agreement
        SET current_approver_id = @next, status = CASE WHEN @next IS NULL THEN 'A' ELSE 'P' END
        WHERE special_agreement_sno = @sno;
        COMMIT TRANSACTION;
        SELECT 'SUCCESS' AS result, @sno AS special_agreement_sno, ISNULL(@next, 'FINAL_STAGE') AS next_approver;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ── reads ───────────────────────────────────────────────────
-- Shared shape for the list and the approver inbox. status_effective turns an approved agreement past its
-- end date into 'X' (expired) with no background job.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetSpecialAgreements
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @approver VARCHAR(30) = JSON_VALUE(@jsonInput, '$.approver_ecno');
    SELECT sa.special_agreement_sno, sa.agreement_no, sa.agreement_type,
           sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
           d.com_name, d.div_name, d.brn_name, d.dept_name,
           sa.vendor_sno, k.company_name AS vendor_name, k.supp_code,
           sa.period_start_date, sa.period_end_date, sa.agreement_doc_url, sa.remarks, sa.terms_conditions,
           sa.status AS status_raw,
           CASE WHEN sa.status = 'A' AND sa.period_end_date < CAST(GETDATE() AS DATE) THEN 'X' ELSE sa.status END AS status,
           sa.version_no, sa.current_approver_id, sa.created_by, sa.created_at, sa.modified_at,
           (
               SELECT it.item_sno, it.prod_sno, p.prod_name, p.prod_code, p.uom_sno, um.uom_name,
                      it.rate_amount, it.max_qty, it.remarks
               FROM dbo.special_agreement_item it
               JOIN dbo.product_master p ON p.prod_sno = it.prod_sno
               LEFT JOIN dbo.uom_master um ON um.uom_sno = p.uom_sno
               WHERE it.special_agreement_sno = sa.special_agreement_sno AND it.is_active = 'Y'
               ORDER BY it.item_sno
               FOR JSON PATH
           ) AS items_json,
           (
               SELECT h.action_type, h.status_by, h.comment, h.version_no, h.created_at
               FROM dbo.special_agreement_history h
               WHERE h.special_agreement_sno = sa.special_agreement_sno
               ORDER BY h.history_sno DESC
               FOR JSON PATH
           ) AS history_json,
           (SELECT ws.stage_order_json FROM dbo.workflow_stage ws
            WHERE ws.workflow_types_id = sa.workflow_types_id AND ws.is_active = 'Y') AS stage_order_json
    FROM dbo.special_agreement sa
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    OUTER APPLY (SELECT TOP 1 v.com_name, v.div_name, v.brn_name, v.dept_name FROM dbo.vw_ActiveDeptRecords v
                 WHERE v.dept_sno = sa.dept_sno AND v.brn_sno = sa.brn_sno AND v.div_sno = sa.div_sno AND v.com_sno = sa.com_sno) d
    WHERE sa.is_active = 'Y'
      AND (@approver IS NULL OR (sa.status = 'P' AND sa.current_approver_id = @approver))
    ORDER BY sa.special_agreement_sno DESC;
END;
GO

-- For PR / PO to call later: the live approved agreement covering a product on a date.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetSpecialAgreementRate
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @prod INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.prod_sno') AS INT),
            @on DATE = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.on_date') AS DATE), CAST(GETDATE() AS DATE));
    SELECT TOP 1 sa.special_agreement_sno, sa.agreement_no, sa.agreement_type, sa.vendor_sno, k.company_name AS vendor_name,
           it.rate_amount, it.max_qty, sa.period_start_date, sa.period_end_date
    FROM dbo.special_agreement_item it
    JOIN dbo.special_agreement sa ON sa.special_agreement_sno = it.special_agreement_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    WHERE it.prod_sno = @prod AND it.is_active = 'Y' AND sa.is_active = 'Y' AND sa.status = 'A'
      AND @on BETWEEN sa.period_start_date AND sa.period_end_date
    ORDER BY sa.special_agreement_sno DESC;
END;
GO

-- ── approval bell: pending special agreements notify their current approver ──
-- (same proc as before, plus one more source row set)
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.sp_nt_ClaimApprovalNotices'));
IF @def NOT LIKE N'%SpecialAgreementApprovalScreen%'
BEGIN
    DECLARE @marker NVARCHAR(200) = N'CREATE TABLE #claimed (notice_sno INT PRIMARY KEY);';
    IF CHARINDEX(@marker, @def) = 0 THROW 58399, 'sp_nt_ClaimApprovalNotices has changed shape - patch the Special Agreement source by hand.', 1;
    SET @def = STUFF(@def, CHARINDEX(@marker, @def), 0,
        N'INSERT INTO #pending
    SELECT ''SpecialAgreement'', special_agreement_sno, current_approver_id, N''Special Agreement '' + agreement_no, ''SpecialAgreementApprovalScreen''
    FROM dbo.special_agreement WHERE status = ''P'' AND is_active = ''Y'' AND current_approver_id IS NOT NULL;

    ');
    -- the stored text may start with comments and says CREATE: rebuild it as ALTER from the proc name on
    DECLARE @pos INT = CHARINDEX(N'dbo.sp_nt_ClaimApprovalNotices', @def);
    IF @pos = 0 THROW 58398, 'Could not locate the proc name in sp_nt_ClaimApprovalNotices.', 1;
    SET @def = N'ALTER PROCEDURE ' + SUBSTRING(@def, @pos, LEN(@def));
    EXEC sys.sp_executesql @def;
END
GO
