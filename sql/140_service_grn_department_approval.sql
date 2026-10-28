-- ============================================================
-- 140: Service GRN by department -> approval -> Payment   (Non_trade_Dev ONLY, re-runnable)
--
-- Request 2026-10-26: "GRN for services by their department, under which department, and after approval it comes to payment."
--
-- Flow (Fixed AND Unfixed service POs alike):
--   Service PO raised (cycle GENERATED)  ->  the PO's department files a Service GRN (service received)
--   ->  the department's ServiceGRN approval workflow approves it (stage by stage, reject = re-file)
--   ->  only then does the supplier's invoice become a payable bill on the Payment screen.
--
-- What changes:
--   * dbo.service_grn / service_grn_history      NEW (sql/81's version was never applied on Dev; this one carries org + dept,
--                                                status, workflow, current approver). No invoice on the GRN: the supplier
--                                                invoice keeps coming in through the Service PO screen (service_po_invoice).
--   * sp_nt_GetPendingServiceGrnPOs              generated Service POs with no live GRN, scoped to the user's org hierarchy
--   * sp_nt_CreateServiceGrn                     files the GRN against the PO's own com/div/brn/dept, resolves that
--                                                department's 'ServiceGRN' workflow (THROWS if none), first approver
--   * sp_nt_ApproveServiceGrn                    current approver only; approve -> next stage or Approved, reject -> Rejected
--   * sp_nt_GetServiceGrns                       GRN list (org-scoped) + can_act for the approver
--   * sp_nt_SyncServicePoInvoicesToPayables      sql/133's sync, now GATED: a Service PO invoice is posted to the Payment
--                                                list only when its PO has an Approved Service GRN. Already-posted invoices
--                                                (payable_invoice_sno set) are untouched.
--   * entity_master 'ServiceGRN' + a starter workflow per department (provisional: the SAME approver as that department's
--     Service PO workflow, one stage) - change it on the Approval Workflows screen, no SQL needed.
--   * screens: 'Service GRN' (ServiceGrnPage) under the Service group, granted to everyone who has Service PO / Service PO Approvals.
--
-- Rollback: sql/backups/service_grn_2026-10-26_ROLLBACK.sql
-- ============================================================

-- ── 1. tables ───────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.service_grn', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_grn (
        grn_sno              INT IDENTITY(1,1) PRIMARY KEY,
        grn_no               VARCHAR(30)  NOT NULL,
        po_basic_sno         INT          NOT NULL,
        cycle_sno            INT          NULL,
        agreement_sno        INT          NOT NULL,
        vendor_sno           INT          NULL,
        com_sno              INT          NULL,
        div_sno              INT          NULL,
        brn_sno              INT          NULL,
        dept_sno             INT          NULL,
        received_date        DATE         NOT NULL,
        remarks              NVARCHAR(500) NULL,
        status               VARCHAR(20)  NOT NULL CONSTRAINT DF_service_grn_status DEFAULT 'Pending Approval',
        workflow_types_id    INT          NULL,
        stage_idx            INT          NOT NULL CONSTRAINT DF_service_grn_stage DEFAULT 0,
        current_approver_id  VARCHAR(30)  NULL,
        entered_by           VARCHAR(30)  NOT NULL,
        approved_by          VARCHAR(30)  NULL,
        approved_at          DATETIME     NULL,
        created_at           DATETIME     NOT NULL CONSTRAINT DF_service_grn_created DEFAULT GETDATE(),
        CONSTRAINT UQ_service_grn_no UNIQUE (grn_no),
        CONSTRAINT CK_service_grn_status CHECK (status IN ('Pending Approval', 'Approved', 'Rejected'))
    );
    -- one LIVE GRN per PO; a Rejected one is replaced by filing again
    CREATE UNIQUE INDEX UX_service_grn_po_live ON dbo.service_grn (po_basic_sno) WHERE status IN ('Pending Approval', 'Approved');
    CREATE INDEX IX_service_grn_approver ON dbo.service_grn (current_approver_id) WHERE status = 'Pending Approval';
END
GO

IF OBJECT_ID('dbo.service_grn_history', 'U') IS NULL
    CREATE TABLE dbo.service_grn_history (
        history_sno INT IDENTITY(1,1) PRIMARY KEY,
        grn_sno     INT          NOT NULL,
        action_type VARCHAR(20)  NOT NULL,
        status_by   VARCHAR(30)  NULL,
        comment     NVARCHAR(500) NULL,
        created_at  DATETIME     NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_service_grn_history_grn FOREIGN KEY (grn_sno) REFERENCES dbo.service_grn (grn_sno)
    );
GO

-- ── 2. generated Service POs still waiting for a GRN ────────────────────────
-- @jsonInput: { hierarchy: [{com_sno,div_sno,brn_sno}] }  (absent = no filter; the API always sends it, [] = nothing)
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPendingServiceGrnPOs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @h NVARCHAR(MAX) = CASE WHEN ISJSON(@jsonInput) = 1 THEN JSON_QUERY(@jsonInput, '$.hierarchy') END;

    ;WITH cpo AS (
        SELECT c.cycle_sno, v.po_basic_sno, v.vendor_sno
        FROM dbo.service_po_cycle c
        JOIN dbo.service_po_cycle_vendor v ON v.cycle_sno = c.cycle_sno AND v.po_basic_sno IS NOT NULL
        WHERE c.status = 'GENERATED'
        UNION ALL
        SELECT c.cycle_sno, c.po_basic_sno, CAST(NULL AS INT)
        FROM dbo.service_po_cycle c
        WHERE c.status = 'GENERATED' AND c.po_basic_sno IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dbo.service_po_cycle_vendor v WHERE v.cycle_sno = c.cycle_sno AND v.po_basic_sno = c.po_basic_sno)
    )
    SELECT po.po_basic_sno, po.po_df_no AS po_no, po.po_date, po.com_sno, po.div_sno, po.brn_sno, po.dept_sno, d.dept_name,
           cpo.cycle_sno, sa.agreement_sno, sa.agreement_no, sm.service_name, st.service_type_code,
           COALESCE(cpo.vendor_sno, po.vendor_sno, sa.vendor_sno) AS vendor_sno, k.company_name AS vendor_name,
           ISNULL(it.net_cost, 0) AS net_cost,
           (SELECT COUNT(*) FROM dbo.service_po_invoice i WHERE i.is_active = 'Y' AND (i.po_basic_sno = po.po_basic_sno OR (i.po_basic_sno IS NULL AND i.cycle_sno = cpo.cycle_sno))) AS invoice_count
    FROM cpo
    JOIN dbo.po_request_info po ON po.po_basic_sno = cpo.po_basic_sno
    JOIN dbo.service_po_cycle c ON c.cycle_sno = cpo.cycle_sno
    JOIN dbo.service_agreement sa ON sa.agreement_sno = c.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.dept_master d ON d.dept_sno = po.dept_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = COALESCE(cpo.vendor_sno, po.vendor_sno, sa.vendor_sno)
    OUTER APPLY (SELECT SUM(ISNULL(pid.net_cost, 0)) AS net_cost FROM dbo.po_item_details pid WHERE pid.po_basic_sno = po.po_basic_sno AND pid.is_active IN ('1', 'Y')) it
    WHERE NOT EXISTS (SELECT 1 FROM dbo.service_grn g WHERE g.po_basic_sno = po.po_basic_sno AND g.status IN ('Pending Approval', 'Approved'))
      AND (@h IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@h) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') x
                                 WHERE x.com_sno = po.com_sno
                                   AND (x.div_sno IS NULL OR x.div_sno = po.div_sno)
                                   AND (x.brn_sno IS NULL OR x.brn_sno = po.brn_sno)))
    ORDER BY po.po_basic_sno DESC;
END
GO

-- ── 3. file the GRN ─────────────────────────────────────────────────────────
-- @jsonInput: { po_basic_sno, received_date, remarks, entered_by }
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateServiceGrn
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END, @sp BIT = 0;   -- own the transaction only when the caller has none
    BEGIN TRY
        DECLARE @po INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT),
                @received DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.received_date') AS DATE),
                @remarks NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks'),
                @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.entered_by');

        IF @po IS NULL OR @by IS NULL THROW 58301, 'po_basic_sno and entered_by are required.', 1;
        IF @received IS NULL THROW 58304, 'received_date is required.', 1;
        IF @received > CAST(GETDATE() AS DATE) THROW 58308, 'The received date cannot be in the future.', 1;

        DECLARE @cycle INT, @agreement INT, @vendor INT, @com INT, @div INT, @brn INT, @dept INT;
        SELECT @com = com_sno, @div = div_sno, @brn = brn_sno, @dept = dept_sno, @vendor = vendor_sno
        FROM dbo.po_request_info WHERE po_basic_sno = @po;
        IF @@ROWCOUNT = 0 THROW 58305, 'PO not found.', 1;

        SELECT TOP 1 @cycle = c.cycle_sno, @agreement = c.agreement_sno
        FROM dbo.service_po_cycle c
        WHERE c.status = 'GENERATED'
          AND (c.po_basic_sno = @po OR EXISTS (SELECT 1 FROM dbo.service_po_cycle_vendor v WHERE v.cycle_sno = c.cycle_sno AND v.po_basic_sno = @po))
        ORDER BY c.cycle_sno DESC;
        IF @cycle IS NULL THROW 58305, 'This PO is not an issued Service Agreement PO.', 1;

        IF @vendor IS NULL
            SELECT @vendor = COALESCE((SELECT TOP 1 v.vendor_sno FROM dbo.service_po_cycle_vendor v WHERE v.cycle_sno = @cycle AND v.po_basic_sno = @po),
                                      (SELECT sa.vendor_sno FROM dbo.service_agreement sa WHERE sa.agreement_sno = @agreement));

        IF @dept IS NULL THROW 58309, 'This PO has no department; a Service GRN is filed under the PO''s department.', 1;

        -- the PO's department workflow: first approver of stage 1
        DECLARE @wf INT, @first VARCHAR(30);
        SELECT TOP 1 @wf = wt.workflow_types_id
        FROM dbo.workflow_types wt
        JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id AND awm.is_active = 'Y'
        WHERE wt.is_active = 'Y' AND awm.entity_type = 'ServiceGRN'
          AND wt.com_sno = @com AND wt.div_sno = @div AND wt.brn_sno = @brn AND wt.dept_sno = @dept
        ORDER BY wt.workflow_types_id DESC;
        IF @wf IS NOT NULL
            SELECT TOP 1 @first = JSON_VALUE(j.[value], '$.approver_ecno')
            FROM dbo.workflow_stage ws
            CROSS APPLY OPENJSON(ws.stage_order_json) j
            WHERE ws.workflow_types_id = @wf AND ws.is_active = 'Y'
            ORDER BY CAST(j.[key] AS INT);
        IF @wf IS NULL OR @first IS NULL
            THROW 58320, 'No Service GRN approval workflow is configured for this company/division/branch/department. Add a ''ServiceGRN'' workflow on the Approval Workflows screen first.', 1;

        IF @own = 1 BEGIN TRANSACTION; ELSE BEGIN SAVE TRANSACTION sgrn_create; SET @sp = 1; END

        IF EXISTS (SELECT 1 FROM dbo.service_grn WITH (UPDLOCK, HOLDLOCK) WHERE po_basic_sno = @po AND status IN ('Pending Approval', 'Approved'))
            THROW 58307, 'A GRN already exists for this PO.', 1;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(grn_no, 4) AS INT)), 0) + 1
        FROM dbo.service_grn WITH (UPDLOCK, HOLDLOCK) WHERE grn_no LIKE 'SGRN-' + @year + '-%';
        DECLARE @grn_no VARCHAR(30) = 'SGRN-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT dbo.service_grn (grn_no, po_basic_sno, cycle_sno, agreement_sno, vendor_sno, com_sno, div_sno, brn_sno, dept_sno,
                                received_date, remarks, status, workflow_types_id, stage_idx, current_approver_id, entered_by)
        VALUES (@grn_no, @po, @cycle, @agreement, @vendor, @com, @div, @brn, @dept,
                @received, @remarks, 'Pending Approval', @wf, 0, @first, @by);
        DECLARE @grn INT = SCOPE_IDENTITY();

        INSERT dbo.service_grn_history (grn_sno, action_type, status_by, comment)
        VALUES (@grn, 'SUBMITTED', @by, N'Filed for approval to ' + @first);

        IF @own = 1 COMMIT TRANSACTION;

        SELECT @grn AS grn_sno, @grn_no AS grn_no, @first AS current_approver_id, @dept AS dept_sno, 'SUCCESS' AS result;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        ELSE IF @sp = 1 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sgrn_create;
        THROW;
    END CATCH
END
GO

-- ── 4. approve / reject ─────────────────────────────────────────────────────
-- @jsonInput: { grn_sno, action: 'approve'|'reject', approved_by, comments }
-- result = APPROVED_NEXT | FINAL | REJECTED  (+ next_approver, entered_by, grn_no)
CREATE OR ALTER PROCEDURE dbo.sp_nt_ApproveServiceGrn
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @final BIT = 0, @sp BIT = 0, @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;   -- own the transaction only when the caller has none
    BEGIN TRY
        DECLARE @grn INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.grn_sno') AS INT),
                @action VARCHAR(10) = LOWER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.action')))),
                @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.approved_by'),
                @comments NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.comments');

        IF @grn IS NULL OR @by IS NULL THROW 58321, 'grn_sno and approved_by are required.', 1;
        IF @action IS NULL OR @action NOT IN ('approve', 'reject') THROW 58322, 'Invalid action. Must be approve or reject.', 1;
        IF @action = 'reject' AND (@comments IS NULL OR LTRIM(RTRIM(@comments)) = '') THROW 58323, 'Give a reason when rejecting.', 1;

        IF @own = 1 BEGIN TRANSACTION; ELSE BEGIN SAVE TRANSACTION sgrn_approve; SET @sp = 1; END

        DECLARE @status VARCHAR(20), @cur VARCHAR(30), @wf INT, @idx INT, @entered VARCHAR(30), @grn_no VARCHAR(30);
        SELECT @status = status, @cur = current_approver_id, @wf = workflow_types_id, @idx = stage_idx, @entered = entered_by, @grn_no = grn_no
        FROM dbo.service_grn WITH (UPDLOCK, HOLDLOCK) WHERE grn_sno = @grn;
        IF @@ROWCOUNT = 0 THROW 58324, 'Service GRN not found.', 1;
        IF @status <> 'Pending Approval' THROW 58325, 'This Service GRN is not awaiting approval.', 1;
        IF @cur IS NULL OR @cur <> @by THROW 58326, 'This Service GRN is not waiting for your approval.', 1;

        IF @action = 'reject'
        BEGIN
            UPDATE dbo.service_grn SET status = 'Rejected', current_approver_id = NULL WHERE grn_sno = @grn;
            INSERT dbo.service_grn_history (grn_sno, action_type, status_by, comment) VALUES (@grn, 'REJECTED', @by, @comments);
            IF @own = 1 COMMIT TRANSACTION;
            SELECT 'REJECTED' AS result, @grn AS grn_sno, @grn_no AS grn_no, @entered AS entered_by, CAST(NULL AS VARCHAR(30)) AS next_approver;
            RETURN;
        END

        DECLARE @next VARCHAR(30);
        SELECT TOP 1 @next = JSON_VALUE(j.[value], '$.approver_ecno')
        FROM dbo.workflow_stage ws
        CROSS APPLY OPENJSON(ws.stage_order_json) j
        WHERE ws.workflow_types_id = @wf AND ws.is_active = 'Y' AND CAST(j.[key] AS INT) > @idx
        ORDER BY CAST(j.[key] AS INT);

        INSERT dbo.service_grn_history (grn_sno, action_type, status_by, comment) VALUES (@grn, 'APPROVED', @by, @comments);

        IF @next IS NOT NULL
        BEGIN
            UPDATE dbo.service_grn
            SET current_approver_id = @next,
                stage_idx = (SELECT TOP 1 CAST(j.[key] AS INT)
                             FROM dbo.workflow_stage ws CROSS APPLY OPENJSON(ws.stage_order_json) j
                             WHERE ws.workflow_types_id = @wf AND ws.is_active = 'Y' AND CAST(j.[key] AS INT) > @idx
                             ORDER BY CAST(j.[key] AS INT))
            WHERE grn_sno = @grn;
        END
        ELSE
        BEGIN
            UPDATE dbo.service_grn SET status = 'Approved', current_approver_id = NULL, approved_by = @by, approved_at = GETDATE() WHERE grn_sno = @grn;
            SET @final = 1;
        END

        IF @own = 1 COMMIT TRANSACTION;

        -- the GRN is now approved: post this PO's waiting supplier invoices to the Payment list
        IF @final = 1
        BEGIN TRY
            EXEC dbo.sp_nt_SyncServicePoInvoicesToPayables;
        END TRY
        BEGIN CATCH
            -- never undo an approval over a sync problem; the Payment list re-runs the sync every time it loads
        END CATCH

        SELECT CASE WHEN @final = 1 THEN 'FINAL' ELSE 'APPROVED_NEXT' END AS result, @grn AS grn_sno, @grn_no AS grn_no, @entered AS entered_by, @next AS next_approver;
    END TRY
    BEGIN CATCH
        IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        ELSE IF @sp = 1 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sgrn_approve;
        THROW;
    END CATCH
END
GO

-- ── 5. the GRN list ─────────────────────────────────────────────────────────
-- @jsonInput: { hierarchy:[...], ecno }   Shows every GRN in the user's org scope, plus any waiting on this ecno.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetServiceGrns
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @h NVARCHAR(MAX) = CASE WHEN ISJSON(@jsonInput) = 1 THEN JSON_QUERY(@jsonInput, '$.hierarchy') END,
            @ecno VARCHAR(30) = CASE WHEN ISJSON(@jsonInput) = 1 THEN JSON_VALUE(@jsonInput, '$.ecno') END;

    SELECT g.grn_sno, g.grn_no, g.po_basic_sno, po.po_df_no AS po_no, g.com_sno, g.div_sno, g.brn_sno, g.dept_sno, d.dept_name,
           g.agreement_sno, sa.agreement_no, sm.service_name, st.service_type_code,
           g.vendor_sno, k.company_name AS vendor_name, ISNULL(it.net_cost, 0) AS net_cost,
           g.received_date, g.remarks, g.status, g.current_approver_id, g.entered_by, g.approved_by, g.approved_at, g.created_at,
           CAST(CASE WHEN g.status = 'Pending Approval' AND g.current_approver_id = @ecno THEN 1 ELSE 0 END AS BIT) AS can_act,
           lastc.comment AS last_comment, lastc.status_by AS last_comment_by,
           (SELECT COUNT(*) FROM dbo.service_po_invoice i WHERE i.is_active = 'Y' AND (i.po_basic_sno = g.po_basic_sno OR (i.po_basic_sno IS NULL AND i.cycle_sno = g.cycle_sno))) AS invoice_count,
           (SELECT COUNT(*) FROM dbo.service_po_invoice i WHERE i.is_active = 'Y' AND i.payable_invoice_sno IS NOT NULL AND (i.po_basic_sno = g.po_basic_sno OR (i.po_basic_sno IS NULL AND i.cycle_sno = g.cycle_sno))) AS payable_count
    FROM dbo.service_grn g
    JOIN dbo.po_request_info po ON po.po_basic_sno = g.po_basic_sno
    JOIN dbo.service_agreement sa ON sa.agreement_sno = g.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.dept_master d ON d.dept_sno = g.dept_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = g.vendor_sno
    OUTER APPLY (SELECT SUM(ISNULL(pid.net_cost, 0)) AS net_cost FROM dbo.po_item_details pid WHERE pid.po_basic_sno = g.po_basic_sno AND pid.is_active IN ('1', 'Y')) it
    OUTER APPLY (SELECT TOP 1 hh.comment, hh.status_by FROM dbo.service_grn_history hh WHERE hh.grn_sno = g.grn_sno AND hh.action_type IN ('APPROVED', 'REJECTED') AND hh.comment IS NOT NULL ORDER BY hh.history_sno DESC) lastc
    WHERE (@h IS NULL OR (g.current_approver_id = @ecno AND g.status = 'Pending Approval')
           OR EXISTS (SELECT 1 FROM OPENJSON(@h) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') x
                      WHERE x.com_sno = g.com_sno
                        AND (x.div_sno IS NULL OR x.div_sno = g.div_sno)
                        AND (x.brn_sno IS NULL OR x.brn_sno = g.brn_sno)))
    ORDER BY CASE WHEN g.status = 'Pending Approval' THEN 0 ELSE 1 END, g.grn_sno DESC;
END
GO

-- ── 6. gate the Payment hand-off on an Approved Service GRN ─────────────────
-- Identical to sql/133 except the one marked predicate. A Service PO invoice is posted to the Payment list only once its PO
-- has an Approved Service GRN; invoices uploaded earlier simply wait (payable_invoice_sno stays NULL) and are picked up by the
-- next sync, which sp_nt_ApproveServiceGrn runs on final approval and the Payment list runs on every load.
CREATE OR ALTER PROCEDURE dbo.sp_nt_SyncServicePoInvoicesToPayables
    @jsonInput NVARCHAR(MAX) = NULL   -- optional { invoice_sno } to post a single service invoice
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @only INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_sno') AS INT);

    DECLARE @cand TABLE (
        svc_invoice_sno INT PRIMARY KEY, po_basic_sno INT, vendor_sno INT, vendor_invoice_no VARCHAR(50),
        invoice_date DATE, invoice_amount DECIMAL(18,2), doc_url NVARCHAR(500), remarks VARCHAR(500), uploaded_by VARCHAR(20),
        com_sno INT, div_sno INT, brn_sno INT, dept_sno INT);

    INSERT @cand
    SELECT si.invoice_sno, r.po_basic_sno, COALESCE(si.vendor_sno, po.vendor_sno), LEFT(si.invoice_no, 50),
           si.invoice_date, si.invoice_amount, si.invoice_doc_url, LEFT(si.remarks, 500), LEFT(si.uploaded_by, 20),
           po.com_sno, po.div_sno, po.brn_sno, po.dept_sno
    FROM dbo.service_po_invoice si
    JOIN dbo.service_po_cycle c ON c.cycle_sno = si.cycle_sno AND c.status = 'GENERATED'
    OUTER APPLY (
        -- the cycle's PO for this supplier when there is exactly one; else the cycle's single PO
        SELECT TOP 1 x.po_basic_sno
        FROM dbo.service_po_cycle_vendor x
        WHERE x.cycle_sno = si.cycle_sno AND x.po_basic_sno IS NOT NULL
          AND (si.vendor_sno IS NULL OR x.vendor_sno = si.vendor_sno)
          AND (SELECT COUNT(*) FROM dbo.service_po_cycle_vendor y
               WHERE y.cycle_sno = si.cycle_sno AND y.po_basic_sno IS NOT NULL
                 AND (si.vendor_sno IS NULL OR y.vendor_sno = si.vendor_sno)) = 1
    ) cvm
    CROSS APPLY (SELECT po_basic_sno = COALESCE(si.po_basic_sno, cvm.po_basic_sno, c.po_basic_sno)) r
    JOIN dbo.po_request_info po ON po.po_basic_sno = r.po_basic_sno
    WHERE si.is_active = 'Y' AND si.payable_invoice_sno IS NULL
      AND (@only IS NULL OR si.invoice_sno = @only)
      -- sql/140 GATE: the PO's Service GRN must be approved
      AND EXISTS (SELECT 1 FROM dbo.service_grn g WHERE g.po_basic_sno = r.po_basic_sno AND g.status = 'Approved')
      -- a split cycle whose supplier can't be told apart can't be attributed to one PO
      AND (si.po_basic_sno IS NOT NULL OR cvm.po_basic_sno IS NOT NULL
           OR (SELECT COUNT(*) FROM dbo.service_po_cycle_vendor z WHERE z.cycle_sno = si.cycle_sno) <= 1);

    IF NOT EXISTS (SELECT 1 FROM @cand) RETURN;

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC sp_getapplock @Resource = 'sync_service_po_invoices', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;

        DECLARE @svc INT, @po INT, @vendor INT, @vno VARCHAR(50), @idate DATE, @amt DECIMAL(18,2), @url NVARCHAR(500),
                @rem VARCHAR(500), @by VARCHAR(20), @com INT, @div INT, @brn INT, @dept INT,
                @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT, @invno VARCHAR(30), @inv INT;

        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT svc_invoice_sno, po_basic_sno, vendor_sno, vendor_invoice_no, invoice_date, invoice_amount, doc_url, remarks, uploaded_by, com_sno, div_sno, brn_sno, dept_sno
            FROM @cand ORDER BY svc_invoice_sno;
        OPEN cur;
        FETCH NEXT FROM cur INTO @svc, @po, @vendor, @vno, @idate, @amt, @url, @rem, @by, @com, @div, @brn, @dept;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- skip a PO with no line to allocate against (nothing to pay it to)
            IF EXISTS (SELECT 1 FROM dbo.po_item_details WHERE po_basic_sno = @po AND is_active IN ('1', 'Y'))
            BEGIN
                SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(invoice_no, 6) AS INT)), 0) + 1
                FROM dbo.invoice_info WITH (UPDLOCK, HOLDLOCK) WHERE invoice_no LIKE 'INV-' + @year + '-%';
                SET @invno = 'INV-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);

                INSERT dbo.invoice_info (invoice_no, vendor_invoice_no, vendor_sno, po_basic_sno, com_sno, div_sno, brn_sno, dept_sno,
                                         invoice_date, invoice_amount, invoice_file_url, invoice_type, source_type, match_status,
                                         net_payable, remarks, is_active, created_by, created_date)
                VALUES (@invno, @vno, @vendor, @po, @com, @div, @brn, @dept, @idate, @amt, @url, 'SERVICE', 'STANDARD', 'Matched',
                        @amt, @rem, 'Y', @by, GETDATE());
                SET @inv = SCOPE_IDENTITY();

                -- split across the PO's lines pro-rata to net_cost; rounding lands on the first line
                DECLARE @lines TABLE (po_item_sno INT PRIMARY KEY, share DECIMAL(18,2));
                DELETE @lines;
                DECLARE @tot DECIMAL(18,2) = (SELECT SUM(ISNULL(net_cost, 0)) FROM dbo.po_item_details WHERE po_basic_sno = @po AND is_active IN ('1', 'Y'));
                DECLARE @n INT = (SELECT COUNT(*) FROM dbo.po_item_details WHERE po_basic_sno = @po AND is_active IN ('1', 'Y'));
                INSERT @lines
                SELECT po_item_sno, ROUND(CASE WHEN @tot > 0 THEN @amt * ISNULL(net_cost, 0) / @tot ELSE @amt / @n END, 2)
                FROM dbo.po_item_details WHERE po_basic_sno = @po AND is_active IN ('1', 'Y');
                UPDATE @lines SET share = share + (@amt - (SELECT SUM(share) FROM @lines)) WHERE po_item_sno = (SELECT MIN(po_item_sno) FROM @lines);

                INSERT dbo.invoice_allocation_details (invoice_sno, po_item_sno, bucket_type, allocated_amount, matched_qty_ratio,
                                                       hold_amount, release_amount, match_status, created_by, created_date, is_active)
                SELECT @inv, po_item_sno, 'SERVICE', share, 1, 0, share, 'Matched', @by, GETDATE(), 'Y' FROM @lines;

                UPDATE dbo.service_po_invoice SET payable_invoice_sno = @inv WHERE invoice_sno = @svc;
            END
            FETCH NEXT FROM cur INTO @svc, @po, @vendor, @vno, @idate, @amt, @url, @rem, @by, @com, @div, @brn, @dept;
        END
        CLOSE cur; DEALLOCATE cur;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ── 7. approval entity + starter workflows ──────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.entity_master WHERE entity_code = 'ServiceGRN')
    INSERT dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by)
    VALUES (N'Service GRN', 'ServiceGRN', N'Department approval that a Service PO''s service was received; releases the supplier invoice to Payment', 'Y', 'system');
GO

-- One single-stage ServiceGRN workflow per department that already has a Service PO workflow, approver = that workflow's
-- first-stage approver. PROVISIONAL - edit on the Approval Workflows screen (add stages, change approver).
DECLARE @stages_tpl NVARCHAR(MAX) = N'[{"approver_ecno":"%A%","stage":"Service GRN Approval","required_approvals":"1","is_mandatory":"Y","escalation_hours":"24","approver_condition":"","next_approver_ecno":"0","can_forward":"N","can_backward":"N","can_edit_data":"N"}]';

DECLARE @scopes TABLE (workflow_types_name NVARCHAR(200), workflow_types_description NVARCHAR(500), brn_sno INT, dept_sno INT, com_sno INT, div_sno INT, is_active CHAR(1), stage_order_json NVARCHAR(MAX));

;WITH src AS (
    SELECT wt.com_sno, wt.div_sno, wt.brn_sno, wt.dept_sno, wt.workflow_types_id,
           (SELECT TOP 1 JSON_VALUE(j.[value], '$.approver_ecno')
            FROM dbo.workflow_stage ws CROSS APPLY OPENJSON(ws.stage_order_json) j
            WHERE ws.workflow_types_id = wt.workflow_types_id AND ws.is_active = 'Y' AND ISJSON(ws.stage_order_json) = 1
            ORDER BY CAST(j.[key] AS INT)) AS approver,
           ROW_NUMBER() OVER (PARTITION BY wt.com_sno, wt.div_sno, wt.brn_sno, wt.dept_sno ORDER BY wt.workflow_types_id DESC) AS rn
    FROM dbo.workflow_types wt
    JOIN dbo.approval_workflow_master m ON m.workflow_id = wt.workflow_id AND m.is_active = 'Y'
    WHERE wt.is_active = 'Y' AND m.entity_type IN ('ServicePO', 'ServicePO_FIXED_RECURRING', 'ServicePO_VARIABLE_RECURRING')
)
INSERT @scopes
SELECT N'Service GRN Approval', N'Department approval of a received service (starter: same approver as the Service PO workflow)',
       s.brn_sno, s.dept_sno, s.com_sno, s.div_sno, 'Y', REPLACE(@stages_tpl, '%A%', s.approver)
FROM src s
WHERE s.rn = 1 AND s.approver IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.workflow_types p
                  JOIN dbo.approval_workflow_master pm ON pm.workflow_id = p.workflow_id AND pm.entity_type = 'ServiceGRN' AND pm.is_active = 'Y'
                  WHERE p.is_active = 'Y' AND p.com_sno = s.com_sno AND p.div_sno = s.div_sno AND p.brn_sno = s.brn_sno AND p.dept_sno = s.dept_sno);

IF EXISTS (SELECT 1 FROM @scopes)
BEGIN
    DECLARE @json NVARCHAR(MAX) = (
        SELECT N'Service GRN Approval Workflow' AS workflow_name, 'ServiceGRN' AS entity_type,
               N'Department approval that a Service PO''s service was received. Starter: the Service PO approver of each department.' AS description,
               'Y' AS is_active, 'system' AS created_by,
               (SELECT workflow_types_name, workflow_types_description, brn_sno, dept_sno, com_sno, div_sno, is_active, stage_order_json FROM @scopes FOR JSON PATH) AS workflow_types
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC dbo.sp_nt_SaveFullWorkflow @jsonInput = @json;
END
ELSE
    PRINT 'No department needed a ServiceGRN workflow.';
GO

-- ── 8. screen + access ──────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'ServiceGrnPage')
    INSERT dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Service GRN', N'S22', 'ServiceGrnPage', N'PackageCheck', 9, 29, 'Y');
GO

-- everyone who can open Service Purchase Orders (62) or Service PO Approvals (63): View, Edit (file), Approve, Reject.
-- Approving is still enforced per GRN by sp_nt_ApproveServiceGrn (current approver only).
DECLARE @sid INT = (SELECT TOP 1 screen_id FROM dbo.screens WHERE comp = 'ServiceGrnPage');
DECLARE @who TABLE (ecno VARCHAR(50), login_id VARCHAR(50));
INSERT @who
SELECT DISTINCT p.ecno, p.login_id
FROM dbo.nt_user_permissions_json p
CROSS APPLY OPENJSON(p.screens_json) WITH (screen_id INT '$.screen_id') j
WHERE p.is_active = 'Y' AND j.screen_id IN (62, 63);

DECLARE @e VARCHAR(50), @l VARCHAR(50);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT ecno, login_id FROM @who;
OPEN c; FETCH NEXT FROM c INTO @e, @l;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF @e IS NOT NULL
    BEGIN
        DECLARE @gj NVARCHAR(MAX) = (SELECT @e AS ecno, @sid AS screen_id, JSON_QUERY('[2,4,7,8]') AS permission_ids FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @gj;
    END
    ELSE IF @l IS NOT NULL
    BEGIN
        -- non-staff users are keyed by login_id, which sp_nt_GrantScreenToUser does not match (same as sql/67)
        DECLARE @row INT, @sj NVARCHAR(MAX);
        SELECT TOP 1 @row = user_perm_json_sno, @sj = RTRIM(screens_json)
        FROM dbo.nt_user_permissions_json WHERE login_id = @l AND is_active = 'Y' ORDER BY user_perm_json_sno DESC;
        IF @row IS NOT NULL AND NOT EXISTS (SELECT 1 FROM OPENJSON(@sj) WITH (screen_id INT '$.screen_id') WHERE screen_id = @sid)
        BEGIN
            DECLARE @entry NVARCHAR(MAX) = (SELECT @sid AS screen_id, JSON_QUERY('[2,4,7,8]') AS permissions FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            UPDATE dbo.nt_user_permissions_json
            SET screens_json = CASE WHEN @sj IS NULL OR @sj IN ('[]', '') THEN '[' + @entry + ']' ELSE LEFT(@sj, LEN(@sj) - 1) + ',' + @entry + ']' END,
                updated_date = GETDATE()
            WHERE user_perm_json_sno = @row;
        END
    END
    FETCH NEXT FROM c INTO @e, @l;
END
CLOSE c; DEALLOCATE c;
GO

SELECT m.entity_type, wt.workflow_types_id, wt.workflow_types_name, wt.com_sno, wt.div_sno, wt.brn_sno, wt.dept_sno
FROM dbo.workflow_types wt JOIN dbo.approval_workflow_master m ON m.workflow_id = wt.workflow_id
WHERE m.entity_type = 'ServiceGRN' ORDER BY wt.workflow_types_id;
GO
