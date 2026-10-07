-- 117: supplier invoice can be uploaded at rate-entry time (Unfixed cycle, before the PO exists).
-- The invoice then hangs off the cycle (po_basic_sno NULL until the PO is raised; the Get proc
-- resolves it through the cycle). Re-runnable.

ALTER TABLE dbo.service_po_invoice ALTER COLUMN po_basic_sno INT NULL;
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_service_po_invoice_po_no' AND object_id = OBJECT_ID('dbo.service_po_invoice'))
    DROP INDEX UX_service_po_invoice_po_no ON dbo.service_po_invoice;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_service_po_invoice_cycle_po_no' AND object_id = OBJECT_ID('dbo.service_po_invoice'))
    CREATE UNIQUE INDEX UX_service_po_invoice_cycle_po_no ON dbo.service_po_invoice (cycle_sno, po_basic_sno, invoice_no) WHERE is_active = 'Y';
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_AttachServicePoEntryInvoice
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @cycle_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.cycle_sno') AS INT),
            @invoice_no NVARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.invoice_no'))), ''),
            @invoice_date DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_date') AS DATE),
            @invoice_amount DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_amount') AS DECIMAL(18,2)),
            @doc_url NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.invoice_doc_url'))), ''),
            @remarks NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.remarks'))), ''),
            @uploaded_by VARCHAR(50) = JSON_VALUE(@jsonInput, '$.uploaded_by'),
            @agreement_sno INT, @vendor_sno INT;

    IF @cycle_sno IS NULL THROW 58321, 'cycle_sno is required', 1;
    IF @invoice_no IS NULL THROW 58312, 'Invoice number is required', 1;
    IF @invoice_date IS NULL THROW 58313, 'A valid invoice date is required', 1;
    IF @invoice_date > CAST(GETDATE() AS DATE) THROW 58314, 'Invoice date cannot be in the future', 1;
    IF @invoice_amount IS NULL OR @invoice_amount <= 0 THROW 58315, 'Invoice amount must be greater than zero', 1;
    IF @doc_url IS NULL THROW 58316, 'The invoice file is required', 1;
    IF @uploaded_by IS NULL THROW 58317, 'uploaded_by is required', 1;

    SELECT @agreement_sno = agreement_sno FROM dbo.service_po_cycle WHERE cycle_sno = @cycle_sno;
    IF @agreement_sno IS NULL THROW 58322, 'Service PO cycle not found', 1;

    -- single-supplier agreement: the supplier is known; a split cycle's invoice is not tied to one
    IF (SELECT COUNT(*) FROM dbo.service_agreement_vendor WHERE agreement_sno = @agreement_sno) = 1
        SELECT @vendor_sno = vendor_sno FROM dbo.service_agreement_vendor WHERE agreement_sno = @agreement_sno;

    IF EXISTS (SELECT 1 FROM dbo.service_po_invoice WHERE cycle_sno = @cycle_sno AND po_basic_sno IS NULL AND invoice_no = @invoice_no AND is_active = 'Y')
        THROW 58319, 'This invoice number is already uploaded for this cycle', 1;

    INSERT dbo.service_po_invoice (po_basic_sno, cycle_sno, agreement_sno, vendor_sno, invoice_no, invoice_date, invoice_amount, invoice_doc_url, remarks, uploaded_by)
    VALUES (NULL, @cycle_sno, @agreement_sno, @vendor_sno, @invoice_no, @invoice_date, @invoice_amount, @doc_url, @remarks, @uploaded_by);

    SELECT SCOPE_IDENTITY() AS invoice_sno, @cycle_sno AS cycle_sno;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetServicePoInvoices
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @po_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT),
            @cycle_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.cycle_sno') AS INT);
    SELECT i.invoice_sno, i.po_basic_sno, po.po_df_no AS po_no, i.cycle_sno, i.agreement_sno, i.vendor_sno,
           k.company_name AS vendor_name, i.invoice_no, i.invoice_date, i.invoice_amount, i.invoice_doc_url,
           i.remarks, i.uploaded_by, i.uploaded_at
    FROM dbo.service_po_invoice i
    LEFT JOIN dbo.service_po_cycle c ON c.cycle_sno = i.cycle_sno
    -- entry-time invoices have no PO yet: show the cycle's PO once it is raised (single-PO cycles)
    LEFT JOIN dbo.po_request_info po ON po.po_basic_sno = COALESCE(i.po_basic_sno, c.po_basic_sno)
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    WHERE i.is_active = 'Y'
      AND (@po_basic_sno IS NULL OR i.po_basic_sno = @po_basic_sno)
      AND (@cycle_sno IS NULL OR i.cycle_sno = @cycle_sno)
    ORDER BY i.uploaded_at DESC, i.invoice_sno DESC;
END
GO
