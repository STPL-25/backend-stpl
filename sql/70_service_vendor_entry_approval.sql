-- ============================================================
-- Per-entry approval for Vendor Driven daily entries
-- Database : Non_trade_Dev (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/ServiceVendorEntry module
--
-- Why this is needed
-- ------------------
-- service_vendor_daily_entry (41_service_vendor_daily_entry.sql,
-- 46_service_vendor_daily_entry_receipt.sql) let anyone log a daily Vendor
-- Driven purchase (e.g. canteen groceries) straight to PENDING with zero
-- review — only the later, periodic consolidated PO went through approval.
-- User explicitly asked for approval on EVERY purchase, not just the
-- consolidated batch: a supervisor verifies each entry (qty/price/receipt)
-- soon after it's logged, catching a padded or wrong entry immediately
-- instead of it being buried in a 15/30-day batch of many.
--
-- This is retrospective verification, not a pre-purchase gate — the goods
-- are already bought by the time an entry is logged (perishables can't wait
-- for approval). So the new state machine is:
--   PENDING_APPROVAL (awaiting the assigned approver's review)
--     -> PENDING       (approved — same meaning as the old default state:
--                        eligible for consolidation. The consolidation
--                        screen already hardcodes status:'PENDING', so it
--                        needs NO changes — it naturally only ever offers
--                        entries that have cleared this new approval step.)
--     -> REJECTED       (terminal; requester logs a fresh corrected entry,
--                        no edit-in-place)
--   PROCESSING / CONSOLIDATED / CANCELLED — unchanged from before.
--
-- Approval state lives directly on service_vendor_daily_entry itself (its
-- own dedicated table, per the user's explicit instruction — NOT merged
-- into service_entry_info or any other entity's table), same convention
-- every other Service* entity already uses (service_entry_info,
-- service_bill_request all keep their own workflow/approval columns
-- in-table, not in a separate approval-log table).
--
-- Workflow lookup mirrors sp_nt_CreateServicePO's pattern (entity_type join
-- against approval_workflow_master/workflow_types), but unlike ServicePO's
-- "no config -> direct issue" fallback, this one hard-requires a configured
-- workflow (THROW), matching sp_nt_CreateServiceEntry's stricter precedent
-- — the whole point here is approval is mandatory, not optional. The
-- workflow is auto-configured for com14/div14/brn13/dept15 (the only org
-- scope any Service* activity exists in, per every prior Service* workflow
-- in this repo) at the bottom of this file, so nothing is actually blocked
-- once this file has run.
-- ============================================================

-- ── new columns on the existing, dedicated table ────────────────────────────

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_vendor_daily_entry') AND name = 'workflow_types_id')
    ALTER TABLE dbo.service_vendor_daily_entry ADD workflow_types_id INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_vendor_daily_entry') AND name = 'current_approver_id')
    ALTER TABLE dbo.service_vendor_daily_entry ADD current_approver_id VARCHAR(20) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_vendor_daily_entry') AND name = 'approved_by')
    ALTER TABLE dbo.service_vendor_daily_entry ADD approved_by VARCHAR(20) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_vendor_daily_entry') AND name = 'approved_at')
    ALTER TABLE dbo.service_vendor_daily_entry ADD approved_at DATETIME NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_vendor_daily_entry') AND name = 'approval_comments')
    ALTER TABLE dbo.service_vendor_daily_entry ADD approval_comments VARCHAR(500) NULL;
GO

-- Widen the status state machine: PENDING_APPROVAL and REJECTED are new;
-- PENDING/PROCESSING/CONSOLIDATED/CANCELLED keep their exact old meaning, so
-- every pre-existing row (already PENDING or beyond) needs no backfill —
-- they're grandfathered in as already-approved.
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_service_vendor_daily_entry_status')
    ALTER TABLE dbo.service_vendor_daily_entry DROP CONSTRAINT CK_service_vendor_daily_entry_status;
GO
ALTER TABLE dbo.service_vendor_daily_entry
    ADD CONSTRAINT CK_service_vendor_daily_entry_status
        CHECK (status IN ('PENDING_APPROVAL','PENDING','PROCESSING','CONSOLIDATED','CANCELLED','REJECTED'));
GO

-- entity_master seed row for the approval-side workflow lookup (same
-- convention as grn-service/sql/12_service_entry.sql:101-105)
IF NOT EXISTS (SELECT 1 FROM dbo.entity_master WHERE entity_code = 'ServiceVendorEntry')
    INSERT INTO dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by)
    VALUES (N'Service Vendor Daily Entry', N'ServiceVendorEntry', NULL, 'Y', N'system');
GO

-- ============================================================
-- sp_nt_CreateServiceVendorDailyEntry v3 — now resolves a mandatory
-- ServiceVendorEntry workflow for the entry's org scope and starts every
-- new entry at PENDING_APPROVAL instead of PENDING. Everything else
-- (validation, receipt_doc_url requirement) unchanged from v2
-- (46_service_vendor_daily_entry_receipt.sql), same error codes reused.
-- @jsonInput unchanged shape: {com_sno,div_sno,brn_sno,dept_sno,vendor_sno,
--   service_sno,entry_date,qty,unit,unit_price,specification,remarks,
--   receipt_doc_url,created_by}
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateServiceVendorDailyEntry', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateServiceVendorDailyEntry;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceVendorDailyEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
    DECLARE @div_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
    DECLARE @brn_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
    DECLARE @dept_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
    DECLARE @vendor_sno     INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    DECLARE @service_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
    DECLARE @entry_date     DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.entry_date') AS DATE);
    DECLARE @qty            DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4));
    DECLARE @unit           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.unit') AS INT);
    DECLARE @unit_price     DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.unit_price') AS DECIMAL(18,4));
    DECLARE @specification  NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.specification');
    DECLARE @remarks        NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
    DECLARE @receipt_doc_url NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.receipt_doc_url');
    DECLARE @created_by     VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
       OR @vendor_sno IS NULL OR @service_sno IS NULL OR @entry_date IS NULL OR @created_by IS NULL
        THROW 54100, 'com_sno, div_sno, brn_sno, dept_sno, vendor_sno, service_sno, entry_date and created_by are required.', 1;

    IF @qty IS NULL OR @qty <= 0
        THROW 54102, 'qty must be greater than 0.', 1;

    IF @unit_price IS NULL OR @unit_price < 0
        THROW 54103, 'unit_price is required and cannot be negative.', 1;

    IF @receipt_doc_url IS NULL OR LTRIM(RTRIM(@receipt_doc_url)) = ''
        THROW 54104, 'receipt_doc_url is required — upload today''s receipt/bill before submitting.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND st.service_type_code = 'VENDOR_BILL' AND sm.is_active = 'Y'
    )
        THROW 54101, 'service_sno must reference an active Vendor-Bill-Driven service.', 1;

    -- Mandatory per-entry approval workflow lookup (mirrors
    -- sp_nt_CreateServicePO's entity_type join; unlike ServicePO's "no
    -- config -> direct issue" fallback, this hard-throws when unconfigured
    -- — approval on every purchase is the explicit requirement here).
    DECLARE @workflow_types_id   INT;
    DECLARE @first_approver_id   VARCHAR(20);

    SELECT @workflow_types_id = wt.workflow_types_id
    FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
      AND awm.entity_type = 'ServiceVendorEntry' AND awm.is_active = 'Y' AND wt.is_active = 'Y';

    IF @workflow_types_id IS NULL
        THROW 54105, 'No ServiceVendorEntry approval workflow configured for this company/division/branch/department. Configure it in Approval Workflow Manager before logging purchases.', 1;

    SELECT @first_approver_id = JSON_VALUE(s2.value, '$.approver_ecno')
    FROM dbo.vw_workflow_stages AS ws
    CROSS APPLY OPENJSON(ws.stages_json) AS s
    CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
    WHERE ws.workflow_types_id = @workflow_types_id AND s.[key] = '0' AND s2.[key] = '0';

    IF @first_approver_id IS NULL
        THROW 54106, 'No approver found for the first stage of the ServiceVendorEntry workflow.', 1;

    DECLARE @total_amount DECIMAL(18,4) = @qty * @unit_price;

    INSERT INTO dbo.service_vendor_daily_entry (
        com_sno, div_sno, brn_sno, dept_sno, vendor_sno, service_sno,
        entry_date, qty, unit, unit_price, total_amount,
        specification, remarks, receipt_doc_url, status,
        workflow_types_id, current_approver_id,
        created_by, created_date, is_active
    )
    VALUES (
        @com_sno, @div_sno, @brn_sno, @dept_sno, @vendor_sno, @service_sno,
        @entry_date, @qty, @unit, @unit_price, @total_amount,
        @specification, @remarks, @receipt_doc_url, 'PENDING_APPROVAL',
        @workflow_types_id, @first_approver_id,
        @created_by, GETDATE(), 'Y'
    );

    DECLARE @entry_sno INT = SCOPE_IDENTITY();

    SELECT
        e.entry_sno, e.com_sno, e.div_sno, e.brn_sno, e.dept_sno,
        e.vendor_sno, k.company_name AS vendor_name,
        e.service_sno, sm.service_name,
        e.entry_date, e.qty, e.unit, um.uom_name AS unit_name, e.unit_price, e.total_amount,
        e.specification, e.remarks, e.receipt_doc_url, e.status,
        e.workflow_types_id, e.current_approver_id,
        e.created_by, e.created_date
    FROM dbo.service_vendor_daily_entry e
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = e.vendor_sno
    LEFT JOIN dbo.service_master sm ON sm.service_sno = e.service_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = e.unit
    WHERE e.entry_sno = @entry_sno;
END;
GO

-- ============================================================
-- sp_nt_ApproveServiceVendorDailyEntry — single-stage (one approver, no
-- multi-stage chain), same simplicity precedent as sp_nt_ApproveServiceEntry
-- (grn-service/sql/12_service_entry.sql). Approve -> PENDING (now eligible
-- for consolidation, unchanged meaning). Reject -> REJECTED (terminal;
-- comments required).
-- @jsonInput: {entry_sno, action:'Approve'|'Reject', approved_by, comments}
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ApproveServiceVendorDailyEntry', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_ApproveServiceVendorDailyEntry;
GO
CREATE PROCEDURE dbo.sp_nt_ApproveServiceVendorDailyEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @entry_sno    INT          = TRY_CAST(JSON_VALUE(@jsonInput, '$.entry_sno') AS INT);
    DECLARE @action       VARCHAR(20)  = JSON_VALUE(@jsonInput, '$.action');
    DECLARE @approved_by  VARCHAR(20)  = JSON_VALUE(@jsonInput, '$.approved_by');
    DECLARE @comments     VARCHAR(500) = JSON_VALUE(@jsonInput, '$.comments');

    IF @entry_sno IS NULL OR @approved_by IS NULL
        THROW 54160, 'entry_sno and approved_by are required.', 1;

    IF @action NOT IN ('Approve', 'Reject')
        THROW 54161, 'action must be Approve or Reject.', 1;

    DECLARE @current_status VARCHAR(20), @current_approver VARCHAR(20);
    SELECT @current_status = status, @current_approver = current_approver_id
    FROM dbo.service_vendor_daily_entry
    WHERE entry_sno = @entry_sno;

    IF @current_status IS NULL
        THROW 54162, 'Entry not found.', 1;

    IF @current_status <> 'PENDING_APPROVAL'
        THROW 54163, 'This entry is not awaiting approval (already actioned or consolidated).', 1;

    IF @current_approver IS NULL OR @current_approver <> @approved_by
        THROW 54164, 'You are not the assigned approver for this entry.', 1;

    IF @action = 'Reject' AND (@comments IS NULL OR LTRIM(RTRIM(@comments)) = '')
        THROW 54165, 'Comments are required when rejecting an entry.', 1;

    UPDATE dbo.service_vendor_daily_entry
    SET status = CASE WHEN @action = 'Approve' THEN 'PENDING' ELSE 'REJECTED' END,
        approved_by = @approved_by,
        approved_at = GETDATE(),
        approval_comments = @comments,
        current_approver_id = NULL
    WHERE entry_sno = @entry_sno;

    SELECT
        e.entry_sno, e.com_sno, e.div_sno, e.brn_sno, e.dept_sno,
        e.vendor_sno, k.company_name AS vendor_name,
        e.service_sno, sm.service_name,
        e.entry_date, e.qty, e.unit, um.uom_name AS unit_name, e.unit_price, e.total_amount,
        e.specification, e.remarks, e.receipt_doc_url, e.status,
        e.workflow_types_id, e.current_approver_id, e.approved_by, e.approved_at, e.approval_comments,
        e.created_by, e.created_date
    FROM dbo.service_vendor_daily_entry e
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = e.vendor_sno
    LEFT JOIN dbo.service_master sm ON sm.service_sno = e.service_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = e.unit
    WHERE e.entry_sno = @entry_sno;
END;
GO

-- ============================================================
-- sp_nt_GetServiceVendorDailyEntries v3 — adds an @approver_ecno filter
-- (for the new approval-queue screen: pass status:'PENDING_APPROVAL' +
-- approver_ecno together) and returns the new approval columns. Filter
-- logic otherwise unchanged from v2 (46_service_vendor_daily_entry_receipt.sql).
-- @jsonInput optional filters: {vendor_sno, service_sno, com_sno, div_sno,
--   brn_sno, dept_sno, status, date_from, date_to, approver_ecno}
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServiceVendorDailyEntries', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetServiceVendorDailyEntries;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceVendorDailyEntries
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @vendor_sno    INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    DECLARE @service_sno   INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
    DECLARE @com_sno       INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
    DECLARE @div_sno       INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
    DECLARE @brn_sno       INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
    DECLARE @dept_sno      INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
    DECLARE @status        VARCHAR(20) = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @date_from     DATE        = TRY_CAST(JSON_VALUE(@jsonInput, '$.date_from') AS DATE);
    DECLARE @date_to       DATE        = TRY_CAST(JSON_VALUE(@jsonInput, '$.date_to') AS DATE);
    DECLARE @approver_ecno VARCHAR(20) = JSON_VALUE(@jsonInput, '$.approver_ecno');

    SELECT
        e.entry_sno, e.com_sno, e.div_sno, e.brn_sno, e.dept_sno,
        e.vendor_sno, k.company_name AS vendor_name,
        e.service_sno, sm.service_name,
        e.entry_date, e.qty, e.unit, um.uom_name AS unit_name, e.unit_price, e.total_amount,
        e.specification, e.remarks, e.receipt_doc_url, e.status, e.po_basic_sno, p.po_df_no AS po_no,
        e.workflow_types_id, e.current_approver_id, e.approved_by, e.approved_at, e.approval_comments,
        e.created_by, e.created_date, e.consolidated_by, e.consolidated_date
    FROM dbo.service_vendor_daily_entry e
    LEFT JOIN dbo.kyc_basic_info k    ON k.kyc_basic_info_sno = e.vendor_sno
    LEFT JOIN dbo.service_master sm   ON sm.service_sno = e.service_sno
    LEFT JOIN dbo.uom_master um       ON um.uom_sno = e.unit
    LEFT JOIN dbo.po_request_info p   ON p.po_basic_sno = e.po_basic_sno
    WHERE e.is_active = 'Y'
      AND (@vendor_sno IS NULL OR e.vendor_sno = @vendor_sno)
      AND (@service_sno IS NULL OR e.service_sno = @service_sno)
      AND (@com_sno IS NULL OR e.com_sno = @com_sno)
      AND (@div_sno IS NULL OR e.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR e.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR e.dept_sno = @dept_sno)
      AND (@date_from IS NULL OR e.entry_date >= @date_from)
      AND (@date_to IS NULL OR e.entry_date <= @date_to)
      AND (@approver_ecno IS NULL OR e.current_approver_id = @approver_ecno)
      AND (
            (@status IS NULL AND e.status <> 'CANCELLED')
            OR e.status = @status
          )
    ORDER BY e.entry_date DESC, e.entry_sno DESC;
END;
GO

-- ============================================================
-- Auto-configure the ServiceVendorEntry workflow, live, via the real
-- sp_nt_SaveFullWorkflow procedure (same path a human would use through
-- Approval Workflow Manager) — same org scope/approver every other Service*
-- workflow in this repo uses (com_sno=14/div_sno=14/brn_sno=13/dept_sno=15,
-- single stage, approver KTM1148). Idempotent: skips if a ServiceVendorEntry
-- workflow already exists for this scope. Without this, every daily entry
-- submission for that scope would hit THROW 54105 above.
-- ============================================================
IF NOT EXISTS (
    SELECT 1
    FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE awm.entity_type = 'ServiceVendorEntry'
      AND wt.com_sno = 14 AND wt.div_sno = 14 AND wt.brn_sno = 13 AND wt.dept_sno = 15
)
BEGIN
    EXEC dbo.sp_nt_SaveFullWorkflow @jsonInput = N'{
        "workflow_name": "ServiceVendorEntry Approval Workflow",
        "entity_type": "ServiceVendorEntry",
        "description": "Per-purchase approval for Vendor Driven daily entries (e.g. canteen groceries) before they become eligible for periodic consolidation into a Service PO.",
        "is_active": "Y",
        "created_by": "system",
        "workflow_types": [
            {
                "workflow_types_name": "ServiceVendorEntry - Default",
                "workflow_types_description": "Default ServiceVendorEntry workflow for com14/div14/brn13/dept15",
                "com_sno": 14,
                "div_sno": 14,
                "brn_sno": 13,
                "dept_sno": 15,
                "is_active": "Y",
                "stage_order_json": "[{\"approver_ecno\":\"KTM1148\",\"stage\":\"Approver\",\"required_approvals\":\"1\",\"is_mandatory\":\"Y\",\"escalation_hours\":\"24\",\"approver_condition\":\"\",\"next_approver_ecno\":\"0\",\"can_forward\":\"Y\",\"can_backward\":\"N\",\"can_edit_data\":\"N\"}]"
            }
        ]
    }';
END
GO

-- ============================================================
-- Register the approval-queue screen and grant it to KTM1148 (the approver
-- just configured above) — same group_id/screen_code convention as every
-- other Service* screen. The daily-entry form itself needs no new screen
-- (reuses ServiceAgreementPage, unchanged, same reasoning as
-- 42_service_vendor_entry_screen.sql).
-- ============================================================
DECLARE @svGroupId       INT           = 2;
DECLARE @svScreenCode    VARCHAR(10)   = N'S17';
DECLARE @svDisplayOrder  INT           = 22;
DECLARE @svCompImg       NVARCHAR(100) = N'ClipboardCheck';

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceVendorEntryApprovalScreen')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Vendor Entry Approvals', @svScreenCode, 'ServiceVendorEntryApprovalScreen', @svCompImg, @svGroupId, @svDisplayOrder, 'Y');
GO

DECLARE @svApprovalScreenId INT = (SELECT screen_id FROM dbo.screens WHERE comp = 'ServiceVendorEntryApprovalScreen');
DECLARE @svGrantJson NVARCHAR(MAX) = N'{"ecno":"KTM1148","screen_id":' + CAST(@svApprovalScreenId AS NVARCHAR(10)) + N',"permission_ids":[2,3,4,5,7,8]}';
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @svGrantJson;
GO

-- ============================================================
-- After running, confirm:
--   SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.service_vendor_daily_entry') AND name IN ('workflow_types_id','current_approver_id','approved_by','approved_at','approval_comments');
--   SELECT name FROM sys.procedures WHERE name IN ('sp_nt_CreateServiceVendorDailyEntry','sp_nt_ApproveServiceVendorDailyEntry','sp_nt_GetServiceVendorDailyEntries');
--   SELECT wt.workflow_types_id, wt.workflow_types_name FROM dbo.workflow_types wt INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id WHERE awm.entity_type = 'ServiceVendorEntry';
--   SELECT * FROM dbo.screens WHERE comp = 'ServiceVendorEntryApprovalScreen';
--   EXEC dbo.sp_nt_CreateServiceVendorDailyEntry @jsonInput = N'{"com_sno":14,"div_sno":14,"brn_sno":13,"dept_sno":15,"vendor_sno":1,"service_sno":<a VENDOR_BILL service_sno>,"entry_date":"2026-09-11","qty":10,"unit":1,"unit_price":50,"receipt_doc_url":"http://x/test.pdf","created_by":"system"}';
--   -- then approve it: EXEC dbo.sp_nt_ApproveServiceVendorDailyEntry @jsonInput = N'{"entry_sno":<id>,"action":"Approve","approved_by":"KTM1148"}';
-- ============================================================
