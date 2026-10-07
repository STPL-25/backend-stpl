-- ============================================================
-- Conditional approval engine — Purchase Requisition (phase 1)
-- Database : Non_trade_Dev (re-runnable)
--
-- Request (2026-09-26): approval workflows must route on conditions, e.g. for a
-- PR:  a small PR needs Admin only; a bigger one needs Admin -> GM; a bigger one
-- Admin -> GM -> ED. An approver who is not required to escalate can still
-- FORWARD to a higher stage (GM or ED), can SEND BACK to anyone who acted before
-- (or to the requester who made the entry), and can EDIT values. Every stage can
-- optionally list ALTERNATE approvers.
--
-- Decisions taken with the requester (2026-09-26):
--   * Condition fields for a PR: amount, category, sub-category, priority.
--   * ANY edit of values restarts approval from stage 1 (the rules are then
--     re-evaluated against the new values).
--   * An alternate may act only once the stage has been pending longer than that
--     stage's escalation_hours.
--   * Send back may target the requester or any stage that already acted in this
--     cycle. The chain then resumes at the approver who sent it back (unless the
--     person it was sent to edits, which restarts it).
--
-- What was wrong before
-- ---------------------
--   * The stage JSON already carried can_forward / can_backward / can_edit_data /
--     approver_condition and the Approval Workflows screen let you set them, but
--     sp_approve_pr_datas ignored every one: it only did approve / reject and
--     stepped to the next entry of a list THE BROWSER SENT (approval_stages in the
--     request body). Conditional routing cannot be trusted to a client-supplied
--     list, so the new engine reads the stages itself and ignores anything sent.
--   * pr_history_data.status_date is a DATE (no time) — the escalation clock for
--     alternates needs a timestamp, hence the new tables below.
--
-- New objects (nothing existing is altered except sp_get_pr_details_for_approval,
-- which only gains trailing columns and the alternate-approver rows):
--   approval_instance    one row per document in approval: a SNAPSHOT of the stage
--                        chain, where it is now, cycle number (bumped on restart),
--                        the send-back resume point, and when the current stage
--                        started waiting.
--   approval_action_log  every approve / reject / forward / send-back / edit /
--                        skip / restart, with who, as whom (primary / alternate /
--                        requester), the comment and before/after values of edits.
--   fn_approval_condition_met / fn_approval_next_seq / fn_pr_approval_context
--   sp_nt_PrApprovalAct       the engine (approve|reject|forward|send_back|edit|resubmit)
--   sp_nt_PrApprovalContext   what the approval screen needs (path, targets, flags, log)
--   trg_pr_basic_info_approval_instance  creates the instance when a PR is raised,
--                        so no PR-creating procedure needed touching.
--
-- Stage JSON (additive keys; old stages without them behave exactly as before):
--   "condition":  {"match":"all"|"any","rules":[{"field":"amount","op":"gt","value":50000},
--                  {"field":"category","op":"in","value":[3,4]}]}
--                 field/op: amount gt|gte|lt|lte|between ; priority|category|subcategory in|not_in
--                 no condition = stage always required. A rule the evaluator cannot
--                 understand makes the stage REQUIRED (fail toward more approval).
--   "alternates": ["ECNO1","ECNO2"]
--
-- pr_history_data still receives one row per real approval ('A') / rejection ('R')
-- so PR Tracking keeps working; the richer actions live only in approval_action_log.
--
-- Revision (2026-09-26, later): CONDITION FIELDS ARE NOT FIXED.
--   What "amount" means, and which other values a rule can test, depends on the workflow's entity
--   type: a PR's amount is the total of its lines, a vendor-driven PR's includes GST and it can also
--   be tested by supplier / payment cycle, a payment's would be the payment amount. So:
--     * approval_condition_field  the registry: which fields each entity type offers, their label,
--                                 kind (number | list), option source (a master) and unit. The
--                                 Approval Workflows screen builds its rule editor from this.
--     * the evaluator (fn_approval_condition_met) no longer knows any field by name: it reads the
--       rule's field from a JSON CONTEXT the entity supplies (fn_pr_approval_context.context_json).
--   Adding a field or a whole entity = registry rows + a context function that emits a key per
--   registered field (+ wiring that entity's approval procedure to the engine). No evaluator or UI change.
--   Stored rules are unchanged: {"field","op","value"}, the same keys as before.
-- ============================================================

-- ── 1. Tables ───────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.approval_instance', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.approval_instance (
        instance_id         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_approval_instance PRIMARY KEY,
        entity_type         VARCHAR(50)   NOT NULL,
        entity_ref_id       INT           NOT NULL,
        workflow_types_id   INT           NULL,
        stages_json         NVARCHAR(MAX) NOT NULL,   -- snapshot of the stage chain for this cycle
        cycle_no            INT           NOT NULL CONSTRAINT DF_approval_instance_cycle  DEFAULT 1,
        current_seq         INT           NULL,       -- index into stages_json; NULL once finished
        return_to_seq       INT           NULL,       -- send-back: where to resume once fixed
        awaiting_requester  BIT           NOT NULL CONSTRAINT DF_approval_instance_await  DEFAULT 0,
        status              CHAR(1)       NOT NULL CONSTRAINT DF_approval_instance_status DEFAULT 'P',  -- P/A/R
        current_since       DATETIME      NOT NULL CONSTRAINT DF_approval_instance_since  DEFAULT GETDATE(),
        history_floor       INT           NOT NULL CONSTRAINT DF_approval_instance_floor  DEFAULT 0,    -- pr_history_sno at the start of this cycle
        created_at          DATETIME      NOT NULL CONSTRAINT DF_approval_instance_created DEFAULT GETDATE(),
        updated_at          DATETIME      NULL,
        CONSTRAINT UQ_approval_instance_entity UNIQUE (entity_type, entity_ref_id)
    );
END
GO

IF OBJECT_ID('dbo.approval_action_log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.approval_action_log (
        log_id         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_approval_action_log PRIMARY KEY,
        instance_id    INT           NOT NULL CONSTRAINT FK_approval_action_log_instance REFERENCES dbo.approval_instance (instance_id),
        entity_type    VARCHAR(50)   NOT NULL,
        entity_ref_id  INT           NOT NULL,
        cycle_no       INT           NOT NULL,
        action         VARCHAR(20)   NOT NULL,   -- APPROVE REJECT FORWARD SEND_BACK RESUBMIT EDIT RESTART SKIP
        from_seq       INT           NULL,
        to_seq         INT           NULL,
        stage_name     NVARCHAR(100) NULL,
        acted_by       VARCHAR(30)   NULL,
        acted_as       VARCHAR(10)   NULL,       -- PRIMARY ALTERNATE REQUESTER SYSTEM
        target_ecno    VARCHAR(30)   NULL,
        comments       NVARCHAR(1000) NULL,
        before_json    NVARCHAR(MAX) NULL,
        after_json     NVARCHAR(MAX) NULL,
        acted_at       DATETIME      NOT NULL CONSTRAINT DF_approval_action_log_at DEFAULT GETDATE()
    );
    CREATE INDEX IX_approval_action_log_instance ON dbo.approval_action_log (instance_id, log_id);
END
GO

-- ── 1b. Which condition fields each workflow type offers ────────────────────
IF OBJECT_ID('dbo.approval_condition_field', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.approval_condition_field (
        field_id       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_approval_condition_field PRIMARY KEY,
        entity_type    VARCHAR(50)   NOT NULL,   -- approval_workflow_master.entity_type
        field_key      VARCHAR(50)   NOT NULL,   -- the key in the entity's context JSON and in a stored rule
        field_label    NVARCHAR(100) NOT NULL,   -- what the rule editor shows
        value_kind     VARCHAR(10)   NOT NULL CONSTRAINT CK_approval_condition_field_kind CHECK (value_kind IN ('number','list')),
        option_source  VARCHAR(60)   NULL,       -- list fields: the master (getRequiredMasterForOptions) that supplies the choices
        unit           VARCHAR(20)   NULL,       -- number fields: INR, days ...
        help_text      NVARCHAR(200) NULL,
        sort_order     INT           NOT NULL CONSTRAINT DF_approval_condition_field_sort DEFAULT 0,
        is_active      CHAR(1)       NOT NULL CONSTRAINT DF_approval_condition_field_active DEFAULT 'Y',
        CONSTRAINT UQ_approval_condition_field UNIQUE (entity_type, field_key)
    );
END
GO

-- The registry is owned by this file: re-running it re-asserts these rows.
MERGE dbo.approval_condition_field AS t
USING (VALUES
    ('PurchaseRequisition',            'amount',             N'Amount (PR total)',          'number', NULL,                       'INR',  N'Total cost of all lines on the requisition', 1),
    ('PurchaseRequisition',            'category',           N'Category',                   'list',   'ProductCategoryMaster',    NULL,   N'Product categories of the lines',            2),
    ('PurchaseRequisition',            'subcategory',        N'Sub-category',               'list',   'ProductSubCategoryMaster', NULL,   N'Product sub-categories of the lines',        3),
    ('PurchaseRequisition',            'priority',           N'Priority',                   'list',   'PriorityMaster',           NULL,   N'Priority chosen on the requisition',         4),
    ('VendorDrivenPurchaseRequisition','amount',             N'Amount (total incl. GST)',   'number', NULL,                       'INR',  N'Total of all lines including GST',           1),
    ('VendorDrivenPurchaseRequisition','supplier',           N'Supplier',                   'list',   'VendorMaster',             NULL,   N'The supplier the requisition is for',        2),
    ('VendorDrivenPurchaseRequisition','payment_cycle_days', N'Payment cycle (days)',       'number', NULL,                       'days', N'Days agreed to pay the supplier',            3),
    ('VendorDrivenPurchaseRequisition','category',           N'Category',                   'list',   'ProductCategoryMaster',    NULL,   N'Product categories of the lines',            4),
    ('VendorDrivenPurchaseRequisition','subcategory',        N'Sub-category',               'list',   'ProductSubCategoryMaster', NULL,   N'Product sub-categories of the lines',        5),
    ('VendorDrivenPurchaseRequisition','priority',           N'Priority',                   'list',   'PriorityMaster',           NULL,   N'Priority chosen on the requisition',         6)
) AS s (entity_type, field_key, field_label, value_kind, option_source, unit, help_text, sort_order)
ON t.entity_type = s.entity_type AND t.field_key = s.field_key
WHEN MATCHED THEN
    UPDATE SET field_label = s.field_label, value_kind = s.value_kind, option_source = s.option_source,
               unit = s.unit, help_text = s.help_text, sort_order = s.sort_order, is_active = 'Y'
WHEN NOT MATCHED THEN
    INSERT (entity_type, field_key, field_label, value_kind, option_source, unit, help_text, sort_order)
    VALUES (s.entity_type, s.field_key, s.field_label, s.value_kind, s.option_source, s.unit, s.help_text, s.sort_order);
GO

-- @jsonInput: {"entity_type":"PurchaseRequisition"}. An entity type with no rows has no conditions yet.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetApprovalConditionFields
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @entity_type VARCHAR(50) = CASE WHEN ISJSON(@jsonInput) = 1 THEN JSON_VALUE(@jsonInput, '$.entity_type') END;

    SELECT field_key, field_label, value_kind, option_source, unit, help_text, sort_order
    FROM dbo.approval_condition_field
    WHERE is_active = 'Y' AND entity_type = @entity_type
    ORDER BY sort_order, field_key;
END
GO

-- ── 2. Condition evaluator ──────────────────────────────────────────────────
-- 1 = the stage applies to a document with these values. @context is the entity's JSON of values
-- ({"amount":120000,"priority":[2],"category":[1,3],...}); a rule names one of its keys. Number rules
-- (gt gte lt lte eq between) compare the key's number; list rules (in / not_in) compare the rule's ids
-- with the key's value, which may be an array (any element matches) or a single value.
-- A rule whose key is missing from the context, or that cannot be read, makes the stage REQUIRED.
CREATE OR ALTER FUNCTION dbo.fn_approval_condition_met
(
    @condition NVARCHAR(MAX),
    @context   NVARCHAR(MAX)
)
RETURNS BIT
AS
BEGIN
    IF @condition IS NULL OR ISJSON(@condition) = 0 RETURN 1;

    DECLARE @rules NVARCHAR(MAX) = JSON_QUERY(@condition, '$.rules');
    IF @rules IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@rules)) RETURN 1;

    DECLARE @any BIT = CASE WHEN LOWER(ISNULL(JSON_VALUE(@condition, '$.match'), 'all')) = 'any' THEN 1 ELSE 0 END;
    DECLARE @ctx NVARCHAR(MAX) = CASE WHEN ISJSON(@context) = 1 THEN @context ELSE N'{}' END;
    DECLARE @total INT, @hits INT, @bad INT;

    SELECT @total = COUNT(*),
           @hits  = SUM(t.hit),
           @bad   = SUM(1 - t.ok)
    FROM (
        SELECT
            k.ok,
            CASE
                WHEN k.ok = 0 THEN 0
                WHEN r.op = 'gt'      THEN IIF(p.cnum >  p.num, 1, 0)
                WHEN r.op = 'gte'     THEN IIF(p.cnum >= p.num, 1, 0)
                WHEN r.op = 'lt'      THEN IIF(p.cnum <  p.num, 1, 0)
                WHEN r.op = 'lte'     THEN IIF(p.cnum <= p.num, 1, 0)
                WHEN r.op = 'eq'      THEN IIF(p.cnum =  p.num, 1, 0)
                WHEN r.op = 'between' THEN IIF(p.cnum BETWEEN p.lo AND p.hi, 1, 0)
                WHEN r.op = 'in'      THEN f.found
                WHEN r.op = 'not_in'  THEN 1 - f.found
                ELSE 0
            END AS hit
        FROM OPENJSON(@rules) WITH (
                 field VARCHAR(50)   '$.field',
                 op    VARCHAR(10)   '$.op',
                 v     NVARCHAR(50)  '$.value',
                 arr   NVARCHAR(MAX) '$.value' AS JSON
             ) r
        OUTER APPLY (SELECT TOP 1 c.value AS cval, c.[type] AS ctype
                     FROM OPENJSON(@ctx) c
                     WHERE c.[key] COLLATE DATABASE_DEFAULT = r.field) cv
        CROSS APPLY (SELECT TRY_CAST(r.v AS DECIMAL(18,3))                          AS num,
                            TRY_CAST(JSON_VALUE(r.arr, '$[0]') AS DECIMAL(18,3))    AS lo,
                            TRY_CAST(JSON_VALUE(r.arr, '$[1]') AS DECIMAL(18,3))    AS hi,
                            TRY_CAST(CASE WHEN cv.ctype IN (1, 2) THEN cv.cval END AS DECIMAL(18,3)) AS cnum,
                            CASE WHEN cv.ctype = 4 THEN cv.cval
                                 WHEN cv.ctype = 2 THEN '[' + cv.cval + ']'
                                 WHEN cv.ctype = 1 THEN '["' + STRING_ESCAPE(cv.cval, 'json') + '"]'
                            END AS clist) p
        CROSS APPLY (SELECT CASE WHEN p.clist IS NOT NULL AND r.arr IS NOT NULL AND EXISTS (
                                   SELECT 1 FROM OPENJSON(r.arr) x
                                   JOIN OPENJSON(p.clist) y
                                     ON CAST(x.value AS NVARCHAR(200)) COLLATE DATABASE_DEFAULT = CAST(y.value AS NVARCHAR(200)) COLLATE DATABASE_DEFAULT
                               ) THEN 1 ELSE 0 END AS found) f
        CROSS APPLY (SELECT CASE
                                WHEN r.op IN ('gt','gte','lt','lte','eq') AND p.num IS NOT NULL AND p.cnum IS NOT NULL THEN 1
                                WHEN r.op = 'between' AND p.lo IS NOT NULL AND p.hi IS NOT NULL AND p.cnum IS NOT NULL THEN 1
                                WHEN r.op IN ('in','not_in') AND r.arr IS NOT NULL AND p.clist IS NOT NULL THEN 1
                                ELSE 0
                            END AS ok) k
    ) t;

    IF @bad > 0 RETURN 1;          -- unintelligible rule / value not in the context: keep the stage rather than skip an approval
    RETURN CASE WHEN @any = 1 THEN IIF(@hits > 0, 1, 0) ELSE IIF(@hits = @total, 1, 0) END;
END
GO

-- ── 3. First required stage after @after (NULL = none left) ─────────────────
CREATE OR ALTER FUNCTION dbo.fn_approval_next_seq
(
    @stages  NVARCHAR(MAX),
    @after   INT,
    @context NVARCHAR(MAX)
)
RETURNS INT
AS
BEGIN
    DECLARE @next INT;
    SELECT TOP 1 @next = CAST(s.[key] AS INT)
    FROM OPENJSON(@stages) s
    WHERE CAST(s.[key] AS INT) > @after
      AND dbo.fn_approval_condition_met(JSON_QUERY(s.value, '$.condition'), @context) = 1
    ORDER BY CAST(s.[key] AS INT);
    RETURN @next;
END
GO

-- ── 4. The values a PR's rules are evaluated against ────────────────────────
-- context_json carries one key per field registered for PR-type workflows (1b). A vendor-driven PR also
-- carries its supplier and payment cycle. amount / priority_sno / cats / subcats stay as plain columns
-- for the approval screen and the edit before/after snapshots.
CREATE OR ALTER FUNCTION dbo.fn_pr_approval_context (@pr_basic_sno INT)
RETURNS TABLE
AS
RETURN
(
    SELECT
        x.amount, x.priority_sno, x.cats, x.subcats,
        CONCAT('{"amount":', x.amount,
               ',"priority":[', ISNULL(CAST(x.priority_sno AS VARCHAR(20)), ''), ']',
               ',"category":', x.cats,
               ',"subcategory":', x.subcats,
               CASE WHEN x.vendor_sno IS NOT NULL THEN CONCAT(',"supplier":[', x.vendor_sno, ']') ELSE '' END,
               CASE WHEN x.pay_days   IS NOT NULL THEN CONCAT(',"payment_cycle_days":', x.pay_days) ELSE '' END,
               '}') AS context_json
    FROM (
        SELECT
            CAST(ISNULL((SELECT SUM(i.total_cost) FROM dbo.pr_item_details i
                         WHERE i.pr_basic_sno = @pr_basic_sno AND i.is_active = 'Y'), 0) AS DECIMAL(18,3)) AS amount,
            p.priority_sno,
            ISNULL((SELECT '[' + STRING_AGG(CAST(d.cat_sno AS VARCHAR(20)), ',') + ']'
                    FROM (SELECT DISTINCT pm.cat_sno
                          FROM dbo.pr_item_details i JOIN dbo.product_master pm ON pm.prod_sno = i.prod_sno
                          WHERE i.pr_basic_sno = @pr_basic_sno AND i.is_active = 'Y' AND pm.cat_sno IS NOT NULL) d), '[]') AS cats,
            ISNULL((SELECT '[' + STRING_AGG(CAST(d.subcat_sno AS VARCHAR(20)), ',') + ']'
                    FROM (SELECT DISTINCT pm.subcat_sno
                          FROM dbo.pr_item_details i JOIN dbo.product_master pm ON pm.prod_sno = i.prod_sno
                          WHERE i.pr_basic_sno = @pr_basic_sno AND i.is_active = 'Y' AND pm.subcat_sno IS NOT NULL) d), '[]') AS subcats,
            pvd.vendor_sno,
            pvd.payment_cycle_days AS pay_days
        FROM dbo.pr_basic_info p
        LEFT JOIN dbo.pr_vendor_driven_info pvd ON pvd.pr_basic_sno = p.pr_basic_sno
        WHERE p.pr_basic_sno = @pr_basic_sno
    ) x
)
GO

-- ── 5. The engine ───────────────────────────────────────────────────────────
-- @jsonInput: {"pr_no":"PR2627..","action":"approve|reject|forward|send_back|edit|resubmit",
--              "approved_by":"<session ecno>","comments":"..",
--              "target_seq":2,            -- forward (later stage) / send_back (earlier stage that acted)
--              "target":"REQUESTER",      -- send_back to the person who raised it
--              "edits":{"purpose":"..","required_date":"2026-10-01","priority_sno":1,
--                       "items":[{"pr_item_sno":12,"qty":5,"est_cost":100}]}}
-- Real errors are THROWN (the old procedure returned an 'ERROR' row that the screen
-- read as success).
CREATE OR ALTER PROCEDURE dbo.sp_nt_PrApprovalAct
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    -- No XACT_ABORT: a validation THROW must leave the caller's transaction (if any)
    -- rollback-able to our savepoint instead of dooming it.

    IF ISJSON(@jsonInput) = 0
        THROW 52001, N'Invalid JSON payload.', 1;

    DECLARE @own_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    DECLARE @pr_in       VARCHAR(30)    = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.pr_no'))), ''),
            @action      VARCHAR(20)    = LOWER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.action')))),
            @by          VARCHAR(30)    = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.approved_by'))), ''),
            @comments    NVARCHAR(1000) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.comments'))), ''),
            @target_seq  INT            = TRY_CAST(JSON_VALUE(@jsonInput, '$.target_seq') AS INT),
            @target      VARCHAR(30)    = UPPER(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.target'))), '')),
            @edits       NVARCHAR(MAX)  = JSON_QUERY(@jsonInput, '$.edits');

    IF @pr_in IS NULL THROW 52002, N'pr_no is required.', 1;
    IF @by IS NULL    THROW 52003, N'Approver EC number is required.', 1;
    IF @action IS NULL OR @action NOT IN ('approve','reject','forward','send_back','edit','resubmit')
        THROW 52004, N'Invalid action. Use approve | reject | forward | send_back | edit | resubmit.', 1;
    IF @action IN ('reject','send_back','edit') AND @comments IS NULL
        THROW 52008, N'A comment is required for this action.', 1;

    -- The approval screen lists a split PR as "PRxxxx/2"; the row itself is the base number.
    DECLARE @pr_no VARCHAR(30) = LEFT(@pr_in, CASE WHEN CHARINDEX('/', @pr_in) > 0 THEN CHARINDEX('/', @pr_in) - 1 ELSE LEN(@pr_in) END);

    DECLARE @pr_sno INT, @pr_status CHAR(1), @created_by VARCHAR(20), @mode VARCHAR(30), @wf INT, @cur_appr VARCHAR(20);
    DECLARE @inst INT, @stages NVARCHAR(MAX), @cycle INT, @cur INT, @ret INT, @await BIT, @since DATETIME, @istatus CHAR(1);
    DECLARE @stage NVARCHAR(MAX), @stage_name NVARCHAR(100), @primary VARCHAR(30), @esc_h INT, @role VARCHAR(10);
    DECLARE @ctx NVARCHAR(MAX);
    DECLARE @next INT, @next_appr VARCHAR(30), @result VARCHAR(20), @msg NVARCHAR(2048), @now DATETIME = GETDATE();
    DECLARE @before NVARCHAR(MAX), @after NVARCHAR(MAX), @hist_floor INT;

    BEGIN TRY
        IF @own_tran = 1
        BEGIN
            BEGIN TRAN;
        END
        ELSE
        BEGIN
            SAVE TRAN pr_approval_act;
        END

        SELECT @pr_sno = pr_basic_sno, @pr_status = status, @created_by = created_by,
               @mode = request_mode, @wf = workflow_types_id, @cur_appr = current_approver_id
        FROM dbo.pr_basic_info WITH (UPDLOCK)
        WHERE pr_no = @pr_no AND is_active = 'Y';

        IF @pr_sno IS NULL THROW 52005, N'Purchase Request not found or inactive.', 1;
        IF @pr_status <> 'P' THROW 52009, N'This Purchase Request is no longer pending approval.', 1;

        -- ── the approval instance (created by the trigger; rebuilt here for PRs raised before it existed)
        SELECT @inst = instance_id, @stages = stages_json, @cycle = cycle_no, @cur = current_seq, @ret = return_to_seq,
               @await = awaiting_requester, @since = current_since, @istatus = status
        FROM dbo.approval_instance WITH (UPDLOCK, HOLDLOCK)
        WHERE entity_type = 'PurchaseRequisition' AND entity_ref_id = @pr_sno;

        IF @inst IS NULL
        BEGIN
            SELECT TOP 1 @stages = stage_order_json FROM dbo.workflow_stage
            WHERE workflow_types_id = @wf AND is_active = 'Y' AND ISJSON(stage_order_json) = 1 ORDER BY stage_id;
            IF @stages IS NULL
            BEGIN
                -- The workflow this PR was raised under has since been retired (no active stages). Rather than
                -- strand the PR, give it a single stage held by whoever it is currently with.
                IF @cur_appr IS NULL THROW 52006, N'No approval stages are configured for this requisition.', 1;
                SET @stages = (SELECT @cur_appr AS approver_ecno, N'Approval' AS stage, '1' AS required_approvals, 'Y' AS is_mandatory,
                                      '24' AS escalation_hours, '' AS approver_condition, '' AS next_approver_ecno,
                                      'N' AS can_forward, 'N' AS can_backward, 'N' AS can_edit_data FOR JSON PATH);
            END

            SELECT TOP 1 @cur = CAST(s.[key] AS INT) FROM OPENJSON(@stages) s
            WHERE JSON_VALUE(s.value, '$.approver_ecno') = @cur_appr ORDER BY CAST(s.[key] AS INT);
            IF @cur IS NULL THROW 52007, N'Could not work out the current approval stage for this requisition.', 1;

            INSERT INTO dbo.approval_instance (entity_type, entity_ref_id, workflow_types_id, stages_json, cycle_no, current_seq, status, current_since)
            VALUES ('PurchaseRequisition', @pr_sno, @wf, @stages, 1, @cur, 'P', @now);
            SELECT @inst = SCOPE_IDENTITY(), @cycle = 1, @ret = NULL, @await = 0, @since = @now, @istatus = 'P';
        END

        IF @istatus <> 'P' THROW 52009, N'This Purchase Request is no longer pending approval.', 1;

        SET @stage = (SELECT s.value FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@cur AS NVARCHAR(10)));
        SELECT @stage_name = JSON_VALUE(@stage, '$.stage'),
               @primary    = JSON_VALUE(@stage, '$.approver_ecno'),
               @esc_h      = ISNULL(TRY_CAST(JSON_VALUE(@stage, '$.escalation_hours') AS INT), 24);

        -- Self-heal: the PR was re-assigned outside the engine (manual SQL, an older screen).
        IF @await = 0 AND ISNULL(@primary, '') <> ISNULL(@cur_appr, '')
        BEGIN
            DECLARE @healed INT;
            SELECT TOP 1 @healed = CAST(s.[key] AS INT) FROM OPENJSON(@stages) s
            WHERE JSON_VALUE(s.value, '$.approver_ecno') = @cur_appr ORDER BY CAST(s.[key] AS INT);
            IF @healed IS NULL THROW 52007, N'The approval chain and the current approver are out of step; ask an administrator to check the workflow.', 1;
            SET @cur = @healed;
            SET @stage = (SELECT s.value FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@cur AS NVARCHAR(10)));
            SELECT @stage_name = JSON_VALUE(@stage, '$.stage'), @primary = JSON_VALUE(@stage, '$.approver_ecno'),
                   @esc_h = ISNULL(TRY_CAST(JSON_VALUE(@stage, '$.escalation_hours') AS INT), 24);
            UPDATE dbo.approval_instance SET current_seq = @cur, current_since = @now, updated_at = @now WHERE instance_id = @inst;
            SET @since = @now;
        END

        -- ── who may act now
        IF @await = 1
        BEGIN
            IF @by <> @created_by
                THROW 52020, N'This requisition was sent back to the requester and is waiting for their correction.', 1;
            IF @action NOT IN ('edit','resubmit')
                THROW 52021, N'The requester can only edit or resubmit a requisition that was sent back.', 1;
            SET @role = 'REQUESTER';
        END
        ELSE
        BEGIN
            IF @action = 'resubmit'
                THROW 52022, N'Resubmit applies only to a requisition that was sent back to the requester.', 1;

            IF @by = @primary
                SET @role = 'PRIMARY';
            ELSE IF EXISTS (SELECT 1 FROM OPENJSON(@stage, '$.alternates') a WHERE a.value COLLATE DATABASE_DEFAULT = @by)
            BEGIN
                IF DATEDIFF(MINUTE, @since, @now) >= @esc_h * 60
                    SET @role = 'ALTERNATE';
                ELSE
                BEGIN
                    SET @msg = CONCAT(N'You are the alternate approver for this stage. You can act once it has been pending for ',
                                      @esc_h, N' hours (from ', CONVERT(VARCHAR(16), DATEADD(HOUR, @esc_h, @since), 120), N').');
                    THROW 52023, @msg, 1;
                END
            END
            ELSE
            BEGIN
                SET @msg = CONCAT(N'User ', @by, N' is not the current approver (expected ', ISNULL(@primary, N'-'), N').');
                THROW 52024, @msg, 1;
            END
        END

        SELECT @ctx = context_json FROM dbo.fn_pr_approval_context(@pr_sno);

        -- ════════ APPROVE ════════
        IF @action = 'approve'
        BEGIN
            SET @next = CASE WHEN @ret IS NOT NULL THEN @ret
                             ELSE dbo.fn_approval_next_seq(@stages, @cur, @ctx) END;

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, to_seq, stage_name, acted_by, acted_as, comments)
            VALUES (@inst, 'PurchaseRequisition', @pr_sno, @cycle, 'APPROVE', @cur, @next, @stage_name, @by, @role, @comments);

            IF @ret IS NULL
                INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, stage_name, acted_by, acted_as, comments)
                SELECT @inst, 'PurchaseRequisition', @pr_sno, @cycle, 'SKIP', CAST(s.[key] AS INT), JSON_VALUE(s.value, '$.stage'), @by, 'SYSTEM',
                       N'Not required - approval condition not met'
                FROM OPENJSON(@stages) s
                WHERE CAST(s.[key] AS INT) > @cur AND (@next IS NULL OR CAST(s.[key] AS INT) < @next);

            INSERT INTO dbo.pr_history_data (pr_basic_sno, pr_edit_data, workflow_types_id, approver_ecno, status, status_by, status_date, commends, is_active, pr_no)
            VALUES (@pr_sno, NULL, NULL, @primary, 'A', @by, @now, LEFT(@comments, 250), 'Y', @pr_no);

            IF @next IS NULL
            BEGIN
                UPDATE dbo.approval_instance SET status = 'A', current_seq = NULL, return_to_seq = NULL, updated_at = @now WHERE instance_id = @inst;
                UPDATE dbo.pr_basic_info SET current_approver_id = NULL, status = 'A' WHERE pr_basic_sno = @pr_sno;
                SET @next_appr = NULL;
            END
            ELSE
            BEGIN
                SET @next_appr = (SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@next AS NVARCHAR(10)));
                IF @next_appr IS NULL THROW 52011, N'The next approval stage has no approver configured.', 1;
                UPDATE dbo.approval_instance SET current_seq = @next, return_to_seq = NULL, current_since = @now, updated_at = @now WHERE instance_id = @inst;
                UPDATE dbo.pr_basic_info SET current_approver_id = @next_appr WHERE pr_basic_sno = @pr_sno;
            END
            SET @result = 'SUCCESS';
        END

        -- ════════ REJECT ════════
        ELSE IF @action = 'reject'
        BEGIN
            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, stage_name, acted_by, acted_as, comments)
            VALUES (@inst, 'PurchaseRequisition', @pr_sno, @cycle, 'REJECT', @cur, @stage_name, @by, @role, @comments);

            INSERT INTO dbo.pr_history_data (pr_basic_sno, pr_edit_data, workflow_types_id, approver_ecno, status, status_by, status_date, commends, is_active, pr_no)
            VALUES (@pr_sno, NULL, NULL, @primary, 'R', @by, @now, LEFT(@comments, 250), 'Y', @pr_no);

            UPDATE dbo.approval_instance SET status = 'R', current_seq = NULL, return_to_seq = NULL, updated_at = @now WHERE instance_id = @inst;
            UPDATE dbo.pr_basic_info SET status = 'R', current_approver_id = NULL WHERE pr_basic_sno = @pr_sno;
            SET @result = 'REJECTED';
        END

        -- ════════ FORWARD (jump to a later stage, even one the rules did not require) ════════
        ELSE IF @action = 'forward'
        BEGIN
            IF ISNULL(JSON_VALUE(@stage, '$.can_forward'), 'N') <> 'Y'
                THROW 52030, N'This stage is not allowed to forward.', 1;
            IF @target_seq IS NULL OR @target_seq <= @cur
                THROW 52031, N'Choose a later stage to forward to.', 1;

            SET @next_appr = (SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@target_seq AS NVARCHAR(10)));
            IF @next_appr IS NULL THROW 52032, N'That stage does not exist or has no approver.', 1;

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, to_seq, stage_name, acted_by, acted_as, target_ecno, comments)
            VALUES (@inst, 'PurchaseRequisition', @pr_sno, @cycle, 'FORWARD', @cur, @target_seq, @stage_name, @by, @role, @next_appr, @comments);

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, stage_name, acted_by, acted_as, comments)
            SELECT @inst, 'PurchaseRequisition', @pr_sno, @cycle, 'SKIP', CAST(s.[key] AS INT), JSON_VALUE(s.value, '$.stage'), @by, 'SYSTEM',
                   N'Bypassed - forwarded past this stage'
            FROM OPENJSON(@stages) s
            WHERE CAST(s.[key] AS INT) > @cur AND CAST(s.[key] AS INT) < @target_seq;

            UPDATE dbo.approval_instance SET current_seq = @target_seq, return_to_seq = NULL, current_since = @now, updated_at = @now WHERE instance_id = @inst;
            UPDATE dbo.pr_basic_info SET current_approver_id = @next_appr WHERE pr_basic_sno = @pr_sno;
            SET @next = @target_seq;
            SET @result = 'FORWARDED';
        END

        -- ════════ SEND BACK (requester, or a stage that already acted in this cycle) ════════
        ELSE IF @action = 'send_back'
        BEGIN
            IF ISNULL(JSON_VALUE(@stage, '$.can_backward'), 'N') <> 'Y'
                THROW 52040, N'This stage is not allowed to send back.', 1;

            IF @target = 'REQUESTER'
            BEGIN
                INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, to_seq, stage_name, acted_by, acted_as, target_ecno, comments)
                VALUES (@inst, 'PurchaseRequisition', @pr_sno, @cycle, 'SEND_BACK', @cur, NULL, @stage_name, @by, @role, @created_by, @comments);

                UPDATE dbo.approval_instance SET awaiting_requester = 1, return_to_seq = @cur, current_since = @now, updated_at = @now WHERE instance_id = @inst;
                UPDATE dbo.pr_basic_info SET current_approver_id = @created_by WHERE pr_basic_sno = @pr_sno;
                SET @next_appr = @created_by;
            END
            ELSE
            BEGIN
                IF @target_seq IS NULL OR @target_seq >= @cur
                    THROW 52041, N'Choose the requester or an earlier approver to send this back to.', 1;
                IF NOT EXISTS (SELECT 1 FROM dbo.approval_action_log
                               WHERE instance_id = @inst AND cycle_no = @cycle AND from_seq = @target_seq AND action IN ('APPROVE','FORWARD'))
                    THROW 52042, N'You can send back only to the requester or to an approver who has already acted on this requisition.', 1;

                SET @next_appr = (SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@target_seq AS NVARCHAR(10)));

                INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, to_seq, stage_name, acted_by, acted_as, target_ecno, comments)
                VALUES (@inst, 'PurchaseRequisition', @pr_sno, @cycle, 'SEND_BACK', @cur, @target_seq, @stage_name, @by, @role, @next_appr, @comments);

                UPDATE dbo.approval_instance SET current_seq = @target_seq, return_to_seq = @cur, current_since = @now, updated_at = @now WHERE instance_id = @inst;
                UPDATE dbo.pr_basic_info SET current_approver_id = @next_appr WHERE pr_basic_sno = @pr_sno;
                SET @next = @target_seq;
            END
            SET @result = 'SENT_BACK';
        END

        -- ════════ RESUBMIT (requester, no changes) ════════
        ELSE IF @action = 'resubmit'
        BEGIN
            SET @next = ISNULL(@ret, @cur);
            SET @next_appr = (SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@next AS NVARCHAR(10)));

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, to_seq, stage_name, acted_by, acted_as, target_ecno, comments)
            VALUES (@inst, 'PurchaseRequisition', @pr_sno, @cycle, 'RESUBMIT', NULL, @next, @stage_name, @by, @role, @next_appr, @comments);

            UPDATE dbo.approval_instance SET awaiting_requester = 0, current_seq = @next, return_to_seq = NULL, current_since = @now, updated_at = @now WHERE instance_id = @inst;
            UPDATE dbo.pr_basic_info SET current_approver_id = @next_appr WHERE pr_basic_sno = @pr_sno;
            SET @result = 'RESUBMITTED';
        END

        -- ════════ EDIT VALUES (always restarts the approval) ════════
        ELSE IF @action = 'edit'
        BEGIN
            IF @role <> 'REQUESTER' AND ISNULL(JSON_VALUE(@stage, '$.can_edit_data'), 'N') <> 'Y'
                THROW 52050, N'This stage is not allowed to edit values.', 1;
            IF @mode = 'VENDOR_DRIVEN'
                THROW 52051, N'Editing values is not supported for vendor-driven requisitions yet.', 1;
            IF @edits IS NULL OR ISJSON(@edits) = 0
                THROW 52052, N'No edits were supplied.', 1;

            DECLARE @new_purpose VARCHAR(200) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@edits, '$.purpose'))), ''),
                    @new_req     DATE         = TRY_CAST(JSON_VALUE(@edits, '$.required_date') AS DATE),
                    @new_prio    INT          = TRY_CAST(JSON_VALUE(@edits, '$.priority_sno') AS INT);

            CREATE TABLE #edit_items (pr_item_sno INT PRIMARY KEY, qty DECIMAL(10,3) NULL, est_cost DECIMAL(10,3) NULL);
            INSERT INTO #edit_items (pr_item_sno, qty, est_cost)
            SELECT e.pr_item_sno, e.qty, e.est_cost
            FROM OPENJSON(@edits, '$.items') WITH (pr_item_sno INT '$.pr_item_sno', qty DECIMAL(10,3) '$.qty', est_cost DECIMAL(10,3) '$.est_cost') e
            WHERE e.pr_item_sno IS NOT NULL;

            IF EXISTS (SELECT 1 FROM #edit_items e
                       WHERE NOT EXISTS (SELECT 1 FROM dbo.pr_item_details i
                                         WHERE i.pr_item_sno = e.pr_item_sno AND i.pr_basic_sno = @pr_sno AND i.is_active = 'Y'))
                THROW 52053, N'One of the edited lines does not belong to this requisition.', 1;
            IF EXISTS (SELECT 1 FROM #edit_items WHERE qty <= 0 OR est_cost < 0)
                THROW 52054, N'Quantity must be greater than zero and cost cannot be negative.', 1;
            IF EXISTS (SELECT 1 FROM #edit_items e JOIN dbo.pr_item_details i ON i.pr_item_sno = e.pr_item_sno
                       WHERE ISNULL(e.qty, i.qty) * ISNULL(e.est_cost, i.est_cost) > 9999999)
                THROW 52055, N'A line total exceeds the allowed limit.', 1;
            IF @new_prio IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.priority_master WHERE priority_sno = @new_prio)
                THROW 52056, N'Unknown priority.', 1;

            SET @before = (SELECT
                              (SELECT purpose, required_date, priority_sno FROM dbo.pr_basic_info WHERE pr_basic_sno = @pr_sno FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS header,
                              (SELECT i.pr_item_sno, i.qty, i.est_cost, i.total_cost FROM dbo.pr_item_details i
                               WHERE i.pr_basic_sno = @pr_sno AND i.is_active = 'Y' FOR JSON PATH) AS items,
                              (SELECT amount FROM dbo.fn_pr_approval_context(@pr_sno)) AS amount
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            UPDATE dbo.pr_basic_info
            SET purpose = ISNULL(@new_purpose, purpose), required_date = ISNULL(@new_req, required_date),
                priority_sno = ISNULL(@new_prio, priority_sno), modified_by = @by, modified_date = CAST(@now AS DATE)
            WHERE pr_basic_sno = @pr_sno;

            UPDATE i
            SET qty = ISNULL(e.qty, i.qty), est_cost = ISNULL(e.est_cost, i.est_cost),
                total_cost = ROUND(ISNULL(e.qty, i.qty) * ISNULL(e.est_cost, i.est_cost), 3),
                modified_by = @by, modified_date = CAST(@now AS DATE)
            FROM dbo.pr_item_details i JOIN #edit_items e ON e.pr_item_sno = i.pr_item_sno
            WHERE i.pr_basic_sno = @pr_sno AND i.is_active = 'Y';

            SET @after = (SELECT
                              (SELECT purpose, required_date, priority_sno FROM dbo.pr_basic_info WHERE pr_basic_sno = @pr_sno FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS header,
                              (SELECT i.pr_item_sno, i.qty, i.est_cost, i.total_cost FROM dbo.pr_item_details i
                               WHERE i.pr_basic_sno = @pr_sno AND i.is_active = 'Y' FOR JSON PATH) AS items,
                              (SELECT amount FROM dbo.fn_pr_approval_context(@pr_sno)) AS amount
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            DROP TABLE #edit_items;

            IF @before = @after
                THROW 52057, N'Nothing was changed, so the approval was not restarted.', 1;

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, stage_name, acted_by, acted_as, comments, before_json, after_json)
            VALUES (@inst, 'PurchaseRequisition', @pr_sno, @cycle, 'EDIT', @cur, @stage_name, @by, @role, @comments, @before, @after);

            -- restart: fresh cycle from stage 1 on the current workflow definition
            DECLARE @fresh NVARCHAR(MAX) = (SELECT TOP 1 stage_order_json FROM dbo.workflow_stage
                                            WHERE workflow_types_id = @wf AND is_active = 'Y' AND ISJSON(stage_order_json) = 1 ORDER BY stage_id);
            IF @fresh IS NOT NULL SET @stages = @fresh;
            SET @next_appr = (SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = '0');
            IF @next_appr IS NULL THROW 52011, N'The first approval stage has no approver configured.', 1;
            SET @hist_floor = ISNULL((SELECT MAX(pr_history_sno) FROM dbo.pr_history_data WHERE pr_basic_sno = @pr_sno), 0);

            UPDATE dbo.approval_instance
            SET stages_json = @stages, cycle_no = @cycle + 1, current_seq = 0, return_to_seq = NULL, awaiting_requester = 0,
                status = 'P', current_since = @now, history_floor = @hist_floor, updated_at = @now
            WHERE instance_id = @inst;
            UPDATE dbo.pr_basic_info SET current_approver_id = @next_appr WHERE pr_basic_sno = @pr_sno;

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, to_seq, stage_name, acted_by, acted_as, target_ecno, comments)
            VALUES (@inst, 'PurchaseRequisition', @pr_sno, @cycle + 1, 'RESTART', 0, JSON_VALUE((SELECT s.value FROM OPENJSON(@stages) s WHERE s.[key] = '0'), '$.stage'),
                    @by, 'SYSTEM', @next_appr, N'Approval restarted from the first stage after values were edited');
            SET @next = 0;
            SET @result = 'EDITED';
        END

        IF @own_tran = 1 COMMIT TRAN;

        SELECT @result                                AS result,
               @pr_no                                 AS pr_no,
               @by                                    AS approved_by,
               @now                                   AS approved_on,
               1                                      AS stages_processed,
               CASE WHEN @result = 'REJECTED' THEN NULL
                    ELSE ISNULL(@next_appr, 'FINAL_STAGE') END AS next_approver,
               CAST(NULL AS VARCHAR(200))             AS next_condition,
               CAST(NULL AS CHAR(1))                  AS next_can_forward,
               @pr_sno                                AS pr_basic_sno,
               @mode                                  AS request_mode,
               @next                                  AS next_seq,
               @role                                  AS acted_as;
    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#edit_items') IS NOT NULL DROP TABLE #edit_items;
        IF @own_tran = 1
        BEGIN
            IF XACT_STATE() <> 0 ROLLBACK TRAN;
        END
        ELSE IF XACT_STATE() = 1
        BEGIN
            ROLLBACK TRAN pr_approval_act;      -- undo only our own writes; the caller decides the rest
        END;
        THROW;
    END CATCH
END
GO

-- ── 6. What the approval screen needs ───────────────────────────────────────
-- Six result sets, always in this order (shapes fixed even when there is no instance):
--   RS1 summary + what the caller may do    RS2 the stages with their state
--   RS3 forward targets                     RS4 send-back targets
--   RS5 the action log (all cycles)         RS6 the condition fields this workflow type offers
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
    WHERE is_active = 'Y' AND entity_type = @entity_type
    ORDER BY sort_order, field_key;

    DROP TABLE #stg; DROP TABLE #codes; DROP TABLE #people;
END
GO

-- ── 7. Approval queue: also list PRs the caller is the ALTERNATE for, once overdue ─────
-- Same as before (current approver + hierarchy scope) plus: my_role / cycle_no /
-- awaiting_requester / stage_pending_since. The requester of a PR that was sent
-- back to them already matches current_approver_id.
CREATE OR ALTER PROCEDURE dbo.sp_get_pr_details_for_approval
    @Ecno           VARCHAR(20),
    @HierarchyJson  NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        SELECT
            vw.*,
            CASE WHEN vw.current_approver_id = @Ecno THEN 'PRIMARY' ELSE 'ALTERNATE' END AS my_role,
            ai.cycle_no             AS approval_cycle_no,
            ai.awaiting_requester   AS awaiting_requester,
            ai.current_since        AS stage_pending_since
        FROM dbo.vw_PR_Basic_Info vw
        LEFT JOIN dbo.approval_instance ai
               ON ai.entity_type = 'PurchaseRequisition' AND ai.entity_ref_id = vw.pr_basic_sno
        WHERE vw.status = 'P'
          AND (
                vw.current_approver_id = @Ecno
                OR EXISTS (
                    SELECT 1
                    FROM dbo.approval_instance a2
                    CROSS APPLY OPENJSON(a2.stages_json) st
                    WHERE a2.entity_type = 'PurchaseRequisition'
                      AND a2.entity_ref_id = vw.pr_basic_sno
                      AND a2.status = 'P' AND a2.awaiting_requester = 0
                      AND st.[key] = CAST(a2.current_seq AS NVARCHAR(10))
                      AND EXISTS (SELECT 1 FROM OPENJSON(st.value, '$.alternates') a WHERE a.value COLLATE DATABASE_DEFAULT = @Ecno)
                      AND DATEDIFF(MINUTE, a2.current_since, GETDATE())
                          >= ISNULL(TRY_CAST(JSON_VALUE(st.value, '$.escalation_hours') AS INT), 24) * 60
                )
              )
          AND (
                @HierarchyJson IS NULL
                OR EXISTS (
                    SELECT 1
                    FROM OPENJSON(@HierarchyJson)
                    WITH (
                        com_sno INT '$.com_sno',
                        div_sno INT '$.div_sno',
                        brn_sno INT '$.brn_sno'
                    ) h
                    WHERE h.com_sno = vw.com_sno
                      AND (h.div_sno IS NULL OR h.div_sno = vw.div_sno)
                      AND (h.brn_sno IS NULL OR h.brn_sno = vw.brn_sno)
                )
              )

    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

-- ── 8. Create the instance whenever a PR is raised ──────────────────────────
-- A trigger rather than editing every PR-creating procedure (normal, vendor-driven,
-- recurring, agreement-driven). Only pending PRs with a workflow get one.
CREATE OR ALTER TRIGGER dbo.trg_pr_basic_info_approval_instance
ON dbo.pr_basic_info
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.approval_instance (entity_type, entity_ref_id, workflow_types_id, stages_json, cycle_no, current_seq, status, current_since)
    SELECT 'PurchaseRequisition', i.pr_basic_sno, i.workflow_types_id, ws.stage_order_json, 1, 0, 'P', GETDATE()
    FROM inserted i
    CROSS APPLY (SELECT TOP 1 w.stage_order_json
                 FROM dbo.workflow_stage w
                 WHERE w.workflow_types_id = i.workflow_types_id AND w.is_active = 'Y' AND ISJSON(w.stage_order_json) = 1
                 ORDER BY w.stage_id) ws
    WHERE i.status = 'P' AND i.workflow_types_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.approval_instance a
                      WHERE a.entity_type = 'PurchaseRequisition' AND a.entity_ref_id = i.pr_basic_sno);
END
GO

-- ── 9. Backfill: PRs already pending get an instance at the stage they are with ─────
-- The escalation clock for these starts at migration time (their real arrival time
-- was never recorded — pr_history_data holds dates only).
INSERT INTO dbo.approval_instance (entity_type, entity_ref_id, workflow_types_id, stages_json, cycle_no, current_seq, status, current_since)
SELECT 'PurchaseRequisition', p.pr_basic_sno, p.workflow_types_id, ws.stage_order_json, 1, m.seq, 'P', GETDATE()
FROM dbo.pr_basic_info p
CROSS APPLY (SELECT TOP 1 w.stage_order_json FROM dbo.workflow_stage w
             WHERE w.workflow_types_id = p.workflow_types_id AND w.is_active = 'Y' AND ISJSON(w.stage_order_json) = 1
             ORDER BY w.stage_id) ws
CROSS APPLY (SELECT TOP 1 CAST(s.[key] AS INT) AS seq FROM OPENJSON(ws.stage_order_json) s
             WHERE JSON_VALUE(s.value, '$.approver_ecno') = p.current_approver_id
             ORDER BY CAST(s.[key] AS INT)) m
WHERE p.status = 'P' AND p.is_active = 'Y' AND p.workflow_types_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.approval_instance a
                  WHERE a.entity_type = 'PurchaseRequisition' AND a.entity_ref_id = p.pr_basic_sno);
GO
