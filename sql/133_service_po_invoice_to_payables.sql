-- ============================================================
-- 133: Service PO supplier invoices -> Payment screen (Non_trade_Dev ONLY)
--
-- Problem: a supplier invoice uploaded against a Service PO lived only in dbo.service_po_invoice
-- (sql/116, 117). The Payment screen lists dbo.invoice_allocation_details rows (sp_nt_GetPayableBillsNet),
-- which only sp_nt_CreateInvoice -> sp_nt_AllocateInvoice -> sp_nt_MatchInvoiceBucket ever created, so a
-- Service PO bill never became payable.
--
-- Fix: sp_nt_SyncServicePoInvoicesToPayables turns each service_po_invoice whose PO is raised into
--   invoice_info (invoice_type SERVICE, Matched) + invoice_allocation_details (bucket SERVICE, release = full
--   invoice amount, hold 0: the Service PO is already approved and the bill is the supplier's claim against it).
--   One bill per invoice; a multi-item PO is split across its items pro-rata to net_cost.
--   Entry-time invoices (po_basic_sno NULL, sql/117) are picked up once their cycle has raised its PO.
-- Idempotent: service_po_invoice.payable_invoice_sno marks what is already posted.
-- Called from sp_nt_GetPayableBillsNet (so the list is always current) and after an invoice upload.
-- Re-runnable.
-- ============================================================

IF COL_LENGTH('dbo.service_po_invoice', 'payable_invoice_sno') IS NULL
    ALTER TABLE dbo.service_po_invoice ADD payable_invoice_sno INT NULL;
GO

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

-- Payment screen list: same as sql/48 (grn-service) plus a sync of any unposted Service PO invoices first.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPayableBillsNet
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);

    BEGIN TRY
        EXEC dbo.sp_nt_SyncServicePoInvoicesToPayables;
    END TRY
    BEGIN CATCH
        -- a sync problem must never take the whole Payment list down
    END CATCH

    SELECT
        iad.invoice_alloc_sno AS bill_sno, i.invoice_sno, i.invoice_no AS bill_no, i.vendor_invoice_no AS supplier_invoice_no,
        p.po_df_no AS po_no, i.vendor_sno, k.company_name AS vendor_name, i.invoice_date, i.due_date, iad.bucket_type,
        iad.allocated_amount, iad.hold_amount, iad.release_amount AS net_payable,
        ISNULL(paid.paidSoFar, 0) AS paid_amount, iad.release_amount - ISNULL(paid.paidSoFar, 0) AS outstanding,
        i.invoice_amount, i.taxable_value, i.tds_section_code, i.itc_status, i.payment_hold_override,
        CAST(CASE WHEN LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 THEN 1 ELSE 0 END AS BIT) AS gst_supplier,
        CAST(CASE WHEN i.gst_journal_sno IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS gst_booked,
        CASE WHEN iad.bucket_type = 'SERVICE' THEN 'NA'
             WHEN EXISTS (SELECT 1 FROM dbo.grn_basic_info g WHERE g.po_basic_sno = i.po_basic_sno AND g.is_active = 'Y' AND g.status IN ('Approved', 'Received')) THEN 'Done'
             WHEN EXISTS (SELECT 1 FROM dbo.grn_basic_info g WHERE g.po_basic_sno = i.po_basic_sno AND g.is_active = 'Y' AND g.status = 'Pending Approval') THEN 'Pending approval'
             ELSE 'No GRN' END AS grn_state,
        CAST(CASE WHEN LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 AND ISNULL(i.itc_status, '') NOT IN ('Eligible', 'Ineligible')
                       AND ISNULL(i.payment_hold_override, 'N') <> 'Y' THEN 1 ELSE 0 END AS BIT) AS on_hold_2b
    FROM dbo.invoice_allocation_details iad
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    OUTER APPLY (SELECT ISNULL(SUM(pad.amount), 0) AS paidSoFar FROM dbo.payment_allocation_details pad WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno) paid
    WHERE iad.is_active = 'Y' AND iad.release_amount > ISNULL(paid.paidSoFar, 0) + 0.01
      AND (@vendor_sno IS NULL OR i.vendor_sno = @vendor_sno)
    ORDER BY i.invoice_date, iad.invoice_alloc_sno;
END
GO
