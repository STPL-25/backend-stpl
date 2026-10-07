-- 116: Signed service-agreement copy + supplier invoice per approved Service PO.
--
--  * service_agreement_signed_doc : signed/scanned copy uploaded after an agreement is Approved
--                                   (several uploads kept, newest is "current").
--  * service_po_invoice           : supplier invoice (no, date, amount, file) against a PO raised
--                                   by a GENERATED service PO cycle. One PO may carry several invoices.
-- Existing list procs are untouched; the Node layer merges these in via the Get procs below.
-- Re-runnable.

IF OBJECT_ID('dbo.service_agreement_signed_doc', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_agreement_signed_doc (
        signed_doc_sno INT IDENTITY(1,1) PRIMARY KEY,
        agreement_sno  INT NOT NULL,
        version_no     INT NULL,
        doc_url        NVARCHAR(500) NOT NULL,
        remarks        NVARCHAR(500) NULL,
        uploaded_by    VARCHAR(50) NOT NULL,
        uploaded_at    DATETIME NOT NULL DEFAULT GETDATE(),
        is_active      CHAR(1) NOT NULL DEFAULT 'Y'
    );
    CREATE INDEX IX_service_agreement_signed_doc_agreement ON dbo.service_agreement_signed_doc (agreement_sno);
END
GO

IF OBJECT_ID('dbo.service_po_invoice', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_po_invoice (
        invoice_sno    INT IDENTITY(1,1) PRIMARY KEY,
        po_basic_sno   INT NOT NULL,
        cycle_sno      INT NOT NULL,
        agreement_sno  INT NOT NULL,
        vendor_sno     INT NULL,
        invoice_no     NVARCHAR(100) NOT NULL,
        invoice_date   DATE NOT NULL,
        invoice_amount DECIMAL(18,2) NOT NULL,
        invoice_doc_url NVARCHAR(500) NOT NULL,
        remarks        NVARCHAR(500) NULL,
        uploaded_by    VARCHAR(50) NOT NULL,
        uploaded_at    DATETIME NOT NULL DEFAULT GETDATE(),
        is_active      CHAR(1) NOT NULL DEFAULT 'Y'
    );
    CREATE INDEX IX_service_po_invoice_po ON dbo.service_po_invoice (po_basic_sno);
    CREATE INDEX IX_service_po_invoice_cycle ON dbo.service_po_invoice (cycle_sno);
    -- the same supplier invoice number can't be booked twice against one PO
    CREATE UNIQUE INDEX UX_service_po_invoice_po_no ON dbo.service_po_invoice (po_basic_sno, invoice_no) WHERE is_active = 'Y';
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UploadServiceAgreementSignedDoc
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @agreement_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT),
            @doc_url NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.doc_url'))), ''),
            @remarks NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.remarks'))), ''),
            @uploaded_by VARCHAR(50) = JSON_VALUE(@jsonInput, '$.uploaded_by'),
            @status VARCHAR(5), @version_no INT;

    IF @agreement_sno IS NULL THROW 58301, 'agreement_sno is required', 1;
    IF @doc_url IS NULL THROW 58302, 'The signed agreement file is required', 1;
    IF @uploaded_by IS NULL THROW 58303, 'uploaded_by is required', 1;

    SELECT @status = status FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno;
    SELECT @version_no = MAX(version_no) FROM dbo.service_agreement_version WHERE agreement_sno = @agreement_sno;
    IF @status IS NULL THROW 58304, 'Service agreement not found', 1;
    IF @status <> 'A' THROW 58305, 'The signed copy can only be uploaded once the agreement is approved', 1;

    INSERT dbo.service_agreement_signed_doc (agreement_sno, version_no, doc_url, remarks, uploaded_by)
    VALUES (@agreement_sno, @version_no, @doc_url, @remarks, @uploaded_by);

    SELECT SCOPE_IDENTITY() AS signed_doc_sno, @agreement_sno AS agreement_sno;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetServiceAgreementSignedDocs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @agreement_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
    SELECT signed_doc_sno, agreement_sno, version_no, doc_url, remarks, uploaded_by, uploaded_at
    FROM dbo.service_agreement_signed_doc
    WHERE is_active = 'Y' AND (@agreement_sno IS NULL OR agreement_sno = @agreement_sno)
    ORDER BY uploaded_at DESC, signed_doc_sno DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UploadServicePoInvoice
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @po_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT),
            @invoice_no NVARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.invoice_no'))), ''),
            @invoice_date DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_date') AS DATE),
            @invoice_amount DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_amount') AS DECIMAL(18,2)),
            @doc_url NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.invoice_doc_url'))), ''),
            @remarks NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.remarks'))), ''),
            @uploaded_by VARCHAR(50) = JSON_VALUE(@jsonInput, '$.uploaded_by'),
            @cycle_sno INT, @agreement_sno INT, @vendor_sno INT;

    IF @po_basic_sno IS NULL THROW 58311, 'po_basic_sno is required', 1;
    IF @invoice_no IS NULL THROW 58312, 'Invoice number is required', 1;
    IF @invoice_date IS NULL THROW 58313, 'A valid invoice date is required', 1;
    IF @invoice_date > CAST(GETDATE() AS DATE) THROW 58314, 'Invoice date cannot be in the future', 1;
    IF @invoice_amount IS NULL OR @invoice_amount <= 0 THROW 58315, 'Invoice amount must be greater than zero', 1;
    IF @doc_url IS NULL THROW 58316, 'The invoice file is required', 1;
    IF @uploaded_by IS NULL THROW 58317, 'uploaded_by is required', 1;

    -- the PO must have been raised by an approved (GENERATED) service cycle
    SELECT TOP 1 @cycle_sno = c.cycle_sno, @agreement_sno = c.agreement_sno, @vendor_sno = cv.vendor_sno
    FROM dbo.service_po_cycle c
    LEFT JOIN dbo.service_po_cycle_vendor cv ON cv.cycle_sno = c.cycle_sno AND cv.po_basic_sno = @po_basic_sno
    WHERE c.status = 'GENERATED' AND (c.po_basic_sno = @po_basic_sno OR cv.po_basic_sno = @po_basic_sno)
    ORDER BY c.cycle_sno DESC;
    IF @cycle_sno IS NULL THROW 58318, 'This is not an approved Service PO', 1;

    IF @vendor_sno IS NULL SELECT @vendor_sno = vendor_sno FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno;

    IF EXISTS (SELECT 1 FROM dbo.service_po_invoice WHERE po_basic_sno = @po_basic_sno AND invoice_no = @invoice_no AND is_active = 'Y')
        THROW 58319, 'This invoice number is already uploaded against the PO', 1;

    INSERT dbo.service_po_invoice (po_basic_sno, cycle_sno, agreement_sno, vendor_sno, invoice_no, invoice_date, invoice_amount, invoice_doc_url, remarks, uploaded_by)
    VALUES (@po_basic_sno, @cycle_sno, @agreement_sno, @vendor_sno, @invoice_no, @invoice_date, @invoice_amount, @doc_url, @remarks, @uploaded_by);

    SELECT SCOPE_IDENTITY() AS invoice_sno, @po_basic_sno AS po_basic_sno, @cycle_sno AS cycle_sno, @agreement_sno AS agreement_sno;
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
    LEFT JOIN dbo.po_request_info po ON po.po_basic_sno = i.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    WHERE i.is_active = 'Y'
      AND (@po_basic_sno IS NULL OR i.po_basic_sno = @po_basic_sno)
      AND (@cycle_sno IS NULL OR i.cycle_sno = @cycle_sno)
    ORDER BY i.uploaded_at DESC, i.invoice_sno DESC;
END
GO
