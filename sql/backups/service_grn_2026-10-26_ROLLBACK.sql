-- ============================================================
-- ROLLBACK for sql/140 (Service GRN by department -> approval -> Payment).  Non_trade_Dev ONLY.
--   * restores sql/133's ungated sp_nt_SyncServicePoInvoicesToPayables (invoices post to Payment without a GRN again)
--   * removes the Service GRN screen + grants, the 'ServiceGRN' workflows and entity
--   * drops the 4 Service GRN procedures and (DESTRUCTIVE) service_grn / service_grn_history with every GRN filed so far.
--     Bills already posted to Payment stay (invoice_info / invoice_allocation_details are not touched).
-- ============================================================
-- restore sql/133 sync ─────────────────
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


GO
-- grants + screen
DECLARE @sid INT = (SELECT TOP 1 screen_id FROM dbo.screens WHERE comp = 'ServiceGrnPage');
IF @sid IS NOT NULL
BEGIN
    UPDATE p SET screens_json = (
        SELECT j.screen_id, JSON_QUERY(j.permissions) AS permissions
        FROM OPENJSON(p.screens_json) WITH (screen_id INT '$.screen_id', permissions NVARCHAR(MAX) '$.permissions' AS JSON) j
        WHERE j.screen_id <> @sid FOR JSON PATH)
    FROM dbo.nt_user_permissions_json p
    WHERE p.is_active = 'Y' AND EXISTS (SELECT 1 FROM OPENJSON(p.screens_json) WITH (screen_id INT '$.screen_id') x WHERE x.screen_id = @sid);
    UPDATE dbo.nt_user_permissions_json SET screens_json = '[]' WHERE screens_json IS NULL;
    DELETE FROM dbo.screens WHERE screen_id = @sid;
END
GO
-- workflows + entity
DELETE ws FROM dbo.workflow_stage ws JOIN dbo.workflow_types wt ON wt.workflow_types_id = ws.workflow_types_id
JOIN dbo.approval_workflow_master m ON m.workflow_id = wt.workflow_id AND m.entity_type = 'ServiceGRN';
DELETE wt FROM dbo.workflow_types wt JOIN dbo.approval_workflow_master m ON m.workflow_id = wt.workflow_id AND m.entity_type = 'ServiceGRN';
DELETE FROM dbo.approval_workflow_master WHERE entity_type = 'ServiceGRN';
DELETE FROM dbo.entity_master WHERE entity_code = 'ServiceGRN';
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_GetPendingServiceGrnPOs;
DROP PROCEDURE IF EXISTS dbo.sp_nt_CreateServiceGrn;
DROP PROCEDURE IF EXISTS dbo.sp_nt_ApproveServiceGrn;
DROP PROCEDURE IF EXISTS dbo.sp_nt_GetServiceGrns;
DROP TABLE IF EXISTS dbo.service_grn_history;
DROP TABLE IF EXISTS dbo.service_grn;
GO
