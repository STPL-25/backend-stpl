-- 112: Supplier Quotation — Payment Terms master, freight / other charges (quotation level),
-- supplier MSME flag + type, intrastate (CGST+SGST) vs interstate (IGST), and GST wording.
--  * payment_terms_master (+ Get/Create/Update/Delete SPs, seeded with the old hard-coded list).
--    The quotation keeps storing the terms TEXT in supplier_quotation_info.payment_terms (same as before).
--  * supplier_quotation_info: freight_charges, other_charges, is_msme (Y/N), msme_type, is_intrastate.
--  * sp_nt_CreateSupplierQuotation persists them; sp_nt_GetSupplierQuotations returns them via sq.*
--    (and drops its hard-coded [Non_trade_Dev] reference).
--  * vw_get_kyc / vw_get_supplier_quotation refreshed: both select * and had stale column metadata
--    (vw_get_kyc was missing msme_type / pay_via_portal), so the vendor list could not expose msme_type.
-- Originals backed up in sql/backups/quotation_charges_2026-10-01. Re-runnable.

IF OBJECT_ID('dbo.payment_terms_master','U') IS NULL
CREATE TABLE dbo.payment_terms_master (
    payment_terms_sno  INT IDENTITY(1,1) PRIMARY KEY,
    payment_terms_code VARCHAR(30)   NOT NULL,
    payment_terms_name NVARCHAR(200) NOT NULL,
    is_active          CHAR(1)       NOT NULL DEFAULT 'Y',
    created_by         VARCHAR(20)   NULL,
    created_at         DATETIME      NOT NULL DEFAULT GETDATE(),
    modified_by        VARCHAR(20)   NULL,
    modified_at        DATETIME      NULL,
    CONSTRAINT UQ_payment_terms_master_code UNIQUE (payment_terms_code),
    CONSTRAINT UQ_payment_terms_master_name UNIQUE (payment_terms_name)
);
GO
IF NOT EXISTS (SELECT 1 FROM dbo.payment_terms_master)
INSERT INTO dbo.payment_terms_master (payment_terms_code, payment_terms_name, created_by) VALUES
 ('NET30',N'Net 30','system'),('NET45',N'Net 45','system'),('NET60',N'Net 60','system'),
 ('ADV100',N'Advance 100%','system'),('ADV50',N'Advance 50%, Balance on Delivery','system'),('ONDEL',N'On Delivery','system');
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentTermsRecords
AS
BEGIN
    SET NOCOUNT ON;
    SELECT payment_terms_sno, payment_terms_code, payment_terms_name, is_active
    FROM dbo.payment_terms_master WHERE is_active = 'Y' ORDER BY payment_terms_sno;
END
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreatePaymentTermsRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 50001, N'Invalid JSON payload provided.', 1;
    DECLARE @code NVARCHAR(30)  = LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.payment_terms_code'))),
            @name NVARCHAR(200) = LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.payment_terms_name'))),
            @by   VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
    IF ISNULL(@code,'') = '' OR ISNULL(@name,'') = '' THROW 50002, N'payment_terms_code and payment_terms_name are required.', 1;
    IF EXISTS (SELECT 1 FROM dbo.payment_terms_master WHERE payment_terms_code = @code) THROW 50003, N'A payment term with this code already exists.', 1;
    IF EXISTS (SELECT 1 FROM dbo.payment_terms_master WHERE payment_terms_name = @name) THROW 50004, N'A payment term with this name already exists.', 1;
    INSERT INTO dbo.payment_terms_master (payment_terms_code, payment_terms_name, created_by) VALUES (@code, @name, @by);
    SELECT SCOPE_IDENTITY() AS payment_terms_sno, @code AS payment_terms_code, N'SUCCESS' AS status, N'Payment term created successfully.' AS message;
END
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdatePaymentTermsRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_terms_sno') AS INT);
    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.payment_terms_master WHERE payment_terms_sno = @id)
    BEGIN RAISERROR('Payment term not found.', 16, 1); RETURN; END
    UPDATE dbo.payment_terms_master
    SET payment_terms_code = ISNULL(JSON_VALUE(@jsonInput, '$.payment_terms_code'), payment_terms_code),
        payment_terms_name = ISNULL(JSON_VALUE(@jsonInput, '$.payment_terms_name'), payment_terms_name),
        modified_by = JSON_VALUE(@jsonInput, '$.modified_by'), modified_at = GETDATE()
    WHERE payment_terms_sno = @id;
    SELECT * FROM dbo.payment_terms_master WHERE payment_terms_sno = @id;
END
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_DeletePaymentTermsRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.payment_terms_master WHERE payment_terms_sno = @id)
    BEGIN RAISERROR('Payment term not found.', 16, 1); RETURN; END
    UPDATE dbo.payment_terms_master SET is_active = 'N', modified_at = GETDATE() WHERE payment_terms_sno = @id;
    SELECT @id AS payment_terms_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO
IF COL_LENGTH('dbo.supplier_quotation_info','freight_charges') IS NULL ALTER TABLE dbo.supplier_quotation_info ADD freight_charges DECIMAL(18,2) NOT NULL CONSTRAINT DF_sqi_freight DEFAULT 0;
IF COL_LENGTH('dbo.supplier_quotation_info','other_charges')   IS NULL ALTER TABLE dbo.supplier_quotation_info ADD other_charges   DECIMAL(18,2) NOT NULL CONSTRAINT DF_sqi_other   DEFAULT 0;
IF COL_LENGTH('dbo.supplier_quotation_info','is_msme')         IS NULL ALTER TABLE dbo.supplier_quotation_info ADD is_msme CHAR(1) NULL;
IF COL_LENGTH('dbo.supplier_quotation_info','msme_type')       IS NULL ALTER TABLE dbo.supplier_quotation_info ADD msme_type VARCHAR(20) NULL;
IF COL_LENGTH('dbo.supplier_quotation_info','is_intrastate')   IS NULL ALTER TABLE dbo.supplier_quotation_info ADD is_intrastate BIT NULL;
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateSupplierQuotation
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRAN;

        IF ISJSON(@jsonInput) <> 1
        BEGIN
            RAISERROR('Invalid JSON input.', 16, 1);
            RETURN;
        END;

        DECLARE @sq_basic_sno INT;
        DECLARE @sq_adv_sno   INT = NULL;

        DECLARE
            @pr_basic_sno             INT,
            @pr_no                    VARCHAR(50),
            @vendor_sno               INT,
            @quotation_ref_no         NVARCHAR(100),
            @quotation_date           DATE,
            @valid_upto               DATE,
            @currency_code            NVARCHAR(20),
            @payment_terms            NVARCHAR(500),
            @delivery_days            INT,
            @remarks                  NVARCHAR(1000),
            @created_by               NVARCHAR(50),
            @workflow_types_id        INT,
            @status                   NVARCHAR(50),
            @is_selected              BIT,
            @is_active                BIT,
            @com_sno                  INT,
            @div_sno                  INT,
            @brn_sno                  INT,
            @dept_sno                 INT,
            @first_approver           VARCHAR(20),
            @workflow_id              INT,
            @sq_quotation_file        NVARCHAR(500),
            @freight_charges          DECIMAL(18,2),
            @other_charges            DECIMAL(18,2),
            @is_msme                  CHAR(1),
            @msme_type                VARCHAR(20),
            @is_intrastate            BIT,

            -- New quotation info fields
            @buyback_available         BIT,
            @buyback_value            DECIMAL(18,3),
            @advance_payment_required  BIT,
            @advance_payment_pct      DECIMAL(10,3),

            -- Advance table fields
            @adv_gst_applicable       CHAR(1),
            @adv_gst_pct              DECIMAL(10,3),
            @adv_reason               VARCHAR(200),
            @adv_note                 VARCHAR(200),
            @adv_issue_stages         NVARCHAR(MAX);

        SELECT
            @pr_basic_sno             = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT),
            @pr_no                    = JSON_VALUE(@jsonInput, '$.pr_no'),
            @vendor_sno               = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
            @quotation_ref_no         = JSON_VALUE(@jsonInput, '$.quotation_ref_no'),
            @quotation_date           = TRY_CAST(JSON_VALUE(@jsonInput, '$.quotation_date') AS DATE),
            @valid_upto               = TRY_CAST(JSON_VALUE(@jsonInput, '$.valid_upto') AS DATE),
            @currency_code            = JSON_VALUE(@jsonInput, '$.currency_code'),
            @payment_terms            = JSON_VALUE(@jsonInput, '$.payment_terms'),
            @delivery_days            = TRY_CAST(JSON_VALUE(@jsonInput, '$.delivery_days') AS INT),
            @remarks                  = JSON_VALUE(@jsonInput, '$.remarks'),
            @created_by               = JSON_VALUE(@jsonInput, '$.created_by'),
            @status                   = ISNULL(JSON_VALUE(@jsonInput, '$.status'), 'P'),
            @is_selected              = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.is_selected') AS BIT), 0),
            @is_active                = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.is_active') AS BIT), 1),
            @com_sno                  = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT),
            @div_sno                  = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT),
            @brn_sno                  = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT),
            @dept_sno                 = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT),
            @sq_quotation_file        = JSON_VALUE(@jsonInput, '$.sq_quotation_file'),
            @freight_charges          = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.freight_charges') AS DECIMAL(18,2)), 0),
            @other_charges            = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.other_charges') AS DECIMAL(18,2)), 0),
            @is_msme                  = CASE WHEN JSON_VALUE(@jsonInput, '$.is_msme') IN ('Y','true','1') THEN 'Y' WHEN JSON_VALUE(@jsonInput, '$.is_msme') IS NULL THEN NULL ELSE 'N' END,
            @msme_type                = NULLIF(JSON_VALUE(@jsonInput, '$.msme_type'), ''),
            @is_intrastate            = TRY_CAST(CASE JSON_VALUE(@jsonInput, '$.is_intrastate') WHEN 'Y' THEN '1' WHEN 'N' THEN '0' ELSE JSON_VALUE(@jsonInput, '$.is_intrastate') END AS BIT),

            @buyback_available        = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.buyback_available') AS BIT), 0),
            @buyback_value            = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.buyback_value') AS DECIMAL(18,3)), 0),
            @advance_payment_required = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.advance_payment_required') AS BIT), 0),
            @advance_payment_pct      = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.advance_payment_pct') AS DECIMAL(10,3)), 0),

            @adv_gst_pct              = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.advance_payment_data.gst_pct') AS DECIMAL(10,3)), 0),
            @adv_reason               = JSON_VALUE(@jsonInput, '$.advance_payment_data.reason'),
            @adv_note                 = JSON_VALUE(@jsonInput, '$.advance_payment_data.note'),
            @adv_issue_stages         = JSON_QUERY(@jsonInput, '$.advance_payment_data.stages');

        SET @adv_gst_applicable =
            CASE
                WHEN ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.advance_payment_data.gst_applicable') AS BIT), 0) = 1 THEN 'Y'
                ELSE 'N'
            END;

        IF @is_msme <> 'Y' SET @msme_type = NULL;
        IF @is_msme = 'Y' AND @msme_type IS NULL
            RAISERROR('MSME type is required when the supplier is an MSME.', 16, 1);
        IF @freight_charges < 0 OR @other_charges < 0
            RAISERROR('Freight / other charges cannot be negative.', 16, 1);

        IF @pr_basic_sno IS NULL
            RAISERROR('pr_basic_sno is required.', 16, 1);

        IF @vendor_sno IS NULL
            RAISERROR('vendor_sno is required.', 16, 1);

        IF @quotation_date IS NULL
            RAISERROR('quotation_date is required.', 16, 1);

        IF NOT EXISTS (SELECT 1 FROM OPENJSON(@jsonInput, '$.items'))
            RAISERROR('At least one item is required.', 16, 1);

        SELECT
            @workflow_id       = wt.workflow_id,
            @workflow_types_id = wt.workflow_types_id
        FROM workflow_types wt
        INNER JOIN approval_workflow_master awm
            ON awm.workflow_id = wt.workflow_id
        WHERE wt.brn_sno      = @brn_sno
          AND wt.dept_sno     = @dept_sno
          AND wt.com_sno      = @com_sno
          AND wt.div_sno      = @div_sno
          AND awm.entity_type = 'PurchaseOrder';

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key]  = '0'
          AND s2.[key] = '0';

        INSERT INTO dbo.supplier_quotation_info
        (
            pr_basic_sno,
            vendor_sno,
            quotation_ref_no,
            quotation_date,
            valid_upto,
            currency_code,
            payment_terms,
            delivery_days,
            remarks,
            buyback_available,
            buyback_value,
            advance_payment_required,
            advance_payment_pct,
            sq_adv_sno,
            is_selected,
            is_active,
            workflow_types_id,
            status,
            created_by,
            created_date,
            modifed_by,
            modifed_date,
            sq_quotation_file,
            pr_no,
            com_sno,
            div_sno,
            brn_sno,
            dept_sno,
            approver_ecno,
            freight_charges,
            other_charges,
            is_msme,
            msme_type,
            is_intrastate
        )
        VALUES
        (
            @pr_basic_sno,
            @vendor_sno,
            @quotation_ref_no,
            @quotation_date,
            @valid_upto,
            @currency_code,
            @payment_terms,
            @delivery_days,
            @remarks,
            @buyback_available,
            @buyback_value,
            @advance_payment_required,
            @advance_payment_pct,
            NULL,
            @is_selected,
            @is_active,
            @workflow_types_id,
            @status,
            @created_by,
            GETDATE(),
            NULL,
            NULL,
            @sq_quotation_file,
            @pr_no,
            @com_sno,
            @div_sno,
            @brn_sno,
            @dept_sno,
            @first_approver,
            @freight_charges,
            @other_charges,
            @is_msme,
            @msme_type,
            @is_intrastate
        );

        SET @sq_basic_sno = SCOPE_IDENTITY();

        INSERT INTO dbo.supplier_quotation_items
        (
            sq_basic_sno,
            pr_item_sno,
            prod_sno,
            specification,
            qty,
            unit,
            unit_price,
            discount_pct,
            tax_pct,
            total_amount,
            delivery_days,
            remarks,
            is_active
        )
        SELECT
            @sq_basic_sno,
            pr_item_sno,
            prod_sno,
            specification,
            qty,
            unit,
            unit_price,
            discount_pct,
            tax_pct,
            total_amount,
            delivery_days,
            remarks,
            ISNULL(is_active, 1)
        FROM OPENJSON(@jsonInput, '$.items')
        WITH
        (
            pr_item_sno   INT             '$.pr_item_sno',
            prod_sno      INT             '$.prod_sno',
            specification NVARCHAR(1000)  '$.specification',
            qty           DECIMAL(18,4)   '$.qty',
            unit          INT             '$.unit',
            unit_price    DECIMAL(18,4)   '$.unit_price',
            discount_pct  DECIMAL(18,4)   '$.discount_pct',
            tax_pct       DECIMAL(18,4)   '$.tax_pct',
            total_amount  DECIMAL(18,4)   '$.total_amount',
            delivery_days INT             '$.delivery_days',
            remarks       NVARCHAR(1000)  '$.remarks',
            is_active     BIT             '$.is_active'
        );

        IF @advance_payment_required = 1
           AND JSON_QUERY(@jsonInput, '$.advance_payment_data') IS NOT NULL
        BEGIN
            INSERT INTO dbo.supplier_advance
            (
                sq_basic_sno,
                quotation_ref_no,
                payment_terms,
                advance_payment_pct,
                gst_applicable,
                gst_pct,
                reason,
                note,
                adv_issue_stages,
                is_active,
                created_by,
                created_date
            )
            VALUES
            (
                @sq_basic_sno,
                @quotation_ref_no,
                @payment_terms,
                @advance_payment_pct,
                @adv_gst_applicable,
                @adv_gst_pct,
                @adv_reason,
                @adv_note,
                @adv_issue_stages,
                'Y',
                @created_by,
                CAST(GETDATE() AS DATE)
            );

            SET @sq_adv_sno = SCOPE_IDENTITY();

            UPDATE dbo.supplier_quotation_info
            SET sq_adv_sno = @sq_adv_sno
            WHERE sq_basic_sno = @sq_basic_sno;
        END;

        COMMIT TRAN;

        SELECT
            1 AS success,
            'Supplier quotation created successfully' AS message,
            @sq_basic_sno AS sq_basic_sno,
            @sq_adv_sno AS sq_adv_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRAN;

        SELECT
            0 AS success,
            ERROR_MESSAGE() AS message,
            ERROR_NUMBER() AS error_number,
            ERROR_LINE() AS error_line;
    END CATCH
END;

GO
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetSupplierQuotations]  
    @pr_basic_sno INT,  
    @pr_no        VARCHAR(20)  
AS  
BEGIN  
    SET NOCOUNT ON;  
  
    SELECT  
        sq.*,  
        (  
            SELECT  
                sqi.sq_item_sno,  
                sqi.sq_basic_sno,  
                sqi.pr_item_sno,  
                sqi.prod_sno,  
                pm.prod_name,  
                sqi.specification,  
                sqi.qty        AS unit,  
                sqi.unit_price,  
                sqi.discount_pct,  
                sqi.tax_pct,  
                sqi.total_amount,  
                sqi.delivery_days,  
                sqi.remarks,  
                sqi.is_active  
            FROM supplier_quotation_items sqi  
            INNER JOIN product_master pm  
                ON sqi.prod_sno = pm.prod_sno  
            WHERE sqi.sq_basic_sno = sq.sq_basic_sno  
            FOR JSON PATH  
        ) AS sq_items,
        (
            SELECT
                sa.sq_adv_sno,
                sa.sq_basic_sno,
                sa.quotation_ref_no,
                sa.payment_terms,
                sa.advance_payment_pct,
                sa.gst_applicable,
                sa.gst_pct,
                sa.reason,
                sa.note,
                sa.adv_issue_stages,
                sa.is_active,
                sa.created_by,
                sa.created_date
            FROM dbo.supplier_advance sa
            WHERE sa.sq_basic_sno = sq.sq_basic_sno
            FOR JSON PATH
        ) AS supplier_advance
    FROM supplier_quotation_info sq  
    WHERE  
        sq.is_active   = 1  
        AND sq.pr_basic_sno = @pr_basic_sno  
        AND sq.pr_no        = @pr_no;  
END;

GO
EXEC sp_refreshview 'dbo.vw_get_kyc';
EXEC sp_refreshview 'dbo.vw_get_supplier_quotation';
GO
