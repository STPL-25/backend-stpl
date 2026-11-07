/*
  154_rfq.sql  -  Request For Quotation (RFQ), purchase-team side.

  WHY
  Until now the purchase team typed every supplier quotation in on the supplier's behalf (Add Supplier Quotation
  dialog -> supplier_quotation_info). The new flow lets the buyer pick SEVERAL suppliers on the Purchase screen and
  send them a Request For Quotation. Each supplier gets an e-mail ("please log in to the supplier portal and give your
  quotation") and enters the rates themselves on a Quotation Entry screen in the portal (see grn-service sql/86).

  A supplier is allowed to change its mind and submit again, so RFQ data is kept in its OWN tables and never written
  straight into supplier_quotation_info:

    rfq_info            one request  (a PR, or one split group of it, + due date + note)
    rfq_item            the lines the suppliers are asked to price (snapshot of the PR lines at send time)
    rfq_supplier        one row per invited supplier  (status, e-mail delivery, viewed, revision request, taken)
    rfq_response        one row per SUBMISSION of a supplier = a version (v1, v2, ...). Old versions are never edited.
    rfq_response_item   the prices of that version, line by line
    rfq_supplier_log    audit trail (sent / viewed / submitted / revision asked / taken / ...)

  When the buyer is happy with a supplier's (latest or any earlier) version they "take it as the final quotation":
  sp_nt_TakeRfqResponse builds a normal supplier_quotation_info row from that version by CALLING the existing
  sp_nt_CreateSupplierQuotation, so workflow routing, comparison, PO approval and PO creation are all unchanged.
  supplier_quotation_info only gains two nullable link columns (rfq_sno, rfq_response_sno).

  SUPPLIER STATUS   PENDING -> VIEWED -> SUBMITTED -> TAKEN
                                  \-> DECLINED            SUBMITTED -> REVISION_REQUESTED -> SUBMITTED (v+1)
                    CLOSED when the whole RFQ is cancelled.
  RFQ STATUS        O = open, X = cancelled.

  Idempotent: safe to run more than once.  Apply to Non_trade_Dev only (prod is untouched).
*/

------------------------------------------------------------------------------------------------------------------
-- 1. Tables
------------------------------------------------------------------------------------------------------------------
IF OBJECT_ID('dbo.rfq_info', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.rfq_info (
        rfq_sno            INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_rfq_info PRIMARY KEY,
        rfq_no             VARCHAR(30)    NULL,
        pr_basic_sno       INT            NOT NULL,
        pr_no              VARCHAR(50)    NULL,
        split_group        INT            NULL,                 -- Purchase-screen split group the RFQ was raised for (NULL = main PO)
        com_sno            INT            NULL,                 -- billing scope, used when the final quotation is created
        div_sno            INT            NULL,
        brn_sno            INT            NULL,
        dept_sno           INT            NULL,
        response_due_date  DATE           NULL,
        notes              NVARCHAR(1000) NULL,                 -- message to the suppliers
        status             CHAR(1)        NOT NULL CONSTRAINT DF_rfq_info_status DEFAULT 'O',   -- O open / X cancelled
        closed_by          VARCHAR(20)    NULL,
        closed_at          DATETIME       NULL,
        close_reason       NVARCHAR(250)  NULL,
        is_active          CHAR(1)        NOT NULL CONSTRAINT DF_rfq_info_active DEFAULT 'Y',
        created_by         VARCHAR(20)    NULL,
        created_at         DATETIME       NOT NULL CONSTRAINT DF_rfq_info_created DEFAULT GETDATE()
    );
    CREATE INDEX IX_rfq_info_pr ON dbo.rfq_info (pr_basic_sno, pr_no);
END
GO

IF OBJECT_ID('dbo.rfq_item', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.rfq_item (
        rfq_item_sno   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_rfq_item PRIMARY KEY,
        rfq_sno        INT            NOT NULL CONSTRAINT FK_rfq_item_rfq REFERENCES dbo.rfq_info (rfq_sno),
        pr_item_sno    INT            NULL,
        prod_sno       INT            NULL,
        specification  NVARCHAR(200)  NULL,
        qty            DECIMAL(18,4)  NOT NULL,
        unit           INT            NULL,
        is_active      CHAR(1)        NOT NULL CONSTRAINT DF_rfq_item_active DEFAULT 'Y'
    );
    CREATE INDEX IX_rfq_item_rfq ON dbo.rfq_item (rfq_sno);
END
GO

IF OBJECT_ID('dbo.rfq_supplier', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.rfq_supplier (
        rfq_supplier_sno       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_rfq_supplier PRIMARY KEY,
        rfq_sno                INT            NOT NULL CONSTRAINT FK_rfq_supplier_rfq REFERENCES dbo.rfq_info (rfq_sno),
        vendor_sno             INT            NOT NULL,         -- kyc_basic_info_sno
        status                 VARCHAR(20)    NOT NULL CONSTRAINT DF_rfq_supplier_status DEFAULT 'PENDING',
        email_to               VARCHAR(255)   NULL,
        email_sent             CHAR(1)        NOT NULL CONSTRAINT DF_rfq_supplier_email DEFAULT 'N',
        email_sent_at          DATETIME       NULL,
        email_error            NVARCHAR(500)  NULL,
        email_count            INT            NOT NULL CONSTRAINT DF_rfq_supplier_emailcnt DEFAULT 0,
        first_viewed_at        DATETIME       NULL,
        response_count         INT            NOT NULL CONSTRAINT DF_rfq_supplier_respcnt DEFAULT 0,
        current_response_sno   INT            NULL,             -- the latest submitted version
        response_due_date      DATE           NULL,             -- per-supplier override (set when a revision is requested)
        revision_note          NVARCHAR(500)  NULL,
        revision_requested_by  VARCHAR(20)    NULL,
        revision_requested_at  DATETIME       NULL,
        decline_reason         NVARCHAR(500)  NULL,
        taken_response_sno     INT            NULL,
        taken_sq_basic_sno     INT            NULL,             -- the supplier_quotation_info row created from the taken version
        taken_by               VARCHAR(20)    NULL,
        taken_at               DATETIME       NULL,
        created_at             DATETIME       NOT NULL CONSTRAINT DF_rfq_supplier_created DEFAULT GETDATE(),
        CONSTRAINT UQ_rfq_supplier UNIQUE (rfq_sno, vendor_sno)
    );
    CREATE INDEX IX_rfq_supplier_vendor ON dbo.rfq_supplier (vendor_sno, status);
END
GO

IF OBJECT_ID('dbo.rfq_response', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.rfq_response (
        rfq_response_sno     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_rfq_response PRIMARY KEY,
        rfq_supplier_sno     INT            NOT NULL CONSTRAINT FK_rfq_response_supplier REFERENCES dbo.rfq_supplier (rfq_supplier_sno),
        rfq_sno              INT            NOT NULL,
        version_no           INT            NOT NULL,
        quotation_ref_no     VARCHAR(50)    NULL,
        quotation_date       DATE           NULL,
        valid_upto           DATE           NULL,
        currency_code        VARCHAR(10)    NOT NULL CONSTRAINT DF_rfq_response_cur DEFAULT 'INR',
        payment_terms        NVARCHAR(200)  NULL,
        delivery_days        INT            NULL,
        remarks              NVARCHAR(200)  NULL,
        change_note          NVARCHAR(500)  NULL,               -- what changed since the previous version (required from v2 on)
        freight_charges      DECIMAL(18,2)  NOT NULL CONSTRAINT DF_rfq_response_fr DEFAULT 0,
        freight_gst_pct      DECIMAL(9,3)   NOT NULL CONSTRAINT DF_rfq_response_frg DEFAULT 0,
        other_charges        DECIMAL(18,2)  NOT NULL CONSTRAINT DF_rfq_response_oc DEFAULT 0,
        other_charges_gst_pct DECIMAL(9,3)  NOT NULL CONSTRAINT DF_rfq_response_ocg DEFAULT 0,
        items_total          DECIMAL(18,2)  NOT NULL CONSTRAINT DF_rfq_response_it DEFAULT 0,   -- sum of line totals (incl. line GST)
        grand_total          DECIMAL(18,2)  NOT NULL CONSTRAINT DF_rfq_response_gt DEFAULT 0,   -- items + freight/other charges with their GST
        quotation_file       NVARCHAR(500)  NULL,
        is_current           CHAR(1)        NOT NULL CONSTRAINT DF_rfq_response_cur2 DEFAULT 'Y',
        submitted_by         VARCHAR(255)   NULL,
        submitted_at         DATETIME       NOT NULL CONSTRAINT DF_rfq_response_at DEFAULT GETDATE(),
        CONSTRAINT UQ_rfq_response_version UNIQUE (rfq_supplier_sno, version_no)
    );
    CREATE INDEX IX_rfq_response_rfq ON dbo.rfq_response (rfq_sno);
END
GO

IF OBJECT_ID('dbo.rfq_response_item', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.rfq_response_item (
        rfq_response_item_sno INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_rfq_response_item PRIMARY KEY,
        rfq_response_sno      INT            NOT NULL CONSTRAINT FK_rfq_response_item_resp REFERENCES dbo.rfq_response (rfq_response_sno),
        rfq_item_sno          INT            NOT NULL,
        pr_item_sno           INT            NULL,
        prod_sno              INT            NULL,
        specification         NVARCHAR(200)  NULL,
        qty                   DECIMAL(18,4)  NOT NULL,
        unit                  INT            NULL,
        is_quoted             BIT            NOT NULL CONSTRAINT DF_rfq_response_item_q DEFAULT 1,   -- 0 = supplier does not quote this line
        unit_price            DECIMAL(18,4)  NOT NULL CONSTRAINT DF_rfq_response_item_up DEFAULT 0,
        discount_pct          DECIMAL(9,3)   NOT NULL CONSTRAINT DF_rfq_response_item_d DEFAULT 0,
        tax_pct               DECIMAL(9,3)   NOT NULL CONSTRAINT DF_rfq_response_item_t DEFAULT 0,
        total_amount          DECIMAL(18,2)  NOT NULL CONSTRAINT DF_rfq_response_item_tot DEFAULT 0,
        delivery_days         INT            NULL,
        remarks               NVARCHAR(200)  NULL,
        additional_json       NVARCHAR(MAX)  NULL                -- Warranty / AMC / Other covers, same shape as supplier_quotation_items
    );
    CREATE INDEX IX_rfq_response_item_resp ON dbo.rfq_response_item (rfq_response_sno);
END
GO

IF OBJECT_ID('dbo.rfq_supplier_log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.rfq_supplier_log (
        log_sno           INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_rfq_supplier_log PRIMARY KEY,
        rfq_sno           INT           NOT NULL,
        rfq_supplier_sno  INT           NULL,
        event_type        VARCHAR(30)   NOT NULL,
        event_by          VARCHAR(255)  NULL,
        event_note        NVARCHAR(500) NULL,
        event_at          DATETIME      NOT NULL CONSTRAINT DF_rfq_supplier_log_at DEFAULT GETDATE()
    );
    CREATE INDEX IX_rfq_supplier_log_rs ON dbo.rfq_supplier_log (rfq_supplier_sno, log_sno);
END
GO

------------------------------------------------------------------------------------------------------------------
-- 2. Link a quotation back to the RFQ version it was taken from
------------------------------------------------------------------------------------------------------------------
IF COL_LENGTH('dbo.supplier_quotation_info', 'rfq_sno') IS NULL
    ALTER TABLE dbo.supplier_quotation_info ADD rfq_sno INT NULL;
GO
IF COL_LENGTH('dbo.supplier_quotation_info', 'rfq_response_sno') IS NULL
    ALTER TABLE dbo.supplier_quotation_info ADD rfq_response_sno INT NULL;
GO

------------------------------------------------------------------------------------------------------------------
-- 3. Procedures
------------------------------------------------------------------------------------------------------------------

-- Portal-login status of the approved suppliers, so the Purchase screen can warn about suppliers who cannot log in
-- (older KYC approvals have no nt_supplier_login row; an invite from the KYC screen creates it).
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetRfqSupplierContacts
AS
BEGIN
    SET NOCOUNT ON;
    SELECT k.kyc_basic_info_sno                                                      AS vendor_sno,
           k.supp_code,
           NULLIF(LTRIM(RTRIM(k.email)), '')                                         AS kyc_email,
           l.login_email,
           CAST(CASE WHEN l.supplier_login_sno IS NOT NULL AND l.is_active = 'Y' THEN 1 ELSE 0 END AS BIT) AS has_login
    FROM dbo.kyc_basic_info k
    LEFT JOIN dbo.nt_supplier_login l ON l.kyc_basic_info_sno = k.kyc_basic_info_sno
    WHERE k.status = 'A' AND ISNULL(k.is_active, 'Y') = 'Y';
END
GO

-- Creates an RFQ with its lines and one rfq_supplier row per invited supplier. E-mailing is done by the caller
-- (sp_nt_GetRfqEmailPayload gives it everything it needs; sp_nt_SetRfqEmailStatus records the outcome).
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateRfq
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISJSON(@jsonInput) <> 1 THROW 53100, N'Invalid JSON input.', 1;

    DECLARE @pr_basic_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT),
            @pr_no        VARCHAR(50)   = NULLIF(JSON_VALUE(@jsonInput, '$.pr_no'), ''),
            @split_group  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.split_group') AS INT),
            @com_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT),
            @div_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT),
            @brn_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT),
            @dept_sno     INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT),
            @due          DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.response_due_date') AS DATE),
            @notes        NVARCHAR(1000) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.notes'))), ''),
            @created_by   VARCHAR(20)   = NULLIF(JSON_VALUE(@jsonInput, '$.created_by'), ''),
            @rfq_sno      INT;

    IF @pr_basic_sno IS NULL THROW 53101, N'pr_basic_sno is required.', 1;
    IF @created_by IS NULL   THROW 53102, N'created_by is required.', 1;
    IF @due IS NULL          THROW 53103, N'Response due date is required.', 1;
    IF @due < CAST(GETDATE() AS DATE) THROW 53104, N'Response due date cannot be in the past.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.pr_basic_info WHERE pr_basic_sno = @pr_basic_sno) THROW 53105, N'Purchase requisition not found.', 1;

    DECLARE @vendors TABLE (vendor_sno INT PRIMARY KEY);
    INSERT INTO @vendors (vendor_sno)
    SELECT DISTINCT TRY_CAST([value] AS INT) FROM OPENJSON(@jsonInput, '$.vendor_snos') WHERE TRY_CAST([value] AS INT) IS NOT NULL;
    IF NOT EXISTS (SELECT 1 FROM @vendors) THROW 53106, N'Select at least one supplier.', 1;
    IF EXISTS (SELECT 1 FROM @vendors v WHERE NOT EXISTS (
            SELECT 1 FROM dbo.kyc_basic_info k WHERE k.kyc_basic_info_sno = v.vendor_sno AND k.status = 'A' AND ISNULL(k.is_active, 'Y') = 'Y'))
        THROW 53107, N'One or more of the selected suppliers is not an approved supplier.', 1;

    DECLARE @items TABLE (pr_item_sno INT, prod_sno INT, specification NVARCHAR(1000), qty DECIMAL(18,4), unit INT);
    INSERT INTO @items (pr_item_sno, prod_sno, specification, qty, unit)
    SELECT pr_item_sno, prod_sno, specification, qty, unit
    FROM OPENJSON(@jsonInput, '$.items')
    WITH (pr_item_sno INT '$.pr_item_sno', prod_sno INT '$.prod_sno', specification NVARCHAR(1000) '$.specification',
          qty DECIMAL(18,4) '$.qty', unit INT '$.unit');
    IF NOT EXISTS (SELECT 1 FROM @items) THROW 53108, N'Select at least one item to request a quotation for.', 1;
    IF EXISTS (SELECT 1 FROM @items WHERE qty IS NULL OR qty <= 0 OR prod_sno IS NULL) THROW 53109, N'Every item needs a product and a quantity above zero.', 1;

    BEGIN TRAN;

    INSERT INTO dbo.rfq_info (pr_basic_sno, pr_no, split_group, com_sno, div_sno, brn_sno, dept_sno, response_due_date, notes, status, created_by)
    VALUES (@pr_basic_sno, @pr_no, @split_group, @com_sno, @div_sno, @brn_sno, @dept_sno, @due, @notes, 'O', @created_by);
    SET @rfq_sno = SCOPE_IDENTITY();

    UPDATE dbo.rfq_info SET rfq_no = 'RFQ-' + RIGHT('00000' + CAST(@rfq_sno AS VARCHAR(10)), 5) WHERE rfq_sno = @rfq_sno;

    INSERT INTO dbo.rfq_item (rfq_sno, pr_item_sno, prod_sno, specification, qty, unit)
    SELECT @rfq_sno, pr_item_sno, prod_sno, LEFT(specification, 200), qty, unit FROM @items;

    INSERT INTO dbo.rfq_supplier (rfq_sno, vendor_sno, status)
    SELECT @rfq_sno, vendor_sno, 'PENDING' FROM @vendors;

    INSERT INTO dbo.rfq_supplier_log (rfq_sno, rfq_supplier_sno, event_type, event_by, event_note)
    SELECT @rfq_sno, rs.rfq_supplier_sno, 'CREATED', @created_by, N'RFQ raised'
    FROM dbo.rfq_supplier rs WHERE rs.rfq_sno = @rfq_sno;

    COMMIT;

    SELECT rfq_sno, rfq_no FROM dbo.rfq_info WHERE rfq_sno = @rfq_sno;
END
GO

-- Everything needed to e-mail the suppliers of an RFQ (or one supplier of it): 3 result sets
--   1. the RFQ header   2. the suppliers + where to send   3. the requested items
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetRfqEmailPayload
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @rfq_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.rfq_sno') AS INT),
            @rfq_supplier_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.rfq_supplier_sno') AS INT);

    IF @rfq_sno IS NULL AND @rfq_supplier_sno IS NOT NULL
        SELECT @rfq_sno = rfq_sno FROM dbo.rfq_supplier WHERE rfq_supplier_sno = @rfq_supplier_sno;

    SELECT r.rfq_sno, r.rfq_no, r.pr_no, CONVERT(VARCHAR(11), r.response_due_date, 106) AS response_due_date, r.notes, r.status, com.com_name
    FROM dbo.rfq_info r
    LEFT JOIN dbo.company_master com ON com.com_sno = r.com_sno
    WHERE r.rfq_sno = @rfq_sno;

    SELECT rs.rfq_supplier_sno, rs.vendor_sno, k.company_name, k.supp_code, rs.status, rs.revision_note,
           CONVERT(VARCHAR(11), ISNULL(rs.response_due_date, r.response_due_date), 106) AS due_date,
           COALESCE(NULLIF(LTRIM(RTRIM(l.login_email)), ''), NULLIF(LTRIM(RTRIM(k.email)), '')) AS email_to,
           CAST(CASE WHEN l.supplier_login_sno IS NOT NULL AND l.is_active = 'Y' THEN 1 ELSE 0 END AS BIT) AS has_login
    FROM dbo.rfq_supplier rs
    JOIN dbo.rfq_info r ON r.rfq_sno = rs.rfq_sno
    JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = rs.vendor_sno
    LEFT JOIN dbo.nt_supplier_login l ON l.kyc_basic_info_sno = rs.vendor_sno
    WHERE rs.rfq_sno = @rfq_sno AND (@rfq_supplier_sno IS NULL OR rs.rfq_supplier_sno = @rfq_supplier_sno)
    ORDER BY k.company_name;

    SELECT pm.prod_name, ri.specification, ri.qty, um.uom_name AS unit_name
    FROM dbo.rfq_item ri
    LEFT JOIN dbo.product_master pm ON pm.prod_sno = ri.prod_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = ri.unit
    WHERE ri.rfq_sno = @rfq_sno AND ri.is_active = 'Y'
    ORDER BY ri.rfq_item_sno;
END
GO

-- Records how each RFQ e-mail went. {event_type?, event_by?, results:[{rfq_supplier_sno, email_to, sent, error}]}
CREATE OR ALTER PROCEDURE dbo.sp_nt_SetRfqEmailStatus
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF ISJSON(@jsonInput) <> 1 THROW 53110, N'Invalid JSON input.', 1;

    DECLARE @event_type VARCHAR(30) = ISNULL(NULLIF(JSON_VALUE(@jsonInput, '$.event_type'), ''), 'EMAILED'),
            @event_by   VARCHAR(255) = JSON_VALUE(@jsonInput, '$.event_by');

    DECLARE @res TABLE (rfq_supplier_sno INT PRIMARY KEY, email_to VARCHAR(255), sent BIT, error NVARCHAR(500));
    INSERT INTO @res
    SELECT rfq_supplier_sno, email_to, ISNULL(sent, 0), error
    FROM OPENJSON(@jsonInput, '$.results')
    WITH (rfq_supplier_sno INT '$.rfq_supplier_sno', email_to VARCHAR(255) '$.email_to', sent BIT '$.sent', error NVARCHAR(500) '$.error');

    BEGIN TRAN;
    UPDATE rs
    SET email_to      = r.email_to,
        email_sent    = CASE WHEN r.sent = 1 THEN 'Y' ELSE 'N' END,
        email_sent_at = CASE WHEN r.sent = 1 THEN GETDATE() ELSE rs.email_sent_at END,
        email_error   = CASE WHEN r.sent = 1 THEN NULL ELSE LEFT(ISNULL(r.error, N'E-mail not sent'), 500) END,
        email_count   = rs.email_count + CASE WHEN r.sent = 1 THEN 1 ELSE 0 END
    FROM dbo.rfq_supplier rs JOIN @res r ON r.rfq_supplier_sno = rs.rfq_supplier_sno;

    INSERT INTO dbo.rfq_supplier_log (rfq_sno, rfq_supplier_sno, event_type, event_by, event_note)
    SELECT rs.rfq_sno, rs.rfq_supplier_sno, CASE WHEN r.sent = 1 THEN @event_type ELSE 'EMAIL_FAILED' END, @event_by,
           CASE WHEN r.sent = 1 THEN LEFT(N'E-mailed to ' + ISNULL(r.email_to, N'?'), 500) ELSE LEFT(N'E-mail not sent: ' + ISNULL(r.error, N'unknown reason'), 500) END
    FROM dbo.rfq_supplier rs JOIN @res r ON r.rfq_supplier_sno = rs.rfq_supplier_sno;
    COMMIT;
END
GO

-- The RFQs of one PR (optionally narrowed to one Purchase entry by pr_no) with their suppliers and latest responses.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetRfqsForPR
    @pr_basic_sno INT,
    @pr_no        VARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.rfq_sno, r.rfq_no, r.pr_basic_sno, r.pr_no, r.split_group, CONVERT(VARCHAR(10), r.response_due_date, 23) AS response_due_date, r.notes, r.status,
           r.created_by, CONVERT(VARCHAR(19), r.created_at, 120) AS created_at, r.close_reason, com.com_name,
           (SELECT ri.rfq_item_sno, ri.pr_item_sno, ri.prod_sno, pm.prod_name, ri.specification, ri.qty, ri.unit, um.uom_name AS unit_name
              FROM dbo.rfq_item ri
              LEFT JOIN dbo.product_master pm ON pm.prod_sno = ri.prod_sno
              LEFT JOIN dbo.uom_master um ON um.uom_sno = ri.unit
             WHERE ri.rfq_sno = r.rfq_sno AND ri.is_active = 'Y'
             ORDER BY ri.rfq_item_sno
             FOR JSON PATH) AS items,
           (SELECT rs.rfq_supplier_sno, rs.vendor_sno, k.company_name, k.supp_code, rs.status,
                   rs.email_to, rs.email_sent, CONVERT(VARCHAR(19), rs.email_sent_at, 120) AS email_sent_at, rs.email_error, rs.email_count,
                   CONVERT(VARCHAR(19), rs.first_viewed_at, 120) AS first_viewed_at,
                   rs.response_count, rs.current_response_sno, rs.revision_note, CONVERT(VARCHAR(19), rs.revision_requested_at, 120) AS revision_requested_at, rs.decline_reason,
                   CONVERT(VARCHAR(10), ISNULL(rs.response_due_date, r.response_due_date), 23) AS due_date,
                   rs.taken_response_sno, rs.taken_sq_basic_sno, CONVERT(VARCHAR(19), rs.taken_at, 120) AS taken_at,
                   cur.version_no AS current_version, CONVERT(VARCHAR(19), cur.submitted_at, 120) AS last_submitted_at, cur.grand_total,
                   cur.quotation_ref_no, CONVERT(VARCHAR(10), cur.valid_upto, 23) AS valid_upto, cur.delivery_days, cur.payment_terms,
                   CAST(CASE WHEN l.supplier_login_sno IS NOT NULL AND l.is_active = 'Y' THEN 1 ELSE 0 END AS BIT) AS has_login
              FROM dbo.rfq_supplier rs
              JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = rs.vendor_sno
              LEFT JOIN dbo.rfq_response cur ON cur.rfq_response_sno = rs.current_response_sno
              LEFT JOIN dbo.nt_supplier_login l ON l.kyc_basic_info_sno = rs.vendor_sno
             WHERE rs.rfq_sno = r.rfq_sno
             ORDER BY k.company_name
             FOR JSON PATH) AS suppliers
    FROM dbo.rfq_info r
    LEFT JOIN dbo.company_master com ON com.com_sno = r.com_sno
    WHERE r.pr_basic_sno = @pr_basic_sno
      AND (@pr_no IS NULL OR r.pr_no = @pr_no)
      AND r.is_active = 'Y'
    ORDER BY r.rfq_sno DESC;
END
GO

-- Every submitted version of one supplier's response, newest first, each with its priced lines.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetRfqResponseVersions
    @rfq_supplier_sno INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT resp.rfq_response_sno, resp.rfq_supplier_sno, resp.version_no, resp.is_current,
           resp.quotation_ref_no, CONVERT(VARCHAR(10), resp.quotation_date, 23) AS quotation_date, CONVERT(VARCHAR(10), resp.valid_upto, 23) AS valid_upto,
           resp.currency_code, resp.payment_terms, resp.delivery_days,
           resp.remarks, resp.change_note, resp.freight_charges, resp.freight_gst_pct, resp.other_charges, resp.other_charges_gst_pct,
           resp.items_total, resp.grand_total, resp.quotation_file, resp.submitted_by, CONVERT(VARCHAR(19), resp.submitted_at, 120) AS submitted_at,
           CAST(CASE WHEN rs.taken_response_sno = resp.rfq_response_sno THEN 1 ELSE 0 END AS BIT) AS is_taken,
           (SELECT ri.rfq_response_item_sno, ri.rfq_item_sno, ri.prod_sno, pm.prod_name, ri.specification, ri.qty, ri.unit, um.uom_name AS unit_name,
                   ri.is_quoted, ri.unit_price, ri.discount_pct, ri.tax_pct, ri.total_amount, ri.delivery_days, ri.remarks,
                   JSON_QUERY(ri.additional_json) AS additional
              FROM dbo.rfq_response_item ri
              LEFT JOIN dbo.product_master pm ON pm.prod_sno = ri.prod_sno
              LEFT JOIN dbo.uom_master um ON um.uom_sno = ri.unit
             WHERE ri.rfq_response_sno = resp.rfq_response_sno
             ORDER BY ri.rfq_item_sno
             FOR JSON PATH) AS items
    FROM dbo.rfq_response resp
    JOIN dbo.rfq_supplier rs ON rs.rfq_supplier_sno = resp.rfq_supplier_sno
    WHERE resp.rfq_supplier_sno = @rfq_supplier_sno
    ORDER BY resp.version_no DESC;

    SELECT log_sno, event_type, event_by, event_note, CONVERT(VARCHAR(19), event_at, 120) AS event_at
    FROM dbo.rfq_supplier_log
    WHERE rfq_supplier_sno = @rfq_supplier_sno
    ORDER BY log_sno DESC;
END
GO

-- Buyer asks one supplier to revise its quotation (re-opens it even after the due date).
-- {rfq_supplier_sno, note, response_due_date?, requested_by}
CREATE OR ALTER PROCEDURE dbo.sp_nt_RequestRfqRevision
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF ISJSON(@jsonInput) <> 1 THROW 53111, N'Invalid JSON input.', 1;

    DECLARE @rfq_supplier_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.rfq_supplier_sno') AS INT),
            @note NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.note'))), ''),
            @new_due DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.response_due_date') AS DATE),
            @by VARCHAR(20) = NULLIF(JSON_VALUE(@jsonInput, '$.requested_by'), ''),
            @status VARCHAR(20), @rfq_status CHAR(1), @rfq_sno INT, @eff_due DATE;

    IF @rfq_supplier_sno IS NULL THROW 53112, N'rfq_supplier_sno is required.', 1;
    IF @note IS NULL THROW 53113, N'Tell the supplier what to change.', 1;
    IF @by IS NULL THROW 53114, N'requested_by is required.', 1;

    SELECT @status = rs.status, @rfq_status = r.status, @rfq_sno = r.rfq_sno, @eff_due = ISNULL(rs.response_due_date, r.response_due_date)
    FROM dbo.rfq_supplier rs JOIN dbo.rfq_info r ON r.rfq_sno = rs.rfq_sno
    WHERE rs.rfq_supplier_sno = @rfq_supplier_sno;

    IF @rfq_sno IS NULL THROW 53115, N'RFQ supplier not found.', 1;
    IF @rfq_status <> 'O' THROW 53116, N'This RFQ is closed.', 1;
    IF @status NOT IN ('SUBMITTED', 'DECLINED') THROW 53117, N'A revision can only be requested after the supplier has submitted (or declined).', 1;
    IF @new_due IS NOT NULL AND @new_due < CAST(GETDATE() AS DATE) THROW 53118, N'The new due date cannot be in the past.', 1;
    IF @new_due IS NULL AND @eff_due < CAST(GETDATE() AS DATE) THROW 53119, N'The due date has passed - choose a new response due date.', 1;

    BEGIN TRAN;
    UPDATE dbo.rfq_supplier
    SET status = 'REVISION_REQUESTED', revision_note = @note, revision_requested_by = @by, revision_requested_at = GETDATE(),
        response_due_date = ISNULL(@new_due, response_due_date)
    WHERE rfq_supplier_sno = @rfq_supplier_sno;
    INSERT INTO dbo.rfq_supplier_log (rfq_sno, rfq_supplier_sno, event_type, event_by, event_note)
    VALUES (@rfq_sno, @rfq_supplier_sno, 'REVISION_REQUESTED', @by, @note);
    COMMIT;

    SELECT @rfq_supplier_sno AS rfq_supplier_sno, @rfq_sno AS rfq_sno;
END
GO

-- Cancels a whole RFQ: nobody can respond any more. Quotations already taken stay as they are.
-- {rfq_sno, reason?, closed_by}
CREATE OR ALTER PROCEDURE dbo.sp_nt_CloseRfq
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF ISJSON(@jsonInput) <> 1 THROW 53120, N'Invalid JSON input.', 1;

    DECLARE @rfq_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.rfq_sno') AS INT),
            @reason NVARCHAR(250) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.reason'))), ''),
            @by VARCHAR(20) = NULLIF(JSON_VALUE(@jsonInput, '$.closed_by'), ''),
            @status CHAR(1);

    IF @rfq_sno IS NULL THROW 53121, N'rfq_sno is required.', 1;
    IF @by IS NULL THROW 53122, N'closed_by is required.', 1;
    SELECT @status = status FROM dbo.rfq_info WHERE rfq_sno = @rfq_sno AND is_active = 'Y';
    IF @status IS NULL THROW 53123, N'RFQ not found.', 1;
    IF @status <> 'O' THROW 53124, N'This RFQ is already closed.', 1;

    BEGIN TRAN;
    UPDATE dbo.rfq_info SET status = 'X', closed_by = @by, closed_at = GETDATE(), close_reason = @reason WHERE rfq_sno = @rfq_sno;

    INSERT INTO dbo.rfq_supplier_log (rfq_sno, rfq_supplier_sno, event_type, event_by, event_note)
    SELECT rfq_sno, rfq_supplier_sno, 'CLOSED', @by, ISNULL(@reason, N'RFQ cancelled')
    FROM dbo.rfq_supplier WHERE rfq_sno = @rfq_sno AND status <> 'TAKEN';

    UPDATE dbo.rfq_supplier SET status = 'CLOSED' WHERE rfq_sno = @rfq_sno AND status <> 'TAKEN';
    COMMIT;

    SELECT @rfq_sno AS rfq_sno;
END
GO

-- "Take as final quotation": turns one submitted version into a normal supplier quotation (PO approval workflow etc.)
-- by calling the existing sp_nt_CreateSupplierQuotation. {rfq_response_sno, taken_by}
-- No outer transaction on purpose: sp_nt_CreateSupplierQuotation owns its transaction and ROLLBACKs on error, which
-- would otherwise doom ours. The link-back below is its own small transaction; if it fails the new quotation is
-- switched off again so nothing half-linked is left behind.
CREATE OR ALTER PROCEDURE dbo.sp_nt_TakeRfqResponse
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) <> 1 THROW 53130, N'Invalid JSON input.', 1;

    DECLARE @rfq_response_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.rfq_response_sno') AS INT),
            @taken_by VARCHAR(20) = NULLIF(JSON_VALUE(@jsonInput, '$.taken_by'), '');
    IF @rfq_response_sno IS NULL THROW 53131, N'rfq_response_sno is required.', 1;
    IF @taken_by IS NULL THROW 53132, N'taken_by is required.', 1;

    DECLARE @rfq_supplier_sno INT, @rfq_sno INT, @vendor_sno INT, @rs_status VARCHAR(20), @rfq_status CHAR(1), @version INT,
            @pr_basic_sno INT, @pr_no VARCHAR(50), @split_group INT, @com INT, @div INT, @brn INT, @dept INT, @rfq_no VARCHAR(30),
            @ref VARCHAR(50), @qdate DATE, @valid DATE, @cur VARCHAR(10), @terms NVARCHAR(200), @days INT, @remarks NVARCHAR(200),
            @file NVARCHAR(500), @fr DECIMAL(18,2), @frg DECIMAL(9,3), @oc DECIMAL(18,2), @ocg DECIMAL(9,3);

    SELECT @rfq_supplier_sno = resp.rfq_supplier_sno, @rfq_sno = resp.rfq_sno, @version = resp.version_no,
           @ref = resp.quotation_ref_no, @qdate = ISNULL(resp.quotation_date, CAST(resp.submitted_at AS DATE)), @valid = resp.valid_upto,
           @cur = resp.currency_code, @terms = resp.payment_terms, @days = resp.delivery_days, @remarks = resp.remarks,
           @file = resp.quotation_file, @fr = resp.freight_charges, @frg = resp.freight_gst_pct, @oc = resp.other_charges, @ocg = resp.other_charges_gst_pct,
           @vendor_sno = rs.vendor_sno, @rs_status = rs.status, @rfq_status = r.status,
           @pr_basic_sno = r.pr_basic_sno, @pr_no = r.pr_no, @split_group = r.split_group,
           @com = r.com_sno, @div = r.div_sno, @brn = r.brn_sno, @dept = r.dept_sno, @rfq_no = r.rfq_no
    FROM dbo.rfq_response resp
    JOIN dbo.rfq_supplier rs ON rs.rfq_supplier_sno = resp.rfq_supplier_sno
    JOIN dbo.rfq_info r ON r.rfq_sno = resp.rfq_sno
    WHERE resp.rfq_response_sno = @rfq_response_sno;

    IF @rfq_supplier_sno IS NULL THROW 53133, N'Quotation response not found.', 1;
    IF @rfq_status <> 'O' THROW 53134, N'This RFQ is closed.', 1;
    IF @rs_status = 'TAKEN' THROW 53135, N'A quotation has already been taken from this supplier for this RFQ.', 1;
    IF @rs_status <> 'SUBMITTED' THROW 53136, N'Only a submitted quotation can be taken - the supplier has been asked to revise it or has declined.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.rfq_response_item WHERE rfq_response_sno = @rfq_response_sno AND is_quoted = 1 AND unit_price > 0)
        THROW 53137, N'This response has no priced items.', 1;

    IF @ref IS NULL OR @ref = '' SET @ref = LEFT(@rfq_no + '-V' + CAST(@version AS VARCHAR(5)), 50);

    -- Same lookup sp_nt_CreateSupplierQuotation does. Checked here first because that procedure ROLLBACKs when it
    -- fails, and SQL Server does not allow a ROLLBACK inside the INSERT ... EXEC used below - the buyer would only
    -- see a cryptic error instead of this one.
    IF NOT EXISTS (
        SELECT 1 FROM dbo.workflow_types wt
        JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.brn_sno = @brn AND wt.dept_sno = @dept AND wt.com_sno = @com AND wt.div_sno = @div
          AND awm.entity_type = dbo.fn_resolve_approval_entity('PurchaseOrder', 'STANDARD')
          AND wt.is_active = 'Y' AND awm.is_active = 'Y'
          AND EXISTS (SELECT 1 FROM dbo.workflow_stage act_ws WHERE act_ws.workflow_types_id = wt.workflow_types_id AND act_ws.is_active = 'Y'))
        THROW 53139, N'No active approval workflow is configured for this branch and department, so the quotation cannot be created yet.', 1;

    DECLARE @payload NVARCHAR(MAX) =
    (
        SELECT @pr_basic_sno AS pr_basic_sno, @pr_no AS pr_no, @vendor_sno AS vendor_sno, @ref AS quotation_ref_no,
               CONVERT(VARCHAR(10), @qdate, 23) AS quotation_date, CONVERT(VARCHAR(10), @valid, 23) AS valid_upto,
               @cur AS currency_code, @terms AS payment_terms, @days AS delivery_days, LEFT(@remarks, 200) AS remarks,
               @taken_by AS created_by, @com AS com_sno, @div AS div_sno, @brn AS brn_sno, @dept AS dept_sno,
               @file AS sq_quotation_file, @fr AS freight_charges, @oc AS other_charges, @split_group AS split_group,
               (SELECT ri.pr_item_sno, ri.prod_sno, ri.specification, ri.qty, ri.unit, ri.unit_price, ri.discount_pct, ri.tax_pct,
                       ri.total_amount, ri.delivery_days, ri.remarks, JSON_QUERY(ri.additional_json) AS additional
                  FROM dbo.rfq_response_item ri
                 WHERE ri.rfq_response_sno = @rfq_response_sno AND ri.is_quoted = 1 AND ri.unit_price > 0
                 ORDER BY ri.rfq_item_sno
                 FOR JSON PATH) AS items
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    CREATE TABLE #created (success INT, message NVARCHAR(MAX), c3 INT NULL, c4 INT NULL);
    BEGIN TRY
        INSERT INTO #created EXEC dbo.sp_nt_CreateSupplierQuotation @payload;
    END TRY
    BEGIN CATCH
        DECLARE @em NVARCHAR(1500) = ERROR_MESSAGE();
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @em = LEFT(N'The quotation could not be created from this response: ' + ISNULL(@em, N'unknown error'), 2000);
        THROW 53140, @em, 1;
    END CATCH

    DECLARE @ok INT, @msg NVARCHAR(MAX), @sq_basic_sno INT;
    SELECT TOP 1 @ok = success, @msg = message, @sq_basic_sno = c3 FROM #created;
    IF ISNULL(@ok, 0) <> 1 OR @sq_basic_sno IS NULL
    BEGIN
        SET @msg = LEFT(ISNULL(@msg, N'The quotation could not be created.'), 2000);
        THROW 53138, @msg, 1;
    END

    BEGIN TRY
        BEGIN TRAN;
        -- sp_nt_CreateSupplierQuotation does not store the GST % on freight / other charges; carry them over here.
        UPDATE dbo.supplier_quotation_info
        SET rfq_sno = @rfq_sno, rfq_response_sno = @rfq_response_sno, freight_gst_pct = @frg, other_charges_gst_pct = @ocg
        WHERE sq_basic_sno = @sq_basic_sno;

        UPDATE dbo.rfq_supplier
        SET status = 'TAKEN', taken_response_sno = @rfq_response_sno, taken_sq_basic_sno = @sq_basic_sno, taken_by = @taken_by, taken_at = GETDATE()
        WHERE rfq_supplier_sno = @rfq_supplier_sno;

        INSERT INTO dbo.rfq_supplier_log (rfq_sno, rfq_supplier_sno, event_type, event_by, event_note)
        VALUES (@rfq_sno, @rfq_supplier_sno, 'TAKEN', @taken_by, CONCAT(N'Version ', @version, N' taken as the final quotation (quotation #', @sq_basic_sno, N')'));
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        UPDATE dbo.supplier_quotation_info SET is_active = 0 WHERE sq_basic_sno = @sq_basic_sno;
        THROW;
    END CATCH

    SELECT @sq_basic_sno AS sq_basic_sno, @ref AS quotation_ref_no, @vendor_sno AS vendor_sno, @rfq_no AS rfq_no, @version AS version_no;
END
GO
