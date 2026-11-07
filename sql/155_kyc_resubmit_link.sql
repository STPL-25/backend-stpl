-- ============================================================
-- sql/155: a supplier whose KYC was REJECTED gets a private one-time link to correct it and send it again.
-- Database: Non_trade_Dev (MSSQL). Re-runnable.
--
-- Why: a supplier only gets a portal login after the KYC is approved, and /supplier_onboarding only creates a NEW KYC. So a
-- KYC rejected for wrong information was a dead end: the supplier had to start over, upload every document again, and the
-- approvers lost the history of the first attempt. Now:
--   1. REJECT   the approver's reason is kept and the backend e-mails the supplier a link /kyc_resubmit#t=<token>.
--               The token is 32 random bytes made by the backend; only its SHA-256 is stored here, so the table never holds
--               a usable link. A new link closes the older ones. Links expire (7 days by default) and work once.
--   2. OPEN     the page sends the token; the KYC (active rows only) and the reason come back, with the choices for the form.
--   3. SAVE     the corrected KYC is written IN PLACE: rows kept are updated (same snos), rows left out are deactivated
--               (is_active = 'N', never deleted), new rows are added, a new document replaces the old one of its type.
--               The KYC goes back to status P with the first approver of the KYC workflow as it is configured now, the
--               link is spent, and the before/after snapshot (fn_nt_KycSnapshot) is kept in kyc_resubmission.
--               Changing the GST number clears the GST status fetched for the old one; changing the PAN clears pan_status.
--               The files themselves are checked (type, content, active content in PDFs) by the backend BEFORE they reach
--               the FTP server - see backend-stpl/src/KycResubmit/fileSecurity.js.
--   4. STAFF    Supplier Status shows the link (sent to / expires / used) and can send a new one; the approval list shows
--               that a KYC was resubmitted, why it had been rejected and the supplier's note; the timeline shows the
--               rejection reason and the resubmission.
--
-- Objects:
--   kyc_resubmit_link              NEW   one row per link e-mailed to a supplier (token hash, reason, expiry, used)
--   kyc_resubmission               NEW   one row per resubmission (old / new snapshot, note, uploaded files, IP)
--   vw_get_all_kyc_info            CHANGED  addresses / banks / contacts / documents: active rows only (a deactivated row
--                                           is a removed one - same rule as sp_nt_GetSupplierFullDetails). Columns unchanged.
--   sp_get_kyc_approval            CHANGED  bank accounts: active rows only; + resubmit_count, resubmitted_date,
--                                           resubmit_note, last_reject_reason
--   sp_nt_GetSupplierStatusTimeline CHANGED RS3: 'S' rows read RESUBMITTED; rejection reason / supplier note as comment
--   sp_nt_KycResubmitIssue         NEW   staff/backend: create a link for a rejected KYC (closes older ones); only a KYC approver
--                                        (a stage of the KYC's workflow, or whoever rejected it) may send one
--   sp_nt_KycResubmitMarkEmail     NEW   backend: record whether the e-mail went out
--   sp_nt_KycResubmitLinkStatus    NEW   staff: the latest link of a KYC (no token)
--   sp_nt_KycResubmitFindLink      NEW   (internal) token hash -> link + KYC, or a supplier-facing error
--   sp_nt_KycResubmitCheck         NEW   public: is this link usable? (the backend asks before it accepts any file)
--   sp_nt_KycResubmitOpen          NEW   public: the KYC to correct
--   sp_nt_KycResubmitSave          NEW   public: save the corrected KYC and send it for approval again
-- Errors 58701-58740 are written for the person who sees them and shown as they are.
-- Rollback: sql/backups/kyc_resubmit_link_2026-11-07_ROLLBACK.sql
-- ============================================================

IF OBJECT_ID('dbo.kyc_resubmit_link', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.kyc_resubmit_link (
        link_sno           INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_kyc_resubmit_link PRIMARY KEY,
        kyc_basic_info_sno INT            NOT NULL CONSTRAINT FK_kyc_resubmit_link_kyc REFERENCES dbo.kyc_basic_info (kyc_basic_info_sno),
        token_hash         CHAR(64)       NOT NULL,      -- SHA-256 (hex) of the token in the link; the token itself is never stored
        reject_reason      NVARCHAR(1000) NOT NULL,      -- what the supplier has to correct (shown on the page and in the e-mail)
        kyc_history_sno    INT            NULL,          -- the rejection (kyc_history status R) this link answers
        sent_to            NVARCHAR(100)  NOT NULL,
        email_sent         CHAR(1)        NOT NULL CONSTRAINT DF_kyc_resubmit_link_email DEFAULT ('N'),
        email_note         NVARCHAR(300)  NULL,          -- why the e-mail did not go out
        created_by         VARCHAR(30)    NOT NULL,      -- the approver who rejected / the staff member who re-sent it
        created_date       DATETIME       NOT NULL CONSTRAINT DF_kyc_resubmit_link_created DEFAULT (GETDATE()),
        expires_at         DATETIME       NOT NULL,
        opened_date        DATETIME       NULL,          -- first time the supplier opened it
        used_date          DATETIME       NULL,          -- the KYC was resubmitted with it
        closed_date        DATETIME       NULL,
        closed_reason      VARCHAR(20)    NULL,          -- RESUBMITTED | REPLACED (a newer link was sent)
        CONSTRAINT UQ_kyc_resubmit_link_token UNIQUE (token_hash),
        CONSTRAINT CK_kyc_resubmit_link_email CHECK (email_sent IN ('Y', 'N')),
        CONSTRAINT CK_kyc_resubmit_link_hash CHECK (LEN(token_hash) = 64 AND token_hash NOT LIKE '%[^0-9A-Fa-f]%'),
        CONSTRAINT CK_kyc_resubmit_link_closed CHECK (closed_reason IS NULL OR closed_reason IN ('RESUBMITTED', 'REPLACED'))
    );
    CREATE INDEX IX_kyc_resubmit_link_kyc ON dbo.kyc_resubmit_link (kyc_basic_info_sno, link_sno);
END
GO

IF OBJECT_ID('dbo.kyc_resubmission', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.kyc_resubmission (
        resubmission_sno   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_kyc_resubmission PRIMARY KEY,
        kyc_basic_info_sno INT            NOT NULL CONSTRAINT FK_kyc_resubmission_kyc REFERENCES dbo.kyc_basic_info (kyc_basic_info_sno),
        link_sno           INT            NOT NULL CONSTRAINT FK_kyc_resubmission_link REFERENCES dbo.kyc_resubmit_link (link_sno),
        kyc_history_sno    INT            NULL,          -- the kyc_history row (status S) written for it
        supplier_note      NVARCHAR(500)  NULL,          -- what the supplier says they corrected
        old_data           NVARCHAR(MAX)  NOT NULL,      -- fn_nt_KycSnapshot before
        new_data           NVARCHAR(MAX)  NOT NULL,      -- fn_nt_KycSnapshot after
        files_json         NVARCHAR(MAX)  NULL,          -- the files uploaded: type, name, size, detected type, sha256
        client_ip          VARCHAR(45)    NULL,
        created_date       DATETIME       NOT NULL CONSTRAINT DF_kyc_resubmission_created DEFAULT (GETDATE()),
        CONSTRAINT CK_kyc_resubmission_json CHECK (ISJSON(old_data) = 1 AND ISJSON(new_data) = 1)
    );
    CREATE INDEX IX_kyc_resubmission_kyc ON dbo.kyc_resubmission (kyc_basic_info_sno, resubmission_sno);
END
GO

-- ------------------------------------------------------------
-- vw_get_all_kyc_info: only active child rows (the approval list read removed rows too). Same columns as before.
-- ------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_get_all_kyc_info
AS
    SELECT
        bf.*,
        ISNULL((SELECT address_type, door_no, street, area, city, taluk, state, pincode, location_link
                FROM dbo.kyc_address_info af
                WHERE af.kyc_basic_info_sno = bf.kyc_basic_info_sno AND ISNULL(af.is_active, 'Y') <> 'N'
                FOR JSON PATH), '[]') AS kyc_address,
        ISNULL((SELECT ac_holder_name, ac_number, ac_type, ifsc, bank_name, bank_branch_name, bank_address, is_primary
                FROM dbo.kyc_bank_info kbi
                WHERE kbi.kyc_basic_info_sno = bf.kyc_basic_info_sno AND ISNULL(kbi.is_active, 'Y') <> 'N'
                FOR JSON PATH), '[]') AS kyc_bank_info,
        ISNULL((SELECT contact_type, contact_name, contact_position, contact_mobile, contact_email, created_date, is_active
                FROM dbo.kyc_contact_info ci
                WHERE ci.kyc_basic_info_sno = bf.kyc_basic_info_sno AND ISNULL(ci.is_active, 'Y') <> 'N'
                FOR JSON PATH), '[]') AS kyc_contact_details,
        ISNULL((SELECT document_type, document_name, document_path, uploaded_date, is_active
                FROM dbo.kyc_document_info di
                WHERE di.kyc_basic_info_sno = bf.kyc_basic_info_sno AND ISNULL(di.is_active, 'Y') <> 'N'
                FOR JSON PATH), '[]') AS kyc_uploaded_doc
    FROM dbo.kyc_basic_info bf;
GO

-- ------------------------------------------------------------
-- sp_get_kyc_approval: as sql/110 + active bank rows only + what the approver needs to know about a resubmission.
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_get_kyc_approval
    @Ecno VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NULLIF(LTRIM(RTRIM(@Ecno)), '') IS NULL
            THROW 50001, 'Ecno cannot be null or empty.', 1;

        SELECT v.*,
               CAST(NULL AS NVARCHAR(200)) AS business_type_name,
               rs.resubmit_count, rs.resubmitted_date, rs.resubmit_note, rs.last_reject_reason
        INTO #kyc
        FROM dbo.vw_get_all_kyc_info v
        OUTER APPLY (
            SELECT COUNT(*) AS resubmit_count,
                   MAX(r.created_date) AS resubmitted_date,
                   (SELECT TOP 1 r2.supplier_note FROM dbo.kyc_resubmission r2
                     WHERE r2.kyc_basic_info_sno = v.kyc_basic_info_sno ORDER BY r2.resubmission_sno DESC) AS resubmit_note,
                   (SELECT TOP 1 l.reject_reason FROM dbo.kyc_resubmission r3
                      JOIN dbo.kyc_resubmit_link l ON l.link_sno = r3.link_sno
                     WHERE r3.kyc_basic_info_sno = v.kyc_basic_info_sno ORDER BY r3.resubmission_sno DESC) AS last_reject_reason
            FROM dbo.kyc_resubmission r
            WHERE r.kyc_basic_info_sno = v.kyc_basic_info_sno
        ) rs
        WHERE v.approver_ecno = @Ecno
          AND v.status = 'P';

        -- View column kyc_bank_info is fixed-width; long/multi-account JSON overflowed it (error 2628).
        ALTER TABLE #kyc ALTER COLUMN kyc_bank_info NVARCHAR(MAX) NULL;

        UPDATE k
        SET business_type_name = COALESCE(bt.business_types_name, NULLIF(LTRIM(RTRIM(k.business_type)), '')),
            kyc_bank_info = ISNULL((
                SELECT kbi.ac_holder_name, kbi.ac_number, kbi.ac_type,
                       COALESCE(bat.account_type_name, NULLIF(LTRIM(RTRIM(kbi.ac_type)), '')) AS ac_type_name,
                       kbi.ifsc, kbi.bank_name, kbi.bank_branch_name, kbi.bank_address, kbi.is_primary
                FROM dbo.kyc_bank_info kbi
                LEFT JOIN dbo.bank_account_type_master bat
                       ON bat.bank_account_type_sno = TRY_CONVERT(INT, kbi.ac_type)
                WHERE kbi.kyc_basic_info_sno = k.kyc_basic_info_sno AND ISNULL(kbi.is_active, 'Y') <> 'N'
                FOR JSON PATH), '[]')
        FROM #kyc k
        LEFT JOIN dbo.business_types bt
               ON bt.business_types_id = TRY_CONVERT(INT, k.business_type);

        SELECT * FROM #kyc;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

-- ------------------------------------------------------------
-- sp_nt_GetSupplierStatusTimeline: as before, RS3 now names the resubmission and carries the reason / note.
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetSupplierStatusTimeline
    @source    VARCHAR(12),
    @record_id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @workflow_types_id INT, @status CHAR(1), @approver VARCHAR(50);
    SELECT @workflow_types_id = k.workflow_types_id,
               @status = k.status, @approver = k.approver_ecno
        FROM dbo.kyc_basic_info k
        WHERE k.kyc_basic_info_sno = @record_id;

    -- Every person code we will show, resolved once.
    CREATE TABLE #codes (code VARCHAR(50) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
    INSERT INTO #codes (code)
    SELECT DISTINCT LTRIM(RTRIM(c)) FROM (
        SELECT JSON_VALUE(st.value, '$.approver_ecno') AS c
            FROM dbo.workflow_stage ws CROSS APPLY OPENJSON(ws.stage_order_json) AS st
            WHERE ws.workflow_types_id = @workflow_types_id AND ws.is_active = 'Y'
        UNION SELECT @approver
        UNION SELECT created_by FROM dbo.kyc_basic_info WHERE @source = 'KYC' AND kyc_basic_info_sno = @record_id
        UNION SELECT modified_by FROM dbo.kyc_basic_info WHERE @source = 'KYC' AND kyc_basic_info_sno = @record_id
        UNION SELECT status_by FROM dbo.kyc_history WHERE @source = 'KYC' AND kyc_basic_info_sno = @record_id
    ) x
    WHERE c IS NOT NULL AND LTRIM(RTRIM(c)) <> '';

    CREATE TABLE #people (code VARCHAR(50) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, name NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL);
    INSERT INTO #people (code, name)
    SELECT c.code, MAX(COALESCE(NULLIF(LTRIM(RTRIM(e.ename)), ''), ns.full_name))
    FROM #codes c
    LEFT JOIN dbo.vw_verified_employees e ON e.ecno = c.code
    LEFT JOIN dbo.nt_nonstaff_login ns   ON ns.login_id = c.code
    GROUP BY c.code;

    -- RS1: header (last_action_* = the last modification, used only when history has no row for the final decision)
        SELECT
            'KYC' AS source, k.kyc_basic_info_sno AS record_id,
            COALESCE(NULLIF(LTRIM(RTRIM(k.company_name)), ''), k.legal_name, k.trade_name) AS company_name,
            k.legal_name, k.trade_name, k.supp_code, k.status,
            CASE WHEN k.vendor_category = 'SERVICE' THEN 'Service Vendor' ELSE 'Supplier' END AS category,
            k.contact_person, k.email, k.mobile_number, k.gst_no, k.pan_no, k.msme_no,
            COALESCE(bt.business_types_name, NULLIF(LTRIM(RTRIM(k.business_type)), '')) AS business_type_name,
            k.created_by, pc.name AS created_by_name, k.created_date,
            CASE WHEN k.status = 'P' THEN k.approver_ecno END AS current_approver_id,
            CASE WHEN k.status = 'P' THEN pa.name END AS current_approver_name,
            k.modified_by AS last_action_by, pl.name AS last_action_by_name, k.modified_date AS last_action_date
        FROM dbo.kyc_basic_info k
        LEFT JOIN dbo.business_types bt ON bt.business_types_id = TRY_CONVERT(INT, k.business_type)
        LEFT JOIN #people pc ON pc.code = k.created_by
        LEFT JOIN #people pa ON pa.code = k.approver_ecno
        LEFT JOIN #people pl ON pl.code = k.modified_by
        WHERE k.kyc_basic_info_sno = @record_id;

    -- RS2: the approval chain, in order, with names
    SELECT
        CAST(st.[key] AS INT) + 1             AS stage_no,
        JSON_VALUE(st.value, '$.stage')        AS stage_name,
        JSON_VALUE(st.value, '$.approver_ecno') AS approver_ecno,
        p.name                                 AS approver_name
    FROM dbo.workflow_stage ws
    CROSS APPLY OPENJSON(ws.stage_order_json) AS st
    LEFT JOIN #people p ON p.code = JSON_VALUE(st.value, '$.approver_ecno')
    WHERE ws.workflow_types_id = @workflow_types_id AND ws.is_active = 'Y'
    ORDER BY stage_no;

    -- RS3: what actually happened, oldest first. A rejection carries the reason the supplier was sent (sql/155; older
    -- rejections have none), a resubmission (status S, by the supplier through the link) carries the supplier's note.
        SELECT
            CASE h.status WHEN 'A' THEN 'APPROVED' WHEN 'R' THEN 'REJECTED' WHEN 'S' THEN 'RESUBMITTED' ELSE h.status END AS event,
            h.status_by,
            COALESCE(p.name, CASE WHEN h.status = 'S' THEN N'Supplier (correction link)' END) AS status_by_name,
            CAST(h.status_date AS DATETIME) AS event_date,
            CAST(CASE h.status
                     WHEN 'R' THEN (SELECT TOP 1 l.reject_reason FROM dbo.kyc_resubmit_link l
                                     WHERE l.kyc_history_sno = h.kyc_history_sno ORDER BY l.link_sno DESC)
                     WHEN 'S' THEN (SELECT TOP 1 r.supplier_note FROM dbo.kyc_resubmission r
                                     WHERE r.kyc_history_sno = h.kyc_history_sno ORDER BY r.resubmission_sno DESC)
                 END AS NVARCHAR(1000)) AS comment
        FROM dbo.kyc_history h
        LEFT JOIN #people p ON p.code = h.status_by
        WHERE h.kyc_basic_info_sno = @record_id AND @source = 'KYC'
        ORDER BY h.kyc_history_sno;

    DROP TABLE #people;
    DROP TABLE #codes;
END;
GO

-- ------------------------------------------------------------
-- sp_nt_KycResubmitIssue: a new link for a rejected KYC. The backend makes the token and passes only its hash.
-- @reason NULL = keep the reason of the previous link (a re-send). Closes every older open link of the KYC.
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_nt_KycResubmitIssue
    @kyc_basic_info_sno INT,
    @token_hash         CHAR(64),
    @reason             NVARCHAR(1000) = NULL,
    @created_by         VARCHAR(30),
    @valid_days         INT = 7
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @token_hash IS NULL OR LEN(@token_hash) <> 64 OR @token_hash LIKE '%[^0-9A-Fa-f]%'
        THROW 58707, N'The link could not be made (bad token).', 1;
    IF NULLIF(LTRIM(RTRIM(@created_by)), '') IS NULL
        THROW 58708, N'Who is sending the link is not known.', 1;
    IF @valid_days IS NULL OR @valid_days NOT BETWEEN 1 AND 30 SET @valid_days = 7;
    SET @reason = NULLIF(LTRIM(RTRIM(@reason)), N'');

    DECLARE @status CHAR(1), @category VARCHAR(20), @email NVARCHAR(100), @company NVARCHAR(100), @link INT;

    BEGIN TRAN;

    SELECT @status   = k.status,
           @category = k.vendor_category,
           @company  = COALESCE(NULLIF(LTRIM(RTRIM(k.company_name)), ''), k.legal_name, k.trade_name),
           @email    = COALESCE(NULLIF(LTRIM(RTRIM(k.email)), N''),
                                (SELECT TOP 1 NULLIF(LTRIM(RTRIM(c.contact_email)), '')
                                   FROM dbo.kyc_contact_info c
                                  WHERE c.kyc_basic_info_sno = k.kyc_basic_info_sno AND ISNULL(c.is_active, 'Y') <> 'N'
                                    AND NULLIF(LTRIM(RTRIM(c.contact_email)), '') IS NOT NULL
                                  ORDER BY CASE WHEN c.contact_type = 'PRIMARY' THEN 0 ELSE 1 END, c.kyc_contact_sno))
    FROM dbo.kyc_basic_info k WITH (UPDLOCK, HOLDLOCK)
    WHERE k.kyc_basic_info_sno = @kyc_basic_info_sno;

    IF @status IS NULL      THROW 58701, N'This KYC does not exist.', 1;
    IF @status <> 'R'       THROW 58702, N'A correction link can be sent only for a rejected KYC.', 1;
    IF @category = 'SERVICE' THROW 58703, N'This is a service vendor KYC - it is corrected in the Service Vendor KYC screen.', 1;
    IF @email IS NULL OR @email NOT LIKE N'%_@_%._%'
        THROW 58704, N'This KYC has no valid e-mail address, so the correction link cannot be sent. Contact the supplier directly.', 1;

    IF @reason IS NULL
        SELECT TOP 1 @reason = l.reject_reason FROM dbo.kyc_resubmit_link l
         WHERE l.kyc_basic_info_sno = @kyc_basic_info_sno ORDER BY l.link_sno DESC;
    IF @reason IS NULL      THROW 58705, N'Write what the supplier has to correct.', 1;

    -- only the people who decide on this KYC may send the supplier a link to change it
    IF NOT EXISTS (
            SELECT 1
            FROM dbo.kyc_basic_info k
            JOIN dbo.vw_workflow_stages ws ON ws.workflow_types_id = k.workflow_types_id
            CROSS APPLY OPENJSON(ws.stages_json) s
            CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) v
            WHERE k.kyc_basic_info_sno = @kyc_basic_info_sno AND s.[key] = '0'
              AND UPPER(LTRIM(RTRIM(JSON_VALUE(v.value, '$.approver_ecno')))) = UPPER(LTRIM(RTRIM(@created_by))))
       AND NOT EXISTS (
            SELECT 1 FROM dbo.kyc_history h
            WHERE h.kyc_basic_info_sno = @kyc_basic_info_sno AND h.status = 'R'
              AND UPPER(LTRIM(RTRIM(h.status_by))) = UPPER(LTRIM(RTRIM(@created_by))))
        THROW 58709, N'Only an approver of this KYC can send the supplier a correction link.', 1;

    IF (SELECT COUNT(*) FROM dbo.kyc_resubmit_link l
         WHERE l.kyc_basic_info_sno = @kyc_basic_info_sno AND l.created_date > DATEADD(HOUR, -24, GETDATE())) >= 5
        THROW 58706, N'5 correction links were already sent for this KYC in the last 24 hours. Try again tomorrow.', 1;

    UPDATE dbo.kyc_resubmit_link
       SET closed_date = GETDATE(), closed_reason = 'REPLACED'
     WHERE kyc_basic_info_sno = @kyc_basic_info_sno AND closed_date IS NULL;

    INSERT INTO dbo.kyc_resubmit_link (kyc_basic_info_sno, token_hash, reject_reason, kyc_history_sno, sent_to, created_by, expires_at)
    VALUES (@kyc_basic_info_sno, UPPER(@token_hash), @reason,
            (SELECT TOP 1 h.kyc_history_sno FROM dbo.kyc_history h
              WHERE h.kyc_basic_info_sno = @kyc_basic_info_sno AND h.status = 'R' ORDER BY h.kyc_history_sno DESC),
            @email, LTRIM(RTRIM(@created_by)), DATEADD(DAY, @valid_days, GETDATE()));
    SET @link = SCOPE_IDENTITY();

    COMMIT;

    SELECT l.link_sno, l.kyc_basic_info_sno, @company AS company_name, l.sent_to, l.reject_reason, l.expires_at, l.created_date
    FROM dbo.kyc_resubmit_link l
    WHERE l.link_sno = @link;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_KycResubmitMarkEmail
    @link_sno INT,
    @sent     BIT,
    @note     NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.kyc_resubmit_link
       SET email_sent = CASE WHEN @sent = 1 THEN 'Y' ELSE 'N' END,
           email_note = CASE WHEN @sent = 1 THEN NULL ELSE LEFT(@note, 300) END
     WHERE link_sno = @link_sno;
END
GO

-- Staff: the latest link of a KYC and the latest resubmission (never the token - it is not stored).
CREATE OR ALTER PROCEDURE dbo.sp_nt_KycResubmitLinkStatus
    @kyc_basic_info_sno INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 l.link_sno, l.sent_to, l.email_sent, l.email_note, l.reject_reason, l.created_by, l.created_date,
           l.expires_at, l.opened_date, l.used_date, l.closed_reason,
           CASE WHEN l.used_date IS NOT NULL THEN 'USED'
                WHEN l.closed_date IS NOT NULL THEN 'REPLACED'
                WHEN l.expires_at < GETDATE() THEN 'EXPIRED'
                ELSE 'OPEN' END AS link_state,
           (SELECT COUNT(*) FROM dbo.kyc_resubmission r WHERE r.kyc_basic_info_sno = l.kyc_basic_info_sno) AS resubmit_count
    FROM dbo.kyc_resubmit_link l
    WHERE l.kyc_basic_info_sno = @kyc_basic_info_sno
    ORDER BY l.link_sno DESC;
END
GO

-- ------------------------------------------------------------
-- sp_nt_KycResubmitFindLink (internal): the token's link, or the error the supplier sees. @lock = 1 inside the save.
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_nt_KycResubmitFindLink
    @token_hash         CHAR(64),
    @lock               BIT = 0,
    @link_sno           INT OUTPUT,
    @kyc_basic_info_sno INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @expires DATETIME, @used DATETIME, @closed DATETIME, @status CHAR(1);
    SELECT @link_sno = NULL, @kyc_basic_info_sno = NULL;

    IF @lock = 1
        SELECT @link_sno = l.link_sno, @kyc_basic_info_sno = l.kyc_basic_info_sno,
               @expires = l.expires_at, @used = l.used_date, @closed = l.closed_date
        FROM dbo.kyc_resubmit_link l WITH (UPDLOCK, HOLDLOCK)
        WHERE l.token_hash = UPPER(@token_hash);
    ELSE
        SELECT @link_sno = l.link_sno, @kyc_basic_info_sno = l.kyc_basic_info_sno,
               @expires = l.expires_at, @used = l.used_date, @closed = l.closed_date
        FROM dbo.kyc_resubmit_link l
        WHERE l.token_hash = UPPER(@token_hash);

    IF @link_sno IS NULL
        THROW 58710, N'This link is not valid. Open the latest link we e-mailed you, or ask our purchase team to send a new one.', 1;
    IF @used IS NOT NULL
        THROW 58711, N'Your corrected KYC has already been sent with this link. We will e-mail you once it is reviewed.', 1;
    IF @closed IS NOT NULL
        THROW 58712, N'A newer link was sent for this KYC. Open the latest link in your e-mail.', 1;
    IF @expires < GETDATE()
        THROW 58713, N'This link has expired. Ask our purchase team to send you a new one.', 1;

    SELECT @status = k.status FROM dbo.kyc_basic_info k WHERE k.kyc_basic_info_sno = @kyc_basic_info_sno;
    IF ISNULL(@status, '') <> 'R'
        THROW 58714, N'This KYC is no longer waiting for your correction.', 1;
END
GO

-- Is this link usable? Returns the KYC id or throws the error the supplier sees. Reads only - nothing is marked.
CREATE OR ALTER PROCEDURE dbo.sp_nt_KycResubmitCheck
    @token_hash CHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @link INT, @k INT;
    EXEC dbo.sp_nt_KycResubmitFindLink @token_hash = @token_hash, @lock = 0, @link_sno = @link OUTPUT, @kyc_basic_info_sno = @k OUTPUT;
    SELECT @link AS link_sno, @k AS kyc_basic_info_sno;
END
GO

-- ------------------------------------------------------------
-- sp_nt_KycResubmitOpen: what the correction page shows.
--   RS1 link + company details, RS2 addresses, RS3 bank accounts, RS4 contacts, RS5 documents on file (names only),
--   RS6 business types, RS7 bank account types, RS8 supplier categories (choices for the form).
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_nt_KycResubmitOpen
    @token_hash CHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @link INT, @k INT;
    EXEC dbo.sp_nt_KycResubmitFindLink @token_hash = @token_hash, @lock = 0, @link_sno = @link OUTPUT, @kyc_basic_info_sno = @k OUTPUT;

    UPDATE dbo.kyc_resubmit_link SET opened_date = GETDATE() WHERE link_sno = @link AND opened_date IS NULL;

    SELECT l.link_sno, l.reject_reason, l.created_date AS rejected_date, l.expires_at,
           k.kyc_basic_info_sno,
           NULLIF(LTRIM(RTRIM(k.company_name)), '') AS company_name, NULLIF(LTRIM(RTRIM(k.legal_name)), '') AS legal_name,
           NULLIF(LTRIM(RTRIM(k.trade_name)), '') AS trade_name, NULLIF(LTRIM(RTRIM(k.contact_person)), '') AS contact_person,
           NULLIF(LTRIM(RTRIM(k.email)), '') AS email, NULLIF(LTRIM(RTRIM(k.mobile_number)), '') AS mobile_number,
           NULLIF(LTRIM(RTRIM(k.business_type)), '') AS business_type, NULLIF(LTRIM(RTRIM(k.supplier_cat_code)), '') AS supplier_cat_code,
           NULLIF(LTRIM(RTRIM(k.pan_no)), '') AS pan_no,
           ISNULL(k.is_gst_avail, 'N') AS is_gst_avail, NULLIF(LTRIM(RTRIM(k.gst_no)), '') AS gst_no,
           ISNULL(k.is_msme_avail, 'N') AS is_msme_avail, NULLIF(LTRIM(RTRIM(k.msme_no)), '') AS msme_no,
           NULLIF(LTRIM(RTRIM(k.msme_type)), '') AS msme_type,
           ISNULL(k.pay_via_portal, 'N') AS pay_via_portal, k.payment_portal_name, k.payment_portal_url, k.payment_instructions
    FROM dbo.kyc_resubmit_link l
    JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = l.kyc_basic_info_sno
    WHERE l.link_sno = @link;

    SELECT a.kyc_address_sno, a.door_no, a.street, a.area, a.city, a.taluk, a.state, a.state_code, a.pincode, a.location_link,
           CASE WHEN a.is_primary = 'Y' OR a.address_type = 'PRIMARY' THEN 'Y' ELSE 'N' END AS is_primary
    FROM dbo.kyc_address_info a
    WHERE a.kyc_basic_info_sno = @k AND ISNULL(a.is_active, 'Y') <> 'N'
    ORDER BY a.kyc_address_sno;

    SELECT b.kyc_address_sno AS kyc_bank_sno, b.ac_holder_name, CAST(b.ac_number AS VARCHAR(30)) AS ac_number, b.ac_type,
           b.ifsc, b.bank_name, b.bank_branch_name, b.bank_address, ISNULL(b.is_primary, 'N') AS is_primary
    FROM dbo.kyc_bank_info b
    WHERE b.kyc_basic_info_sno = @k AND ISNULL(b.is_active, 'Y') <> 'N'
    ORDER BY b.kyc_address_sno;

    SELECT c.kyc_contact_sno, c.contact_name, c.contact_position, c.contact_mobile, c.contact_email,
           CASE WHEN c.contact_type = 'PRIMARY' THEN 'Y' ELSE 'N' END AS is_primary
    FROM dbo.kyc_contact_info c
    WHERE c.kyc_basic_info_sno = @k AND ISNULL(c.is_active, 'Y') <> 'N'
    ORDER BY c.kyc_contact_sno;

    SELECT d.kyc_document_sno, d.document_type, d.document_name, d.file_size, d.uploaded_date
    FROM dbo.kyc_document_info d
    WHERE d.kyc_basic_info_sno = @k AND ISNULL(d.is_active, 'Y') <> 'N'
    ORDER BY d.kyc_document_sno;

    SELECT CAST(business_types_id AS VARCHAR(20)) AS value, business_types_name AS label
    FROM dbo.business_types WHERE IsActive = 1 ORDER BY business_types_id;

    SELECT CAST(bank_account_type_sno AS VARCHAR(20)) AS value, account_type_name AS label
    FROM dbo.bank_account_type_master WHERE is_active = 'Y' ORDER BY bank_account_type_sno;

    SELECT supp_cat_code AS value, supp_cat_name AS label
    FROM dbo.supplier_category WHERE is_active = 'Y' ORDER BY supp_cat_name;
END
GO

-- ------------------------------------------------------------
-- sp_nt_KycResubmitSave: write the corrected KYC and send it for approval again.
--   @payload   { note, basic{...}, addresses[{kyc_address_sno?...}], banks[{kyc_bank_sno?...}], contacts[{kyc_contact_sno?...}] }
--              already checked by the backend (formats, lengths, exactly one primary per list)
--   @documents [{ document_type, document_name, document_path, file_size }] - files already checked and on the FTP server
--   @files_json what was uploaded (kept for the record)
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_nt_KycResubmitSave
    @token_hash CHAR(64),
    @payload    NVARCHAR(MAX),
    @documents  NVARCHAR(MAX) = N'[]',
    @files_json NVARCHAR(MAX) = NULL,
    @client_ip  VARCHAR(45)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISJSON(@payload) = 0 OR JSON_QUERY(@payload, '$.basic') IS NULL
        THROW 58730, N'The form could not be read. Reload the page and try again.', 1;
    SET @documents = ISNULL(NULLIF(@documents, N''), N'[]');
    IF ISJSON(@documents) = 0
        THROW 58730, N'The form could not be read. Reload the page and try again.', 1;

    DECLARE @link INT, @k INT, @wf INT, @approver VARCHAR(30), @old NVARCHAR(MAX), @hist INT, @resub INT;

    -- the new company details
    DECLARE @company_name NVARCHAR(50), @legal_name VARCHAR(100), @trade_name VARCHAR(100), @contact_person NVARCHAR(50),
            @email NVARCHAR(50), @mobile VARCHAR(15), @business_type NVARCHAR(50), @supplier_cat VARCHAR(20), @pan VARCHAR(20),
            @is_gst CHAR(1), @gst VARCHAR(20), @is_msme CHAR(1), @msme VARCHAR(20), @msme_type VARCHAR(20),
            @portal CHAR(1), @portal_name NVARCHAR(150), @portal_url NVARCHAR(500), @portal_instr NVARCHAR(1000),
            @note NVARCHAR(500);
    SELECT @company_name   = NULLIF(LTRIM(RTRIM(company_name)), N''),
           @legal_name     = NULLIF(LTRIM(RTRIM(legal_name)), ''),
           @trade_name     = NULLIF(LTRIM(RTRIM(trade_name)), ''),
           @contact_person = NULLIF(LTRIM(RTRIM(contact_person)), N''),
           @email          = NULLIF(LTRIM(RTRIM(email)), N''),
           @mobile         = NULLIF(LTRIM(RTRIM(mobile_number)), ''),
           @business_type  = NULLIF(LTRIM(RTRIM(business_type)), N''),
           @supplier_cat   = NULLIF(LTRIM(RTRIM(supplier_cat_code)), ''),
           @pan            = UPPER(NULLIF(LTRIM(RTRIM(pan_no)), '')),
           @is_gst         = CASE WHEN is_gst_avail = 'Y' THEN 'Y' ELSE 'N' END,
           @gst            = UPPER(NULLIF(LTRIM(RTRIM(gst_no)), '')),
           @is_msme        = CASE WHEN is_msme_avail = 'Y' THEN 'Y' ELSE 'N' END,
           @msme           = UPPER(NULLIF(LTRIM(RTRIM(msme_no)), '')),
           @msme_type      = NULLIF(LTRIM(RTRIM(msme_type)), ''),
           @portal         = CASE WHEN pay_via_portal = 'Y' THEN 'Y' ELSE 'N' END,
           @portal_name    = NULLIF(LTRIM(RTRIM(payment_portal_name)), N''),
           @portal_url     = NULLIF(LTRIM(RTRIM(payment_portal_url)), N''),
           @portal_instr   = NULLIF(LTRIM(RTRIM(payment_instructions)), N'')
    FROM OPENJSON(@payload, '$.basic') WITH (
        company_name NVARCHAR(50), legal_name VARCHAR(100), trade_name VARCHAR(100), contact_person NVARCHAR(50),
        email NVARCHAR(50), mobile_number VARCHAR(15), business_type NVARCHAR(50), supplier_cat_code VARCHAR(20),
        pan_no VARCHAR(20), is_gst_avail CHAR(1), gst_no VARCHAR(20), is_msme_avail CHAR(1), msme_no VARCHAR(20),
        msme_type VARCHAR(20), pay_via_portal CHAR(1), payment_portal_name NVARCHAR(150), payment_portal_url NVARCHAR(500),
        payment_instructions NVARCHAR(1000));
    SET @note = NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload, '$.note'))), N'');
    IF @is_gst = 'N' SET @gst = NULL;
    IF @is_msme = 'N' SELECT @msme = NULL, @msme_type = NULL;
    IF @portal = 'N' SELECT @portal_name = NULL, @portal_url = NULL, @portal_instr = NULL;

    IF @company_name IS NULL OR @contact_person IS NULL OR @email IS NULL OR @mobile IS NULL OR @business_type IS NULL OR @pan IS NULL
       OR (@is_gst = 'Y' AND @gst IS NULL) OR (@is_msme = 'Y' AND @msme IS NULL) OR (@portal = 'Y' AND (@portal_name IS NULL OR @portal_url IS NULL))
        THROW 58731, N'Some required company details are missing. Fill every field marked * and try again.', 1;

    BEGIN TRAN;

    EXEC dbo.sp_nt_KycResubmitFindLink @token_hash = @token_hash, @lock = 1, @link_sno = @link OUTPUT, @kyc_basic_info_sno = @k OUTPUT;
    -- hold the KYC too, so two saves (or a staff action) cannot interleave
    IF NOT EXISTS (SELECT 1 FROM dbo.kyc_basic_info WITH (UPDLOCK, HOLDLOCK) WHERE kyc_basic_info_sno = @k AND status = 'R')
        THROW 58714, N'This KYC is no longer waiting for your correction.', 1;

    -- the same duplicate rule as a new KYC: GST number when registered, otherwise PAN (another approved / pending KYC)
    IF @is_gst = 'Y' AND EXISTS (SELECT 1 FROM dbo.kyc_basic_info x WHERE x.kyc_basic_info_sno <> @k AND x.is_active = 'Y'
                                    AND x.status IN ('A', 'P') AND x.gst_no = @gst)
        THROW 58732, N'Another supplier with this GST number is already registered with us or waiting for approval. Contact our purchase team.', 1;
    IF @is_gst = 'N' AND EXISTS (SELECT 1 FROM dbo.kyc_basic_info x WHERE x.kyc_basic_info_sno <> @k AND x.is_active = 'Y'
                                    AND x.status IN ('A', 'P') AND x.pan_no = @pan)
        THROW 58733, N'Another supplier with this PAN is already registered with us or waiting for approval. Contact our purchase team.', 1;

    -- every row the form names must be one of this KYC's active rows
    IF EXISTS (SELECT 1 FROM OPENJSON(@payload, '$.addresses') WITH (sno INT '$.kyc_address_sno') j
                WHERE j.sno IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.kyc_address_info a WHERE a.kyc_address_sno = j.sno
                                                          AND a.kyc_basic_info_sno = @k AND ISNULL(a.is_active, 'Y') <> 'N'))
       OR EXISTS (SELECT 1 FROM OPENJSON(@payload, '$.banks') WITH (sno INT '$.kyc_bank_sno') j
                WHERE j.sno IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.kyc_bank_info b WHERE b.kyc_address_sno = j.sno
                                                          AND b.kyc_basic_info_sno = @k AND ISNULL(b.is_active, 'Y') <> 'N'))
       OR EXISTS (SELECT 1 FROM OPENJSON(@payload, '$.contacts') WITH (sno INT '$.kyc_contact_sno') j
                WHERE j.sno IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.kyc_contact_info c WHERE c.kyc_contact_sno = j.sno
                                                          AND c.kyc_basic_info_sno = @k AND ISNULL(c.is_active, 'Y') <> 'N'))
        THROW 58734, N'This form no longer matches your KYC. Reload the page and make your corrections again.', 1;

    -- back to the first approver of the KYC workflow as it is configured today (same lookup as sp_InsertKYCData)
    SET @wf = dbo.fn_scopeless_workflow_types(dbo.fn_resolve_approval_entity('KYC', 'SUPPLIER'));
    SELECT @approver = NULLIF(LTRIM(RTRIM(JSON_VALUE(s2.value, '$.approver_ecno'))), '')
    FROM dbo.vw_workflow_stages AS ws
    CROSS APPLY OPENJSON(ws.stages_json) AS s
    CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
    WHERE ws.workflow_types_id = @wf AND s.[key] = '0' AND s2.[key] = '0';
    IF @wf IS NULL OR @approver IS NULL
        THROW 58735, N'KYC approval is not set up at the moment, so your KYC cannot be sent. Please try again later or contact our purchase team.', 1;

    SET @old = ISNULL(dbo.fn_nt_KycSnapshot(@k), N'{}');

    -- company details
    UPDATE k SET
        company_name = @company_name, legal_name = @legal_name, trade_name = @trade_name, contact_person = @contact_person,
        email = @email, mobile_number = @mobile, business_type = @business_type, supplier_cat_code = @supplier_cat,
        pan_no = @pan, is_gst_avail = @is_gst, gst_no = @gst, is_msme_avail = @is_msme, msme_no = @msme, msme_type = @msme_type,
        pay_via_portal = @portal, payment_portal_name = @portal_name, payment_portal_url = @portal_url, payment_instructions = @portal_instr,
        -- what was fetched for the old GST / PAN does not describe the new one
        gst_status     = CASE WHEN ISNULL(k.gst_no, '') = ISNULL(@gst, '') THEN k.gst_status END,
        gst_blk_status = CASE WHEN ISNULL(k.gst_no, '') = ISNULL(@gst, '') THEN k.gst_blk_status END,
        txp_type       = CASE WHEN ISNULL(k.gst_no, '') = ISNULL(@gst, '') THEN k.txp_type END,
        date_of_reg    = CASE WHEN ISNULL(k.gst_no, '') = ISNULL(@gst, '') THEN k.date_of_reg END,
        pan_status     = CASE WHEN ISNULL(k.pan_no, '') = @pan THEN k.pan_status END,
        status = 'P', workflow_types_id = @wf, approver_ecno = @approver,
        modified_by = 'SUPPLIER', modified_date = GETDATE()
    FROM dbo.kyc_basic_info k
    WHERE k.kyc_basic_info_sno = @k;

    -- addresses: left out -> inactive, kept -> updated, new -> added
    DECLARE @addr TABLE (sno INT NULL, door_no NVARCHAR(300), street NVARCHAR(200), area NVARCHAR(200), city NVARCHAR(200),
                         taluk NVARCHAR(200), state NVARCHAR(200), state_code INT, pincode VARCHAR(10), location_link NVARCHAR(500), is_primary CHAR(1));
    INSERT @addr
    SELECT kyc_address_sno, door_no, street, area, city, NULLIF(LTRIM(RTRIM(taluk)), N''), state, TRY_CONVERT(INT, state_code), pincode,
           NULLIF(LTRIM(RTRIM(location_link)), N''), CASE WHEN is_primary = 'Y' THEN 'Y' ELSE 'N' END
    FROM OPENJSON(@payload, '$.addresses') WITH (kyc_address_sno INT, door_no NVARCHAR(300), street NVARCHAR(200), area NVARCHAR(200),
        city NVARCHAR(200), taluk NVARCHAR(200), state NVARCHAR(200), state_code NVARCHAR(10), pincode VARCHAR(10),
        location_link NVARCHAR(500), is_primary CHAR(1));

    UPDATE a SET is_active = 'N'
    FROM dbo.kyc_address_info a
    WHERE a.kyc_basic_info_sno = @k AND ISNULL(a.is_active, 'Y') <> 'N'
      AND NOT EXISTS (SELECT 1 FROM @addr j WHERE j.sno = a.kyc_address_sno);
    UPDATE a SET door_no = j.door_no, street = j.street, area = j.area, city = j.city, taluk = j.taluk, state = j.state,
                 state_code = j.state_code, pincode = j.pincode, location_link = j.location_link, is_primary = j.is_primary,
                 address_type = CASE WHEN j.is_primary = 'Y' THEN 'PRIMARY' ELSE 'SECONDARY' END, status = 'P'
    FROM dbo.kyc_address_info a JOIN @addr j ON j.sno = a.kyc_address_sno
    WHERE a.kyc_basic_info_sno = @k;
    INSERT INTO dbo.kyc_address_info (kyc_basic_info_sno, address_type, door_no, street, area, city, taluk, state, state_code,
                                      pincode, location_link, is_primary, created_date, is_active, status)
    SELECT @k, CASE WHEN j.is_primary = 'Y' THEN 'PRIMARY' ELSE 'SECONDARY' END, j.door_no, j.street, j.area, j.city, j.taluk,
           j.state, j.state_code, j.pincode, j.location_link, j.is_primary, GETDATE(), 'Y', 'P'
    FROM @addr j WHERE j.sno IS NULL;

    -- bank accounts (all inactive when the supplier is paid through its portal)
    DECLARE @bank TABLE (sno INT NULL, ac_holder_name NVARCHAR(50), ac_number BIGINT, ac_type NVARCHAR(50), ifsc NVARCHAR(50),
                         bank_name NVARCHAR(50), bank_branch_name NVARCHAR(50), bank_address VARCHAR(300), is_primary CHAR(1));
    IF @portal = 'N'
        INSERT @bank
        SELECT kyc_bank_sno, ac_holder_name, TRY_CONVERT(BIGINT, ac_number), ac_type, UPPER(ifsc), bank_name, bank_branch_name,
               bank_address, CASE WHEN is_primary = 'Y' THEN 'Y' ELSE 'N' END
        FROM OPENJSON(@payload, '$.banks') WITH (kyc_bank_sno INT, ac_holder_name NVARCHAR(50), ac_number VARCHAR(30),
            ac_type NVARCHAR(50), ifsc NVARCHAR(50), bank_name NVARCHAR(50), bank_branch_name NVARCHAR(50),
            bank_address VARCHAR(300), is_primary CHAR(1));
    IF EXISTS (SELECT 1 FROM @bank WHERE ac_number IS NULL OR ac_holder_name IS NULL OR ifsc IS NULL OR bank_name IS NULL
                                     OR bank_branch_name IS NULL OR ac_type IS NULL)
        THROW 58736, N'A bank account is missing its details. Fill every bank field marked * and try again.', 1;

    UPDATE b SET is_active = 'N'
    FROM dbo.kyc_bank_info b
    WHERE b.kyc_basic_info_sno = @k AND ISNULL(b.is_active, 'Y') <> 'N'
      AND NOT EXISTS (SELECT 1 FROM @bank j WHERE j.sno = b.kyc_address_sno);
    UPDATE b SET ac_holder_name = j.ac_holder_name, ac_number = j.ac_number, ac_type = j.ac_type, ifsc = j.ifsc,
                 bank_name = j.bank_name, bank_branch_name = j.bank_branch_name, bank_address = j.bank_address,
                 is_primary = j.is_primary, status = 'P'
    FROM dbo.kyc_bank_info b JOIN @bank j ON j.sno = b.kyc_address_sno
    WHERE b.kyc_basic_info_sno = @k;
    INSERT INTO dbo.kyc_bank_info (kyc_basic_info_sno, ac_holder_name, ac_number, ac_type, ifsc, bank_name, bank_branch_name,
                                   bank_address, is_primary, created_date, is_active, status)
    SELECT @k, j.ac_holder_name, j.ac_number, j.ac_type, j.ifsc, j.bank_name, j.bank_branch_name, j.bank_address, j.is_primary,
           GETDATE(), 'Y', 'P'
    FROM @bank j WHERE j.sno IS NULL;

    -- contacts
    DECLARE @contact TABLE (sno INT NULL, contact_name VARCHAR(50), contact_position VARCHAR(50), contact_mobile VARCHAR(15),
                            contact_email VARCHAR(50), is_primary CHAR(1));
    INSERT @contact
    SELECT kyc_contact_sno, contact_name, NULLIF(LTRIM(RTRIM(contact_position)), ''), contact_mobile, contact_email,
           CASE WHEN is_primary = 'Y' THEN 'Y' ELSE 'N' END
    FROM OPENJSON(@payload, '$.contacts') WITH (kyc_contact_sno INT, contact_name VARCHAR(50), contact_position VARCHAR(50),
        contact_mobile VARCHAR(15), contact_email VARCHAR(50), is_primary CHAR(1));

    UPDATE c SET is_active = 'N'
    FROM dbo.kyc_contact_info c
    WHERE c.kyc_basic_info_sno = @k AND ISNULL(c.is_active, 'Y') <> 'N'
      AND NOT EXISTS (SELECT 1 FROM @contact j WHERE j.sno = c.kyc_contact_sno);
    UPDATE c SET contact_name = j.contact_name, contact_position = j.contact_position, contact_mobile = j.contact_mobile,
                 contact_email = j.contact_email, contact_type = CASE WHEN j.is_primary = 'Y' THEN 'PRIMARY' ELSE 'SECONDARY' END,
                 status = 'P'
    FROM dbo.kyc_contact_info c JOIN @contact j ON j.sno = c.kyc_contact_sno
    WHERE c.kyc_basic_info_sno = @k;
    INSERT INTO dbo.kyc_contact_info (kyc_basic_info_sno, contact_type, contact_name, contact_position, contact_mobile,
                                      contact_email, created_date, is_active, status)
    SELECT @k, CASE WHEN j.is_primary = 'Y' THEN 'PRIMARY' ELSE 'SECONDARY' END, j.contact_name, j.contact_position,
           j.contact_mobile, j.contact_email, GETDATE(), 'Y', 'P'
    FROM @contact j WHERE j.sno IS NULL;

    -- documents: a new one replaces the one on file of its type ("other_file" only adds)
    DECLARE @doc TABLE (document_type VARCHAR(20), document_name NVARCHAR(255), document_path NVARCHAR(500), file_size BIGINT);
    INSERT @doc
    SELECT document_type, document_name, document_path, file_size
    FROM OPENJSON(@documents) WITH (document_type VARCHAR(20), document_name NVARCHAR(255), document_path NVARCHAR(500), file_size BIGINT)
    WHERE NULLIF(document_path, N'') IS NOT NULL AND NULLIF(document_type, '') IS NOT NULL;

    UPDATE d SET is_active = 'N'
    FROM dbo.kyc_document_info d
    WHERE d.kyc_basic_info_sno = @k AND ISNULL(d.is_active, 'Y') <> 'N' AND d.document_type <> 'other_file'
      AND EXISTS (SELECT 1 FROM @doc j WHERE j.document_type = d.document_type);
    INSERT INTO dbo.kyc_document_info (kyc_basic_info_sno, document_type, document_name, document_path, file_size, uploaded_date, is_active, status)
    SELECT @k, j.document_type, j.document_name, j.document_path, j.file_size, GETDATE(), 'Y', 'P'
    FROM @doc j;

    -- what a KYC must have, checked on the result
    IF NOT EXISTS (SELECT 1 FROM dbo.kyc_address_info WHERE kyc_basic_info_sno = @k AND ISNULL(is_active, 'Y') <> 'N')
        THROW 58737, N'Add at least one address.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.kyc_contact_info WHERE kyc_basic_info_sno = @k AND ISNULL(is_active, 'Y') <> 'N')
        THROW 58737, N'Add at least one contact.', 1;
    IF @portal = 'N' AND NOT EXISTS (SELECT 1 FROM dbo.kyc_bank_info WHERE kyc_basic_info_sno = @k AND ISNULL(is_active, 'Y') <> 'N')
        THROW 58737, N'Add your bank account, or choose to be paid through your own portal.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.kyc_document_info WHERE kyc_basic_info_sno = @k AND ISNULL(is_active, 'Y') <> 'N'
                    AND document_type = 'pan_file')
        THROW 58738, N'Upload your PAN card.', 1;

    -- the link is spent; any other open link of this KYC is closed
    UPDATE dbo.kyc_resubmit_link SET used_date = GETDATE(), closed_date = GETDATE(), closed_reason = 'RESUBMITTED' WHERE link_sno = @link;
    UPDATE dbo.kyc_resubmit_link SET closed_date = GETDATE(), closed_reason = 'REPLACED'
     WHERE kyc_basic_info_sno = @k AND closed_date IS NULL;

    INSERT INTO dbo.kyc_history (kyc_basic_info_sno, kyc_edit_data, is_active, approver_ecno, status, status_by, status_date)
    VALUES (@k, NULL, 'Y', @approver, 'S', 'SUPPLIER', GETDATE());
    SET @hist = SCOPE_IDENTITY();

    INSERT INTO dbo.kyc_resubmission (kyc_basic_info_sno, link_sno, kyc_history_sno, supplier_note, old_data, new_data, files_json, client_ip)
    VALUES (@k, @link, @hist, @note, @old, ISNULL(dbo.fn_nt_KycSnapshot(@k), N'{}'),
            CASE WHEN ISJSON(@files_json) = 1 THEN @files_json END, LEFT(@client_ip, 45));
    SET @resub = SCOPE_IDENTITY();

    COMMIT;

    SELECT k.kyc_basic_info_sno, COALESCE(NULLIF(LTRIM(RTRIM(k.company_name)), ''), k.legal_name, k.trade_name) AS company_name,
           k.approver_ecno, k.workflow_types_id, @resub AS resubmission_sno,
           (SELECT COUNT(*) FROM dbo.kyc_resubmission r WHERE r.kyc_basic_info_sno = @k) AS resubmit_count
    FROM dbo.kyc_basic_info k
    WHERE k.kyc_basic_info_sno = @k;
END
GO
