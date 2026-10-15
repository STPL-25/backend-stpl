-- ROLLBACK for Dev->Non_Trade structure sync 2026-10-10: restores prior definitions of altered modules;
-- then drops newly created objects (only if wanted).
GO
CREATE OR ALTER   PROCEDURE dbo.sp_nt_CreateTransportRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @transport_name VARCHAR(255) = JSON_VALUE(@jsonInput, '$.transport_name');
    DECLARE @transport_code VARCHAR(50)  = JSON_VALUE(@jsonInput, '$.transport_code');

    IF @transport_name IS NULL OR LTRIM(RTRIM(@transport_name)) = ''
    BEGIN
        RAISERROR('transport_name is required.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.nt_transport_master WHERE transport_name = @transport_name AND is_active = 'Y')
    BEGIN
        RAISERROR('A transporter with this name already exists.', 16, 1);
        RETURN;
    END

    IF @transport_code IS NULL OR LTRIM(RTRIM(@transport_code)) = ''
        SET @transport_code = 'TRN-' + RIGHT('0000' + CAST(
            (SELECT ISNULL(MAX(transport_sno), 0) + 1 FROM dbo.nt_transport_master) AS VARCHAR(4)), 4);

    INSERT INTO dbo.nt_transport_master (
        transport_code, transport_name, contact_person, phone_no, gst_no, address, is_active, created_by
    )
    VALUES (
        @transport_code,
        @transport_name,
        JSON_VALUE(@jsonInput, '$.contact_person'),
        JSON_VALUE(@jsonInput, '$.phone_no'),
        JSON_VALUE(@jsonInput, '$.gst_no'),
        JSON_VALUE(@jsonInput, '$.address'),
        'Y',
        JSON_VALUE(@jsonInput, '$.created_by')
    );

    SELECT transport_sno, transport_code, transport_name, contact_person,
           phone_no, gst_no, address, is_active
    FROM dbo.nt_transport_master
    WHERE transport_sno = SCOPE_IDENTITY();
END;
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetAllDebitNotes
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @status = JSON_VALUE(@jsonInput, '$.status');

    SELECT
        b.debit_note_sno,
        b.debit_note_no,
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(g.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(g.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.po_basic_sno,
        p.po_df_no                                  AS po_no,
        b.vendor_sno,
        k.company_name                               AS vendor_name,
        c.com_name                                   AS com_name,
        b.vendor_invoice_no,
        CONVERT(VARCHAR(10), b.vendor_invoice_date, 120) AS vendor_invoice_date,
        CONVERT(VARCHAR(10), b.debit_note_date, 120)  AS debit_note_date,
        b.total_qty,
        b.total_amount,
        b.remarks,
        b.status,
        b.created_by                                  AS raised_by,
        CONVERT(VARCHAR(30), b.created_date, 120)      AS created_at,
        (
            SELECT
                di.debit_note_item_sno,
                di.grn_item_sno,
                di.po_item_sno,
                di.prod_sno,
                di.prod_name,
                di.specification,
                di.unit_name,
                di.reason_type,
                di.qty,
                di.unit_price,
                di.amount,
                di.remarks
            FROM dbo.debit_note_item_details di
            WHERE di.debit_note_sno = b.debit_note_sno
              AND di.is_active = 'Y'
            FOR JSON PATH
        )                                              AS items
    FROM dbo.debit_note_basic_info b
    JOIN dbo.grn_basic_info g       ON g.grn_basic_sno = b.grn_basic_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = b.vendor_sno
    LEFT JOIN dbo.company_master c  ON c.com_sno = b.com_sno
    WHERE b.is_active = 'Y'
      AND (@status IS NULL OR b.status = @status)
    ORDER BY b.debit_note_sno DESC;
END;
GO
-- ============================================================
-- sp_nt_CreateSubCategoryRecords — accept + validate perishable_days
-- Only additive: everything except the marked lines is unchanged from the
-- live definition (pulled via OBJECT_DEFINITION before editing).
-- ============================================================
CREATE OR ALTER   PROCEDURE dbo.sp_nt_CreateSubCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @cat_sno            INT           = JSON_VALUE(@jsonInput, '$.cat_sno'),
            @subcat_name        NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.subcat_name'),
            @subcat_description NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.subcat_description'),
            @subcat_notes       NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.subcat_notes'),
            @subcat_stock_type  VARCHAR(20)   = ISNULL(NULLIF(JSON_VALUE(@jsonInput, '$.subcat_stock_type'), ''), 'Regular'),
            @perishable_days    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.perishable_days') AS INT),
            @created_by         VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @cat_sno IS NULL OR @subcat_name IS NULL OR LTRIM(RTRIM(@subcat_name)) = ''
    BEGIN
        THROW 50002, N'cat_sno and subcat_name are required.', 1;
        RETURN;
    END;

    IF @subcat_stock_type NOT IN ('Regular', 'Non-Regular', 'Perishable')
    BEGIN
        THROW 50005, N'subcat_stock_type must be Regular, Non-Regular or Perishable.', 1;
        RETURN;
    END;

    -- New: perishable_days is mandatory (and > 0, enforced by the CHECK
    -- constraint too) only when the subcategory is Perishable; ignored/
    -- cleared otherwise so a stray value from the form can't leak in.
    IF @subcat_stock_type = 'Perishable' AND (@perishable_days IS NULL OR @perishable_days <= 0)
    BEGIN
        THROW 50006, N'perishable_days is required and must be greater than zero when subcat_stock_type is Perishable.', 1;
        RETURN;
    END;

    IF @subcat_stock_type <> 'Perishable'
        SET @perishable_days = NULL;

    IF NOT EXISTS (SELECT 1 FROM dbo.category_master WHERE cat_sno = @cat_sno AND cat_active = 'Y')
    BEGIN
        THROW 50003, N'Category not found.', 1;
        RETURN;
    END;

    IF EXISTS (
        SELECT 1 FROM dbo.subcategory_master
        WHERE cat_sno = @cat_sno AND subcat_name = @subcat_name AND subcat_active = 'Y'
    )
    BEGIN
        THROW 50004, N'A sub category with this name already exists under the selected category.', 1;
        RETURN;
    END;

    INSERT INTO dbo.subcategory_master (
        cat_sno, subcat_name, subcat_description, subcat_notes, subcat_stock_type, perishable_days,
        subcat_active, subcat_created_date, subcat_created_by
    )
    VALUES (
        @cat_sno, @subcat_name, @subcat_description, @subcat_notes, @subcat_stock_type, @perishable_days,
        'Y', GETDATE(), @created_by
    );

    SELECT SCOPE_IDENTITY()   AS subcat_sno,
           @subcat_name       AS subcat_name,
           @subcat_stock_type AS subcat_stock_type,
           @perishable_days   AS perishable_days,
           N'SUCCESS'         AS status,
           N'Sub category created successfully.' AS message;
END;
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetEntityRecords
AS
BEGIN
    SET NOCOUNT ON;

    SELECT entity_sno,
           entity_name,
           entity_code,
           entity_desc,
           is_active
    FROM dbo.entity_master
    WHERE is_active = 'Y'
    ORDER BY entity_name;
END;
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateSupplierCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @supp_cat_name NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.supp_cat_name'),
            @supp_cat_code NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.supp_cat_code'),
            @created_by    VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @supp_cat_name IS NULL OR LTRIM(RTRIM(@supp_cat_name)) = ''
    BEGIN
        THROW 50002, N'supp_cat_name is required.', 1;
        RETURN;
    END;

    IF EXISTS (
        SELECT 1 FROM dbo.supplier_category
        WHERE supp_cat_name = @supp_cat_name AND is_active = 'Y'
    )
    BEGIN
        THROW 50004, N'A supplier category with this name already exists.', 1;
        RETURN;
    END;

    INSERT INTO dbo.supplier_category (
        supp_cat_name, supp_cat_code, is_active, created_date, created_by
    )
    VALUES (
        @supp_cat_name, @supp_cat_code, 'Y', GETDATE(), @created_by
    );

    SELECT SCOPE_IDENTITY() AS supp_cat_sno,
           @supp_cat_name   AS supp_cat_name,
           @supp_cat_code   AS supp_cat_code,
           N'SUCCESS'       AS status,
           N'Supplier category created successfully.' AS message;
END;
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateDesignationRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 51001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @designation_code NVARCHAR(30)  = JSON_VALUE(@jsonInput, '$.designation_code'),
            @designation_name NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.designation_name'),
            @created_by       VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @designation_code IS NULL OR @designation_name IS NULL
    BEGIN
        THROW 51002, N'designation_code and designation_name are required.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.designation_master WHERE designation_code = @designation_code)
    BEGIN
        THROW 51003, N'A designation with this code already exists.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.designation_master WHERE designation_name = @designation_name)
    BEGIN
        THROW 51004, N'A designation with this name already exists.', 1;
        RETURN;
    END;

    INSERT INTO dbo.designation_master (
        designation_code, designation_name, is_active, created_by
    )
    VALUES (
        @designation_code, @designation_name, 'Y', @created_by
    );

    SELECT SCOPE_IDENTITY()   AS designation_sno,
           @designation_code AS designation_code,
           N'SUCCESS'        AS status,
           N'Designation created successfully.' AS message;
END;
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreatePaymentModeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @payment_mode_code NVARCHAR(20) = JSON_VALUE(@jsonInput, '$.payment_mode_code'),
            @payment_mode_name NVARCHAR(50) = JSON_VALUE(@jsonInput, '$.payment_mode_name'),
            @created_by        VARCHAR(20)  = JSON_VALUE(@jsonInput, '$.created_by');

    IF @payment_mode_code IS NULL OR @payment_mode_name IS NULL
       OR LTRIM(RTRIM(@payment_mode_code)) = '' OR LTRIM(RTRIM(@payment_mode_name)) = ''
    BEGIN
        THROW 59001, N'payment_mode_code and payment_mode_name are required.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.payment_mode_master WHERE payment_mode_code = @payment_mode_code)
    BEGIN
        THROW 59002, N'A payment mode with this code already exists.', 1;
        RETURN;
    END;

    INSERT INTO dbo.payment_mode_master (payment_mode_code, payment_mode_name, is_active, created_by)
    VALUES (UPPER(@payment_mode_code), @payment_mode_name, 'Y', @created_by);

    SELECT SCOPE_IDENTITY() AS payment_mode_sno, UPPER(@payment_mode_code) AS payment_mode_code,
           @payment_mode_name AS payment_mode_name, N'SUCCESS' AS status;
END;
GO
CREATE OR ALTER   PROCEDURE dbo.sp_nt_CreateSupplierQuotation
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
            approver_ecno
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
            @first_approver
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
CREATE OR ALTER     PROCEDURE [dbo].[sp_nt_GetSupplierQuotations]  
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
            FROM [Non_Trade].[dbo].[supplier_advance] sa
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
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateBankAccountTypeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @account_type_code NVARCHAR(30)  = JSON_VALUE(@jsonInput, '$.account_type_code'),
            @account_type_name NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.account_type_name'),
            @created_by        VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @account_type_code IS NULL OR @account_type_name IS NULL
    BEGIN
        THROW 50002, N'account_type_code and account_type_name are required.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.bank_account_type_master WHERE account_type_code = @account_type_code)
    BEGIN
        THROW 50003, N'A bank account type with this code already exists.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.bank_account_type_master WHERE account_type_name = @account_type_name)
    BEGIN
        THROW 50004, N'A bank account type with this name already exists.', 1;
        RETURN;
    END;

    INSERT INTO dbo.bank_account_type_master (
        account_type_code, account_type_name, is_active, created_by
    )
    VALUES (
        @account_type_code, @account_type_name, 'Y', @created_by
    );

    SELECT SCOPE_IDENTITY()   AS bank_account_type_sno,
           @account_type_code AS account_type_code,
           N'SUCCESS'         AS status,
           N'Bank account type created successfully.' AS message;
END;
GO
CREATE OR ALTER   PROCEDURE dbo.sp_nt_CreateServiceTypeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 58001, N'Invalid JSON payload provided.', 1;

    DECLARE @service_type_code VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.service_type_code'),
            @service_type_name NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.service_type_name'),
            @created_by        VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @service_type_code IS NULL OR @service_type_name IS NULL
        THROW 58002, N'service_type_code and service_type_name are required.', 1;

    IF EXISTS (SELECT 1 FROM dbo.service_type_master WHERE service_type_code = @service_type_code)
        THROW 58003, N'A service type with this code already exists.', 1;

    INSERT INTO dbo.service_type_master (service_type_code, service_type_name, is_active, created_by)
    VALUES (@service_type_code, @service_type_name, 'Y', @created_by);

    SELECT SCOPE_IDENTITY() AS service_type_sno, @service_type_code AS service_type_code, N'SUCCESS' AS status;
END;
GO
CREATE OR ALTER   PROCEDURE dbo.sp_nt_CreateServiceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 58004, N'Invalid JSON payload provided.', 1;

    DECLARE @service_name     NVARCHAR(150) = JSON_VALUE(@jsonInput, '$.service_name'),
            @service_code     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.service_code'),
            @service_type_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_type_sno') AS INT),
            @default_uom_sno  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.default_uom_sno') AS INT),
            @description      NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.description'),
            @created_by       VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @service_name IS NULL OR @service_code IS NULL OR @service_type_sno IS NULL
        THROW 58005, N'service_name, service_code and service_type_sno are required.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.service_type_master WHERE service_type_sno = @service_type_sno AND is_active = 'Y')
        THROW 58006, N'service_type_sno does not reference an active service type.', 1;

    IF EXISTS (SELECT 1 FROM dbo.service_master WHERE service_code = @service_code)
        THROW 58007, N'A service with this code already exists.', 1;

    INSERT INTO dbo.service_master (service_name, service_code, service_type_sno, default_uom_sno, description, is_active, created_by)
    VALUES (@service_name, @service_code, @service_type_sno, @default_uom_sno, @description, 'Y', @created_by);

    SELECT SCOPE_IDENTITY() AS service_sno, @service_code AS service_code, N'SUCCESS' AS status;
END;
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetDefaultTermsConditions
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno  INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno')  AS INT),
            @div_sno  INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno')  AS INT),
            @brn_sno  INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno')  AS INT),
            @dept_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);

    SELECT TOP 1 tc_sno, tc_title, tc_text
    FROM dbo.terms_conditions_master
    WHERE com_sno = @com_sno AND div_sno = @div_sno AND brn_sno = @brn_sno AND dept_sno = @dept_sno
      AND is_default = 'Y' AND is_active = 'Y';
END;
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateWarehouseLocationRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @location_code NVARCHAR(30)  = JSON_VALUE(@jsonInput, '$.location_code'),
            @location_name NVARCHAR(150) = JSON_VALUE(@jsonInput, '$.location_name'),
            @description   NVARCHAR(255) = JSON_VALUE(@jsonInput, '$.description'),
            @com_snos      NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.com_snos'),
            @div_snos      NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.div_snos'),
            @brn_snos      NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.brn_snos'),
            @created_by    VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    SET @div_snos = ISNULL(@div_snos, N'[]');
    SET @brn_snos = ISNULL(@brn_snos, N'[]');

    IF @location_code IS NULL OR @location_name IS NULL
    BEGIN
        THROW 50002, N'location_code and location_name are required.', 1;
        RETURN;
    END;

    IF @com_snos IS NULL OR ISJSON(@com_snos) = 0 OR NOT EXISTS (SELECT 1 FROM OPENJSON(@com_snos))
    BEGIN
        THROW 50003, N'At least one company must be selected.', 1;
        RETURN;
    END;

    IF ISJSON(@div_snos) = 0 OR ISJSON(@brn_snos) = 0
    BEGIN
        THROW 50004, N'div_snos and brn_snos must be valid JSON arrays.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.warehouse_location_master WHERE location_code = @location_code)
    BEGIN
        THROW 50005, N'A warehouse location with this code already exists.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.warehouse_location_master WHERE location_name = @location_name)
    BEGIN
        THROW 50006, N'A warehouse location with this name already exists.', 1;
        RETURN;
    END;

    INSERT INTO dbo.warehouse_location_master (
        location_code, location_name, description, com_snos, div_snos, brn_snos, is_active, created_by
    )
    VALUES (
        @location_code, @location_name, @description, @com_snos, @div_snos, @brn_snos, 'Y', @created_by
    );

    SELECT SCOPE_IDENTITY() AS location_sno,
           @location_code   AS location_code,
           N'SUCCESS'       AS status,
           N'Warehouse location created successfully.' AS message;
END;
GO
CREATE OR ALTER   PROCEDURE dbo.sp_nt_CreateRecurrenceCadenceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 58008, N'Invalid JSON payload provided.', 1;

    DECLARE @cadence_code   VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.cadence_code'),
            @cadence_name   NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.cadence_name'),
            @interval_unit  VARCHAR(10)   = UPPER(JSON_VALUE(@jsonInput, '$.interval_unit')),
            @interval_value INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.interval_value') AS INT),
            @description    NVARCHAR(200) = JSON_VALUE(@jsonInput, '$.description'),
            @created_by     VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @cadence_code IS NULL OR @cadence_name IS NULL OR @interval_unit IS NULL OR @interval_value IS NULL
        THROW 58009, N'cadence_code, cadence_name, interval_unit and interval_value are required.', 1;
    IF @interval_unit NOT IN ('DAY','MONTH') THROW 58010, N'interval_unit must be DAY or MONTH.', 1;
    IF @interval_value <= 0 THROW 58011, N'interval_value must be positive.', 1;
    IF EXISTS (SELECT 1 FROM dbo.recurrence_cadence_master WHERE cadence_code = @cadence_code)
        THROW 58012, N'A recurrence cadence with this code already exists.', 1;

    INSERT INTO dbo.recurrence_cadence_master (cadence_code, cadence_name, interval_unit, interval_value, description, is_active, created_by)
    VALUES (@cadence_code, @cadence_name, @interval_unit, @interval_value, @description, 'Y', @created_by);

    SELECT SCOPE_IDENTITY() AS recurrence_cadence_sno, @cadence_code AS cadence_code, N'SUCCESS' AS status;
END;
GO
CREATE OR ALTER   PROCEDURE dbo.sp_nt_CreateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @com_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @service_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @vendor_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @qty                DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4));
        DECLARE @rate_amount        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @rate_uom_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_uom_sno') AS INT);
        DECLARE @recurrence_cadence_sno INT       = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_cadence_sno') AS INT);
        DECLARE @po_generation_day  SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_generation_day') AS SMALLINT);
        DECLARE @notify_days_before SMALLINT      = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.notify_days_before') AS SMALLINT), 0);
        DECLARE @period_start_date  DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url  NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @terms_conditions   NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.terms_conditions');
        DECLARE @ceiling_amount     DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @created_by         VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
        DECLARE @vendors_json       NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.vendors');
        DECLARE @statutory_json     NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.statutory');

        -- The first supplier in the split is the primary (service_agreement.vendor_sno).
        IF @vendors_json IS NOT NULL AND ISJSON(@vendors_json) = 1
            SET @vendor_sno = ISNULL(TRY_CAST(JSON_VALUE(@vendors_json, '$[0].vendor_sno') AS INT), @vendor_sno);

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @service_sno IS NULL OR @vendor_sno IS NULL OR @created_by IS NULL
            THROW 58101, 'com_sno, div_sno, brn_sno, dept_sno, service_sno, at least one supplier and created_by are required.', 1;

        IF @qty IS NULL OR @qty <= 0
            THROW 58102, 'qty must be a positive quantity.', 1;

        IF @rate_amount IS NULL OR @rate_amount <= 0
            THROW 58103, 'rate_amount must be a positive amount (an approximate value is fine for an Unfixed or Statutory agreement).', 1;

        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 58104, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;

        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 58105, 'agreement_doc_url is required — upload the agreement document before submitting.', 1;

        IF @recurrence_cadence_sno IS NULL
            THROW 58106, 'recurrence_cadence_sno is required — see sp_nt_GetRecurrenceCadenceRecords for valid options.', 1;

        DECLARE @interval_unit VARCHAR(10);
        SELECT @interval_unit = interval_unit FROM dbo.recurrence_cadence_master WHERE recurrence_cadence_sno = @recurrence_cadence_sno AND is_active = 'Y';
        IF @interval_unit IS NULL
            THROW 58107, 'recurrence_cadence_sno does not reference an active recurrence cadence.', 1;

        IF @interval_unit = 'MONTH'
        BEGIN
            IF @po_generation_day IS NULL OR @po_generation_day NOT BETWEEN 1 AND 31
                THROW 58108, 'po_generation_day (1-31) is required for a month-based recurrence cadence.', 1;
        END
        ELSE
            SET @po_generation_day = NULL;

        DECLARE @service_type_code VARCHAR(30);
        SELECT @service_type_code = st.service_type_code
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';

        IF @service_type_code IS NULL OR @service_type_code NOT IN ('FIXED_RECURRING', 'VARIABLE_RECURRING', 'STATUTORY')
            THROW 58109, 'service_sno must reference an active Fixed, Unfixed or Statutory service.', 1;

        IF @service_type_code = 'FIXED_RECURRING'
            SET @ceiling_amount = NULL;
        ELSE IF @ceiling_amount IS NOT NULL AND @ceiling_amount <= 0
            THROW 58112, 'ceiling_amount must be a positive amount when provided.', 1;

        -- ── Resolve the ServiceAgreement workflow for this org scope ───────
        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceAgreement';

        IF @workflow_types_id IS NULL
            THROW 58110, 'No ServiceAgreement workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key] = '0' AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 58111, 'No approver found for the first stage of the ServiceAgreement workflow.', 1;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(agreement_no, 4) AS INT)), 0) + 1
        FROM dbo.service_agreement WITH (UPDLOCK, HOLDLOCK)
        WHERE agreement_no LIKE 'AGR-' + @year + '-%';
        DECLARE @agreement_no VARCHAR(30) = 'AGR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.service_agreement (
            agreement_no, com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
            qty, rate_amount, rate_uom_sno, recurrence_cadence_sno, po_generation_day, notify_days_before,
            period_start_date, period_end_date, agreement_doc_url, remarks, terms_conditions, ceiling_amount,
            workflow_types_id, current_approver_id, status, is_active, created_by
        )
        VALUES (
            @agreement_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @service_sno, @vendor_sno,
            @qty, @rate_amount, @rate_uom_sno, @recurrence_cadence_sno, @po_generation_day, @notify_days_before,
            @period_start_date, @period_end_date, @agreement_doc_url, @remarks, @terms_conditions, @ceiling_amount,
            @workflow_types_id, @first_approver, 'P', 'Y', @created_by
        );

        DECLARE @agreement_sno INT = SCOPE_IDENTITY();

        DECLARE @total_per_cycle DECIMAL(18,2) = ROUND(@rate_amount * @qty, 2), @primary_vendor INT;
        EXEC dbo.sp_nt_SaveServiceAgreementSuppliers
            @agreement_sno = @agreement_sno, @vendors_json = @vendors_json, @fallback_vendor_sno = @vendor_sno,
            @total_amount = @total_per_cycle, @out_primary_vendor_sno = @primary_vendor OUTPUT;
        IF @primary_vendor IS NOT NULL AND @primary_vendor <> @vendor_sno
            UPDATE dbo.service_agreement SET vendor_sno = @primary_vendor WHERE agreement_sno = @agreement_sno;

        EXEC dbo.sp_nt_SaveServiceAgreementStatutory
            @agreement_sno = @agreement_sno, @service_type_code = @service_type_code, @statutory_json = @statutory_json;

        DECLARE @version_no INT;
        EXEC dbo.sp_nt_SnapshotServiceAgreementVersion
            @agreement_sno = @agreement_sno, @action_type = 'SUBMITTED', @submitted_by = @created_by,
            @out_version_no = @version_no OUTPUT;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
        VALUES (@agreement_sno, 'SUBMITTED', @created_by, NULL, @version_no);

        COMMIT TRANSACTION;

        SELECT @agreement_sno AS agreement_sno, @agreement_no AS agreement_no, 'SUCCESS' AS result,
               N'Service agreement submitted for approval.' AS message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
CREATE OR ALTER   PROCEDURE dbo.sp_nt_UpdateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @agreement_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
        DECLARE @com_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @service_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @vendor_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @qty                DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4));
        DECLARE @rate_amount        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @rate_uom_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_uom_sno') AS INT);
        DECLARE @recurrence_cadence_sno INT       = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_cadence_sno') AS INT);
        DECLARE @po_generation_day  SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_generation_day') AS SMALLINT);
        DECLARE @notify_days_before SMALLINT      = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.notify_days_before') AS SMALLINT), 0);
        DECLARE @period_start_date  DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url  NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @terms_conditions   NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.terms_conditions');
        DECLARE @ceiling_amount     DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @edited_by          VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.edited_by');
        DECLARE @vendors_json       NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.vendors');
        DECLARE @statutory_json     NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.statutory');

        IF @vendors_json IS NOT NULL AND ISJSON(@vendors_json) = 1
            SET @vendor_sno = ISNULL(TRY_CAST(JSON_VALUE(@vendors_json, '$[0].vendor_sno') AS INT), @vendor_sno);

        IF @agreement_sno IS NULL OR @edited_by IS NULL
            THROW 58120, 'agreement_sno and edited_by are required.', 1;

        DECLARE @current_status CHAR(1), @old_period_end DATE;
        SELECT @current_status = status, @old_period_end = period_end_date
        FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno AND is_active = 'Y';
        IF @current_status IS NULL
            THROW 58121, 'Service agreement not found or inactive.', 1;
        IF @current_status NOT IN ('A', 'R', 'X')
            THROW 58122, 'Only an Approved, Rejected or Expired agreement can be edited or renewed (it is currently Pending approval).', 1;

        DECLARE @is_renewal BIT = CASE WHEN @current_status = 'X' THEN 1 ELSE 0 END;

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @service_sno IS NULL OR @vendor_sno IS NULL
            THROW 58123, 'com_sno, div_sno, brn_sno, dept_sno, service_sno and at least one supplier are required.', 1;
        IF @qty IS NULL OR @qty <= 0
            THROW 58124, 'qty must be a positive quantity.', 1;
        IF @rate_amount IS NULL OR @rate_amount <= 0
            THROW 58125, 'rate_amount must be a positive amount.', 1;
        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 58126, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;
        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 58127, 'agreement_doc_url is required.', 1;

        IF @is_renewal = 1
        BEGIN
            IF @period_start_date <= @old_period_end
            BEGIN
                DECLARE @renew_msg NVARCHAR(300) = N'A renewal must start after the expired term ended (' + CONVERT(NVARCHAR(10), @old_period_end, 23) + N').';
                THROW 58133, @renew_msg, 1;
            END
            IF @period_end_date < CAST(GETDATE() AS DATE)
                THROW 58134, 'The renewed period has already ended — choose a term that runs beyond today.', 1;
        END

        DECLARE @interval_unit VARCHAR(10);
        SELECT @interval_unit = interval_unit FROM dbo.recurrence_cadence_master WHERE recurrence_cadence_sno = @recurrence_cadence_sno AND is_active = 'Y';
        IF @interval_unit IS NULL
            THROW 58128, 'recurrence_cadence_sno does not reference an active recurrence cadence.', 1;
        IF @interval_unit = 'MONTH'
        BEGIN
            IF @po_generation_day IS NULL OR @po_generation_day NOT BETWEEN 1 AND 31
                THROW 58129, 'po_generation_day (1-31) is required for a month-based recurrence cadence.', 1;
        END
        ELSE
            SET @po_generation_day = NULL;

        DECLARE @service_type_code VARCHAR(30);
        SELECT @service_type_code = st.service_type_code
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';
        IF @service_type_code IS NULL OR @service_type_code NOT IN ('FIXED_RECURRING', 'VARIABLE_RECURRING', 'STATUTORY')
            THROW 58135, 'service_sno must reference an active Fixed, Unfixed or Statutory service.', 1;
        IF @service_type_code = 'FIXED_RECURRING'
            SET @ceiling_amount = NULL;
        ELSE IF @ceiling_amount IS NOT NULL AND @ceiling_amount <= 0
            THROW 58132, 'ceiling_amount must be a positive amount when provided.', 1;

        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceAgreement';
        IF @workflow_types_id IS NULL
            THROW 58130, 'No ServiceAgreement workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id AND s.[key] = '0' AND s2.[key] = '0';
        IF @first_approver IS NULL
            THROW 58131, 'No approver found for the first stage of the ServiceAgreement workflow.', 1;

        UPDATE dbo.service_agreement
        SET com_sno = @com_sno, div_sno = @div_sno, brn_sno = @brn_sno, dept_sno = @dept_sno,
            service_sno = @service_sno, vendor_sno = @vendor_sno, qty = @qty, rate_amount = @rate_amount,
            rate_uom_sno = @rate_uom_sno, recurrence_cadence_sno = @recurrence_cadence_sno,
            po_generation_day = @po_generation_day, notify_days_before = @notify_days_before,
            period_start_date = @period_start_date, period_end_date = @period_end_date,
            agreement_doc_url = @agreement_doc_url, remarks = @remarks, terms_conditions = @terms_conditions,
            ceiling_amount = @ceiling_amount,
            workflow_types_id = @workflow_types_id, current_approver_id = @first_approver,
            status = 'P', modified_by = @edited_by, modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno;

        DECLARE @total_per_cycle DECIMAL(18,2) = ROUND(@rate_amount * @qty, 2), @primary_vendor INT;
        EXEC dbo.sp_nt_SaveServiceAgreementSuppliers
            @agreement_sno = @agreement_sno, @vendors_json = @vendors_json, @fallback_vendor_sno = @vendor_sno,
            @total_amount = @total_per_cycle, @out_primary_vendor_sno = @primary_vendor OUTPUT;
        IF @primary_vendor IS NOT NULL AND @primary_vendor <> @vendor_sno
            UPDATE dbo.service_agreement SET vendor_sno = @primary_vendor WHERE agreement_sno = @agreement_sno;

        EXEC dbo.sp_nt_SaveServiceAgreementStatutory
            @agreement_sno = @agreement_sno, @service_type_code = @service_type_code, @statutory_json = @statutory_json;

        DECLARE @edit_action VARCHAR(20) = CASE WHEN @is_renewal = 1 THEN 'RENEWED' ELSE 'RESUBMITTED' END;
        DECLARE @version_no INT;
        EXEC dbo.sp_nt_SnapshotServiceAgreementVersion
            @agreement_sno = @agreement_sno, @action_type = @edit_action, @submitted_by = @edited_by,
            @out_version_no = @version_no OUTPUT;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
        VALUES (@agreement_sno, @edit_action, @edited_by, NULL, @version_no);

        COMMIT TRANSACTION;

        SELECT @agreement_sno AS agreement_sno, @version_no AS version_no, 'SUCCESS' AS result,
               CASE WHEN @is_renewal = 1 THEN N'Service agreement renewed and submitted for approval.'
                    ELSE N'Service agreement updated and resubmitted for approval.' END AS message;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
CREATE OR ALTER   PROCEDURE dbo.sp_nt_DirectIssueServicePO
    @jsonInput NVARCHAR(MAX),
    @silent BIT = 0,
    @out_result VARCHAR(30) = NULL OUTPUT,
    @out_po_basic_sno INT = NULL OUTPUT,
    @out_po_no VARCHAR(50) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @com_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno     INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @vendor_sno   INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @pr_basic_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT);
        DECLARE @pr_item_sno  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_item_sno') AS INT);
        DECLARE @service_sno  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @qty          DECIMAL(18,4) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4)), 1);
        DECLARE @uom_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.uom_sno') AS INT);
        DECLARE @unit_price   DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.unit_price') AS DECIMAL(18,2));
        DECLARE @required_date DATE         = TRY_CAST(JSON_VALUE(@jsonInput, '$.required_date') AS DATE);
        DECLARE @purpose      VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.purpose');
        DECLARE @issued_by    VARCHAR(20)   = ISNULL(JSON_VALUE(@jsonInput, '$.issued_by'), 'SYSTEM');

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @vendor_sno IS NULL OR @pr_basic_sno IS NULL OR @service_sno IS NULL OR @unit_price IS NULL
            THROW 58201, 'com_sno, div_sno, brn_sno, dept_sno, vendor_sno, pr_basic_sno, service_sno and unit_price are required.', 1;

        DECLARE @service_type_sno INT;
        SELECT @service_type_sno = service_type_sno FROM dbo.service_master WHERE service_sno = @service_sno AND is_active = 'Y';
        IF @service_type_sno IS NULL
            THROW 58202, 'Unknown or inactive service_sno.', 1;

        DECLARE @net_cost DECIMAL(18,4) = @qty * @unit_price;

        BEGIN TRANSACTION;

        DECLARE @po_year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @po_seq  INT;
        SELECT @po_seq = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
        FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
        WHERE po_df_no LIKE 'SVO-' + @po_year + '-%';
        DECLARE @po_no VARCHAR(50) = 'SVO-' + @po_year + '-' + RIGHT('0000' + CAST(@po_seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.po_request_info (
            vendor_sno, brn_sno, dept_sno, com_sno, div_sno, budget_sno, budget_code, pr_basic_sno,
            po_date, required_date, purpose, terms_conditions, delivery_address,
            is_active, workflow_types_id, current_approver_id, status, po_df_no, service_type_sno
        )
        VALUES (
            @vendor_sno, @brn_sno, @dept_sno, @com_sno, @div_sno, NULL, NULL, @pr_basic_sno,
            CAST(GETDATE() AS DATE), ISNULL(@required_date, CAST(GETDATE() AS DATE)), @purpose, NULL, NULL,
            'Y', NULL, NULL, 'A', @po_no, @service_type_sno
        );
        DECLARE @po_basic_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.po_item_details (
            po_basic_sno, pr_item_sno, service_sno, prod_name, specification,
            qty, unit, unit_name, agreed_unit_price, total_cost, discount_pct, tax_pct, net_cost,
            remarks, po_section, created_by, created_date, is_active
        )
        SELECT
            @po_basic_sno, @pr_item_sno, @service_sno, sm.service_name, '',
            @qty, @uom_sno, um.uom_name, @unit_price, @net_cost, 0, 0, @net_cost,
            @purpose, 'SERVICE', @issued_by, GETDATE(), '1'
        FROM dbo.service_master sm
        LEFT JOIN dbo.uom_master um ON um.uom_sno = @uom_sno
        WHERE sm.service_sno = @service_sno;

        INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
        VALUES (@po_basic_sno, 'AUTO_ISSUED', @issued_by, N'Direct-issued from an approved Service Agreement, no separate PO approval required.', 'Y');

        COMMIT TRANSACTION;

        SET @out_result = 'SUCCESS';
        SET @out_po_basic_sno = @po_basic_sno;
        SET @out_po_no = @po_no;

        IF @silent = 0
            SELECT 'SUCCESS' AS result, @po_basic_sno AS po_basic_sno, @po_no AS po_no;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @out_result = 'ERROR';
        THROW;
    END CATCH
END;
GO
CREATE OR ALTER   PROCEDURE dbo.sp_approve_service_agreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF ISJSON(@jsonInput) = 0
        BEGIN
            RAISERROR('Invalid JSON format for @jsonInput', 16, 1);
            RETURN;
        END

        DECLARE @agreement_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT),
                @comments         VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages  NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by      VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action           VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');

        IF @agreement_sno IS NULL
        BEGIN
            RAISERROR('agreement_sno is required.', 16, 1);
            RETURN;
        END

        IF @action IS NULL OR LTRIM(RTRIM(LOWER(@action))) NOT IN ('approve', 'reject')
        BEGIN
            RAISERROR('Invalid action. Must be ''approve'' or ''reject''.', 16, 1);
            RETURN;
        END
        SET @action = LOWER(LTRIM(RTRIM(@action)));

        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
        BEGIN
            RAISERROR('Invalid or missing approval_stages in JSON', 16, 1);
            RETURN;
        END

        IF @approved_by IS NULL OR LTRIM(RTRIM(@approved_by)) = ''
        BEGIN
            RAISERROR('Approver EC number is required.', 16, 1);
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno AND is_active = 'Y')
        BEGIN
            RAISERROR('Service agreement not found or inactive.', 16, 1);
            RETURN;
        END

        -- The version this decision applies to (sql/88): the highest version_no
        -- is the one currently in approval.
        DECLARE @cur_version INT = (SELECT MAX(version_no) FROM dbo.service_agreement_version WHERE agreement_sno = @agreement_sno);

        BEGIN TRANSACTION;

        CREATE TABLE #approval_stages (
            seq_no INT, approver_ecno VARCHAR(30), stage VARCHAR(100),
            required_approvals VARCHAR(10), is_mandatory CHAR(1), escalation_hours VARCHAR(10),
            approver_condition VARCHAR(200), next_approver_ecno VARCHAR(30),
            can_forward CHAR(1), can_backward CHAR(1), can_edit_data CHAR(1)
        );

        INSERT INTO #approval_stages (
            seq_no, approver_ecno, stage, required_approvals, is_mandatory,
            escalation_hours, approver_condition, next_approver_ecno,
            can_forward, can_backward, can_edit_data
        )
        SELECT
            CAST(ojBase.[key] AS INT),
            JSON_VALUE(ojBase.[value], '$.approver_ecno'),
            JSON_VALUE(ojBase.[value], '$.stage'),
            JSON_VALUE(ojBase.[value], '$.required_approvals'),
            JSON_VALUE(ojBase.[value], '$.is_mandatory'),
            JSON_VALUE(ojBase.[value], '$.escalation_hours'),
            JSON_VALUE(ojBase.[value], '$.approver_condition'),
            JSON_VALUE(ojBase.[value], '$.next_approver_ecno'),
            JSON_VALUE(ojBase.[value], '$.can_forward'),
            JSON_VALUE(ojBase.[value], '$.can_backward'),
            JSON_VALUE(ojBase.[value], '$.can_edit_data')
        FROM OPENJSON(@approval_stages) AS ojBase;

        IF @action = 'reject'
        BEGIN
            INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
            VALUES (@agreement_sno, 'REJECTED', @approved_by, @comments, @cur_version);

            UPDATE dbo.service_agreement SET status = 'R', current_approver_id = NULL WHERE agreement_sno = @agreement_sno;

            UPDATE dbo.service_agreement_version SET outcome = 'REJECTED', decided_at = GETDATE()
            WHERE agreement_sno = @agreement_sno AND version_no = @cur_version;

            DROP TABLE #approval_stages;
            COMMIT TRANSACTION;
            SELECT 'REJECTED' AS result, @agreement_sno AS agreement_sno, @approved_by AS rejected_by, GETDATE() AS rejected_on;
            RETURN;
        END

        DECLARE @next_current_approver VARCHAR(30);
        SELECT @next_current_approver = next_stage.approver_ecno
        FROM (
            SELECT approver_ecno, LEAD(approver_ecno, 1, NULL) OVER (ORDER BY seq_no) AS next_approver_ecno
            FROM #approval_stages
        ) current_stage
        LEFT JOIN #approval_stages next_stage ON next_stage.approver_ecno = current_stage.next_approver_ecno
        WHERE current_stage.approver_ecno = @approved_by;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, version_no)
        VALUES (@agreement_sno, 'APPROVED', @approved_by, @comments, @cur_version);

        UPDATE dbo.service_agreement SET current_approver_id = @next_current_approver WHERE agreement_sno = @agreement_sno;

        DECLARE @auto_po_result VARCHAR(200) = NULL, @auto_po_basic_sno INT = NULL, @auto_po_no VARCHAR(50) = NULL,
                @auto_pr_basic_sno INT = NULL, @auto_pr_no VARCHAR(20) = NULL;

        IF @next_current_approver IS NULL
        BEGIN
            -- ── Final stage: Fixed and Unfixed both go straight to Approved
            --    now — rate/qty stay whatever was entered at creation, no
            --    re-entry/finalization step here any more. ──────────────
            DECLARE @period_start DATE;
            SELECT @period_start = sa.period_start_date FROM dbo.service_agreement sa WHERE sa.agreement_sno = @agreement_sno;

            UPDATE dbo.service_agreement SET status = 'A' WHERE agreement_sno = @agreement_sno;

            UPDATE dbo.service_agreement_version SET outcome = 'APPROVED', decided_at = GETDATE()
            WHERE agreement_sno = @agreement_sno AND version_no = @cur_version;

            -- sql/88: only THIS term's billing dates count. A renewed agreement already
            -- has log rows from its previous term, which must not suppress the first
            -- cycle of the new one.
            IF NOT EXISTS (SELECT 1 FROM dbo.service_agreement_recurring_pr_log WHERE agreement_sno = @agreement_sno AND billing_period_start >= @period_start)
            BEGIN
                DECLARE @first_billing_period_start DATE = CASE WHEN CAST(GETDATE() AS DATE) < @period_start THEN @period_start ELSE CAST(GETDATE() AS DATE) END;
                DECLARE @firstCycleJson NVARCHAR(MAX) = (
                    SELECT @agreement_sno AS agreement_sno, @first_billing_period_start AS billing_period_start, @approved_by AS issued_by
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
                );

                BEGIN TRY
                    EXEC dbo.sp_nt_IssueRecurringServicePOCycle
                        @jsonInput = @firstCycleJson, @silent = 1,
                        @out_result = @auto_po_result OUTPUT, @out_po_basic_sno = @auto_po_basic_sno OUTPUT, @out_po_no = @auto_po_no OUTPUT,
                        @out_pr_basic_sno = @auto_pr_basic_sno OUTPUT, @out_pr_no = @auto_pr_no OUTPUT;
                END TRY
                BEGIN CATCH
                    -- Do not fail the approval itself — service_agreement_recurring_pr_log
                    -- already has a FAILED row for ops to find and retry via a fresh sweep call.
                    SET @auto_po_result = 'ERROR: ' + ERROR_MESSAGE();
                END CATCH
            END
        END

        DROP TABLE #approval_stages;
        COMMIT TRANSACTION;

        SELECT
            'SUCCESS' AS result, @agreement_sno AS agreement_sno, @approved_by AS approved_by, GETDATE() AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE') AS next_approver,
            @auto_po_result AS auto_po_result, @auto_po_basic_sno AS auto_po_basic_sno, @auto_po_no AS auto_po_no,
            @auto_pr_basic_sno AS auto_pr_basic_sno, @auto_pr_no AS auto_pr_no;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL DROP TABLE #approval_stages;
        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO
-- ============================================================
-- KYC Approval screen: show Business Type / Account Type NAMES, not master ids.
-- Database: Non_Trade + Non_trade_Dev (MSSQL)
--
-- Problem (reported 2026-09-24): on the KYC Approval screen "Business Type"
-- showed "2" / "4" / "6" and the bank "Account Type" showed "1" / "2".
--
-- Cause: the KYC entry form stores the SELECTED MASTER ID in
--   kyc_basic_info.business_type   -> business_types.business_types_id
--   kyc_bank_info.ac_type          -> bank_account_type_master.bank_account_type_sno
-- (both NVARCHAR(50) columns, so the id is held as text), and
-- sp_get_kyc_approval was a bare SELECT * over vw_get_all_kyc_info, which
-- returns those columns untouched. Nothing on the way to the screen ever
-- joined the two masters.
--
-- Fix: resolve both in sp_get_kyc_approval, ADDITIVELY:
--   * new column  business_type_name          (business_type itself stays the raw id)
--   * new key     ac_type_name inside the kyc_bank_info JSON  (ac_type stays the raw id)
-- Everything else in the result set is unchanged, so nothing reading the old
-- fields can break.
--
-- Why the SP and not the view: vw_get_all_kyc_info is shared with
-- sp_nt_ApproveSupplierQuotation / sp_nt_GetQuotationsForApproval (and
-- sp_nt_ApproveServicePoCycle on Dev). Adding a column there would change the
-- shape their SELECT * consumers see; scoping the change to this one SP does not.
--
-- Legacy rows: Non_trade_Dev still has free-text values from before the masters
-- ("current", "SAVINGS", "Proprietorship" ...). TRY_CONVERT(INT, ...) is NULL for
-- those, the LEFT JOIN finds nothing, and COALESCE falls back to the stored text,
-- so they keep displaying as they always did. An empty value stays empty.
-- Inactive master rows are still resolved (a KYC submitted while a type was
-- active must not lose its label).
--
-- A temp table is used only so the existing column name `kyc_bank_info` can be
-- overwritten in place (SELECT v.*, <new JSON> AS kyc_bank_info would return the
-- name twice and node-mssql collapses duplicate column names into an array).
--
-- Re-runnable (CREATE OR ALTER). Rollback:
-- backups/kyc_approval_master_names_2026-09-24_ROLLBACK.sql
-- ============================================================

CREATE OR ALTER   PROCEDURE dbo.sp_get_kyc_approval
    @Ecno VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NULLIF(LTRIM(RTRIM(@Ecno)), '') IS NULL
            THROW 50001, 'Ecno cannot be null or empty.', 1;

        SELECT v.*,
               CAST(NULL AS NVARCHAR(200)) AS business_type_name
        INTO #kyc
        FROM dbo.vw_get_all_kyc_info v
        WHERE v.approver_ecno = @Ecno
          AND v.status = 'P';

        UPDATE k
        SET business_type_name = COALESCE(bt.business_types_name, NULLIF(LTRIM(RTRIM(k.business_type)), '')),
            kyc_bank_info = ISNULL((
                SELECT kbi.ac_holder_name, kbi.ac_number, kbi.ac_type,
                       COALESCE(bat.account_type_name, NULLIF(LTRIM(RTRIM(kbi.ac_type)), '')) AS ac_type_name,
                       kbi.ifsc, kbi.bank_name, kbi.bank_branch_name, kbi.bank_address, kbi.is_primary
                FROM dbo.kyc_bank_info kbi
                LEFT JOIN dbo.bank_account_type_master bat
                       ON bat.bank_account_type_sno = TRY_CONVERT(INT, kbi.ac_type)
                WHERE kbi.kyc_basic_info_sno = k.kyc_basic_info_sno
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
CREATE OR ALTER   PROCEDURE dbo.sp_nt_SubmitServicePoEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @cycle_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.cycle_sno') AS INT);
        DECLARE @rate_amount  DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @discount_pct DECIMAL(5,2)  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.discount_pct') AS DECIMAL(5,2)), 0);
        DECLARE @gst_pct      DECIMAL(5,2)  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.gst_pct') AS DECIMAL(5,2)), 0);
        DECLARE @remarks      NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @submitted_by VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.submitted_by');

        IF @cycle_sno IS NULL OR @rate_amount IS NULL OR @rate_amount <= 0 OR @submitted_by IS NULL
            THROW 58320, 'cycle_sno, rate_amount and submitted_by are required.', 1;
        IF @discount_pct < 0 OR @discount_pct > 100 OR @gst_pct < 0 OR @gst_pct > 100
            THROW 58324, 'discount_pct and gst_pct must be between 0 and 100.', 1;

        DECLARE @agreement_sno INT, @qty DECIMAL(18,4), @status VARCHAR(20),
                @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @ceiling_amount DECIMAL(18,2);
        SELECT @agreement_sno = spc.agreement_sno, @qty = spc.qty, @status = spc.status,
               @com_sno = spc.com_sno, @div_sno = spc.div_sno, @brn_sno = spc.brn_sno, @dept_sno = spc.dept_sno,
               @ceiling_amount = sa.ceiling_amount
        FROM dbo.service_po_cycle spc
        JOIN dbo.service_agreement sa ON sa.agreement_sno = spc.agreement_sno
        WHERE spc.cycle_sno = @cycle_sno;

        IF @agreement_sno IS NULL THROW 58321, 'Service PO cycle not found.', 1;
        IF @status <> 'PENDING_ENTRY' THROW 58322, 'This cycle is not awaiting entry.', 1;

        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);
        EXEC dbo.sp_nt_ResolveServicePoWorkflow
            @com_sno = @com_sno, @div_sno = @div_sno, @brn_sno = @brn_sno, @dept_sno = @dept_sno,
            @workflow_types_id = @workflow_types_id OUTPUT, @first_approver = @first_approver OUTPUT;

        BEGIN TRANSACTION;

        DECLARE @net_cost DECIMAL(18,2);
        EXEC dbo.sp_nt_BuildServicePoCycleSplit
            @cycle_sno = @cycle_sno, @agreement_sno = @agreement_sno, @rate_amount = @rate_amount, @qty = @qty,
            @discount_pct = @discount_pct, @gst_pct = @gst_pct, @out_net_cost = @net_cost OUTPUT;

        IF @ceiling_amount IS NOT NULL AND @net_cost > @ceiling_amount
            THROW 58323, 'Entered amount exceeds the agreement''s ceiling amount.', 1;

        UPDATE dbo.service_po_cycle
        SET rate_amount = @rate_amount, discount_pct = @discount_pct, gst_pct = @gst_pct, net_cost = @net_cost,
            remarks = @remarks, status = 'PENDING_APPROVAL',
            workflow_types_id = @workflow_types_id, current_approver_id = @first_approver,
            entered_by = @submitted_by, entered_at = GETDATE()
        WHERE cycle_sno = @cycle_sno;

        INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
        VALUES (@cycle_sno, 'ENTRY_SUBMITTED', @submitted_by,
                N'Rate ' + CAST(@rate_amount AS VARCHAR(30)) + N', GST ' + CAST(@gst_pct AS VARCHAR(10)) + N'%, Net ' + CAST(@net_cost AS VARCHAR(30)));

        COMMIT TRANSACTION;

        SELECT 'SUCCESS' AS result, @cycle_sno AS cycle_sno, @net_cost AS net_cost;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
CREATE OR ALTER   PROCEDURE dbo.sp_nt_ApproveServicePoCycle
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF ISJSON(@jsonInput) = 0
        BEGIN
            RAISERROR('Invalid JSON format for @jsonInput', 16, 1);
            RETURN;
        END

        DECLARE @cycle_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.cycle_sno') AS INT),
                @comments        VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by     VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action          VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');

        IF @cycle_sno IS NULL
        BEGIN
            RAISERROR('cycle_sno is required.', 16, 1);
            RETURN;
        END

        IF @action IS NULL OR LTRIM(RTRIM(LOWER(@action))) NOT IN ('approve', 'reject')
        BEGIN
            RAISERROR('Invalid action. Must be ''approve'' or ''reject''.', 16, 1);
            RETURN;
        END
        SET @action = LOWER(LTRIM(RTRIM(@action)));

        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
        BEGIN
            RAISERROR('Invalid or missing approval_stages in JSON', 16, 1);
            RETURN;
        END

        IF @approved_by IS NULL OR LTRIM(RTRIM(@approved_by)) = ''
        BEGIN
            RAISERROR('Approver EC number is required.', 16, 1);
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.service_po_cycle WHERE cycle_sno = @cycle_sno AND status = 'PENDING_APPROVAL')
        BEGIN
            RAISERROR('Service PO cycle not found or not awaiting approval.', 16, 1);
            RETURN;
        END

        BEGIN TRANSACTION;

        CREATE TABLE #po_approval_stages (
            seq_no INT, approver_ecno VARCHAR(30), stage VARCHAR(100),
            required_approvals VARCHAR(10), is_mandatory CHAR(1), escalation_hours VARCHAR(10),
            approver_condition VARCHAR(200), next_approver_ecno VARCHAR(30),
            can_forward CHAR(1), can_backward CHAR(1), can_edit_data CHAR(1)
        );

        INSERT INTO #po_approval_stages (
            seq_no, approver_ecno, stage, required_approvals, is_mandatory,
            escalation_hours, approver_condition, next_approver_ecno,
            can_forward, can_backward, can_edit_data
        )
        SELECT
            CAST(ojBase.[key] AS INT),
            JSON_VALUE(ojBase.[value], '$.approver_ecno'),
            JSON_VALUE(ojBase.[value], '$.stage'),
            JSON_VALUE(ojBase.[value], '$.required_approvals'),
            JSON_VALUE(ojBase.[value], '$.is_mandatory'),
            JSON_VALUE(ojBase.[value], '$.escalation_hours'),
            JSON_VALUE(ojBase.[value], '$.approver_condition'),
            JSON_VALUE(ojBase.[value], '$.next_approver_ecno'),
            JSON_VALUE(ojBase.[value], '$.can_forward'),
            JSON_VALUE(ojBase.[value], '$.can_backward'),
            JSON_VALUE(ojBase.[value], '$.can_edit_data')
        FROM OPENJSON(@approval_stages) AS ojBase;

        IF @action = 'reject'
        BEGIN
            INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
            VALUES (@cycle_sno, 'REJECTED', @approved_by, @comments);

            UPDATE dbo.service_po_cycle SET status = 'REJECTED', current_approver_id = NULL WHERE cycle_sno = @cycle_sno;

            DROP TABLE #po_approval_stages;
            COMMIT TRANSACTION;
            SELECT 'REJECTED' AS result, @cycle_sno AS cycle_sno, @approved_by AS rejected_by, GETDATE() AS rejected_on;
            RETURN;
        END

        DECLARE @next_current_approver VARCHAR(30);
        SELECT @next_current_approver = next_stage.approver_ecno
        FROM (
            SELECT approver_ecno, LEAD(approver_ecno, 1, NULL) OVER (ORDER BY seq_no) AS next_approver_ecno
            FROM #po_approval_stages
        ) current_stage
        LEFT JOIN #po_approval_stages next_stage ON next_stage.approver_ecno = current_stage.next_approver_ecno
        WHERE current_stage.approver_ecno = @approved_by;

        INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
        VALUES (@cycle_sno, 'APPROVED', @approved_by, @comments);

        UPDATE dbo.service_po_cycle SET current_approver_id = @next_current_approver WHERE cycle_sno = @cycle_sno;

        DECLARE @out_po_basic_sno INT = NULL, @out_po_no VARCHAR(50) = NULL;

        IF @next_current_approver IS NULL
        BEGIN
            -- ── Final stage: raise ONE PO PER SUPPLIER in the cycle's split (sql/88) ──
            DECLARE @agreement_sno INT, @pr_basic_sno INT, @qty DECIMAL(18,4),
                    @discount_pct DECIMAL(5,2), @gst_pct DECIMAL(5,2),
                    @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT,
                    @service_sno INT, @service_name NVARCHAR(150), @rate_uom_sno INT, @agreement_no VARCHAR(30),
                    @service_type_sno INT, @period_end DATE;

            SELECT @agreement_sno = spc.agreement_sno, @pr_basic_sno = spc.pr_basic_sno, @qty = spc.qty,
                   @discount_pct = ISNULL(spc.discount_pct, 0), @gst_pct = ISNULL(spc.gst_pct, 0),
                   @com_sno = spc.com_sno, @div_sno = spc.div_sno, @brn_sno = spc.brn_sno, @dept_sno = spc.dept_sno
            FROM dbo.service_po_cycle spc
            WHERE spc.cycle_sno = @cycle_sno;

            SELECT @service_sno = sa.service_sno, @rate_uom_sno = sa.rate_uom_sno,
                   @agreement_no = sa.agreement_no, @period_end = sa.period_end_date,
                   @service_name = sm.service_name, @service_type_sno = sm.service_type_sno
            FROM dbo.service_agreement sa
            JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
            WHERE sa.agreement_sno = @agreement_sno;

            -- Defensive: a cycle with no split rows (none should exist after sql/88's
            -- backfill) falls back to the agreement's primary supplier at 100%.
            IF NOT EXISTS (SELECT 1 FROM dbo.service_po_cycle_vendor WHERE cycle_sno = @cycle_sno)
                INSERT INTO dbo.service_po_cycle_vendor (cycle_sno, vendor_sno, share_pct, rate_amount, net_cost)
                SELECT spc.cycle_sno, sa.vendor_sno, 100, spc.rate_amount, spc.net_cost
                FROM dbo.service_po_cycle spc
                JOIN dbo.service_agreement sa ON sa.agreement_sno = spc.agreement_sno
                WHERE spc.cycle_sno = @cycle_sno;

            DECLARE @supplier_count INT = (SELECT COUNT(*) FROM dbo.service_po_cycle_vendor WHERE cycle_sno = @cycle_sno);
            DECLARE @po_list VARCHAR(500) = '';
            DECLARE @cv_sno INT, @cv_vendor INT, @cv_rate DECIMAL(18,2), @cv_net DECIMAL(18,2), @cv_pct DECIMAL(9,6);
            DECLARE @new_po_sno INT, @new_po_no VARCHAR(50), @po_seq INT;
            DECLARE @po_year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));

            DECLARE po_cur CURSOR LOCAL FAST_FORWARD FOR
                SELECT cycle_vendor_sno, vendor_sno, rate_amount, net_cost, share_pct
                FROM dbo.service_po_cycle_vendor
                WHERE cycle_sno = @cycle_sno
                ORDER BY cycle_vendor_sno;

            OPEN po_cur;
            FETCH NEXT FROM po_cur INTO @cv_sno, @cv_vendor, @cv_rate, @cv_net, @cv_pct;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @po_seq = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
                FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
                WHERE po_df_no LIKE 'SVO-' + @po_year + '-%';
                SET @new_po_no = 'SVO-' + @po_year + '-' + RIGHT('0000' + CAST(@po_seq AS VARCHAR(4)), 4);

                INSERT INTO dbo.po_request_info (
                    vendor_sno, brn_sno, dept_sno, com_sno, div_sno, budget_sno, budget_code, pr_basic_sno,
                    po_date, required_date, purpose, terms_conditions, delivery_address,
                    is_active, workflow_types_id, current_approver_id, status, po_df_no, service_type_sno
                )
                VALUES (
                    @cv_vendor, @brn_sno, @dept_sno, @com_sno, @div_sno, NULL, NULL, @pr_basic_sno,
                    CAST(GETDATE() AS DATE), @period_end,
                    N'Recurring service PO — Agreement ' + @agreement_no + N' (' + @service_name + N')'
                        + CASE WHEN @supplier_count > 1
                               THEN N' — ' + CONVERT(NVARCHAR(12), CAST(@cv_pct AS DECIMAL(9,2))) + N'% share'
                               ELSE N'' END,
                    NULL, NULL,
                    'Y', NULL, NULL, 'A', @new_po_no, @service_type_sno
                );
                SET @new_po_sno = SCOPE_IDENTITY();

                INSERT INTO dbo.po_item_details (
                    po_basic_sno, pr_item_sno, service_sno, prod_name, specification,
                    qty, unit, unit_name, agreed_unit_price, total_cost, discount_pct, tax_pct, net_cost,
                    remarks, po_section, created_by, created_date, is_active
                )
                SELECT
                    @new_po_sno, NULL, @service_sno, sm.service_name, '',
                    @qty, @rate_uom_sno, um.uom_name, @cv_rate, @cv_rate * @qty, @discount_pct, @gst_pct, @cv_net,
                    NULL, 'SERVICE', @approved_by, GETDATE(), '1'
                FROM dbo.service_master sm
                LEFT JOIN dbo.uom_master um ON um.uom_sno = @rate_uom_sno
                WHERE sm.service_sno = @service_sno;

                INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
                VALUES (@new_po_sno, 'APPROVED_ISSUED', @approved_by, N'Issued after Service PO cycle approval (Agreement ' + @agreement_no + N').', 'Y');

                UPDATE dbo.service_po_cycle_vendor SET po_basic_sno = @new_po_sno WHERE cycle_vendor_sno = @cv_sno;

                -- The first PO is the "primary" one kept on the cycle / recurring log
                IF @out_po_basic_sno IS NULL
                BEGIN
                    SET @out_po_basic_sno = @new_po_sno;
                    SET @out_po_no = @new_po_no;
                END
                SET @po_list = @po_list + CASE WHEN @po_list = '' THEN '' ELSE ',' END + CAST(@new_po_sno AS VARCHAR(20));

                FETCH NEXT FROM po_cur INTO @cv_sno, @cv_vendor, @cv_rate, @cv_net, @cv_pct;
            END
            CLOSE po_cur;
            DEALLOCATE po_cur;

            UPDATE dbo.service_po_cycle SET status = 'GENERATED', po_basic_sno = @out_po_basic_sno WHERE cycle_sno = @cycle_sno;

            UPDATE dbo.service_agreement_recurring_pr_log
            SET po_basic_sno = @out_po_basic_sno, po_no = @out_po_no
            WHERE agreement_sno = @agreement_sno AND pr_basic_sno = @pr_basic_sno;
        END

        DROP TABLE #po_approval_stages;
        COMMIT TRANSACTION;

        SELECT
            'SUCCESS' AS result, @cycle_sno AS cycle_sno, @approved_by AS approved_by, GETDATE() AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE') AS next_approver,
            @out_po_basic_sno AS po_basic_sno, @out_po_no AS po_no,
            @po_list AS po_basic_snos, @supplier_count AS po_count;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF OBJECT_ID('tempdb..#po_approval_stages') IS NOT NULL DROP TABLE #po_approval_stages;
        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO
CREATE OR ALTER   PROCEDURE dbo.sp_nt_GetServicePoCyclesForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT spc.cycle_sno, spc.agreement_sno, sa.agreement_no,
           sm.service_name, st.service_type_code, st.service_type_name,
           k.company_name AS vendor_name,
           (
               SELECT cv.vendor_sno, kv.company_name AS vendor_name, cv.share_pct, cv.rate_amount, cv.net_cost
               FROM dbo.service_po_cycle_vendor cv
               LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = cv.vendor_sno
               WHERE cv.cycle_sno = spc.cycle_sno
               ORDER BY cv.cycle_vendor_sno
               FOR JSON PATH
           ) AS vendors_json,
           spc.billing_period_start, spc.qty, spc.rate_amount, spc.discount_pct, spc.gst_pct, spc.net_cost,
           sa.ceiling_amount, spc.status, spc.current_approver_id, spc.entered_by, spc.entered_at,
           stt.facility_type, stt.rate_type, stt.interest_rate_pct, stt.sanctioned_amount,
           (
               SELECT ws.stage_order_json
               FROM dbo.workflow_stage ws
               WHERE ws.workflow_types_id = spc.workflow_types_id AND ws.is_active = 'Y'
           ) AS stage_order_json
    FROM dbo.service_po_cycle spc
    JOIN dbo.service_agreement sa ON sa.agreement_sno = spc.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.service_agreement_statutory stt ON stt.agreement_sno = sa.agreement_sno
    WHERE spc.status = 'PENDING_APPROVAL' AND spc.current_approver_id = @Ecno
    ORDER BY spc.cycle_sno DESC;
END;
GO
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateBranchRecords]  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
      
    BEGIN TRY  
        -- Input validation  
        IF @jsonInput IS NULL OR @jsonInput = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'JSON input is required' as ErrorMessage;  
            RETURN;  
        END  
  
        IF JSON_VALUE(@jsonInput, '$.brn_name') IS NULL OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.brn_name'))) = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'Branch name is required' as ErrorMessage;  
            RETURN;  
        END  
  
        BEGIN TRANSACTION;  
          
        DECLARE @AddressId INT;  
        DECLARE @BranchId INT;  
          
        -- Step 1: Insert Address data and get the generated add_sno  
        INSERT INTO address_master(  
            add_door_no, add_street, add_city, add_state, add_state_code, add_pin_code,  
            add_reg_door_no, add_reg_street, add_reg_city, add_reg_state, add_reg_pincode,add_pan  
   ,is_gst_applicable,add_gst,add_tan,add_cin  
        )  
        SELECT *  
        FROM OPENJSON(@jsonInput)  
        WITH (  
            add_door_no VARCHAR(50) '$.add_door_no',  
            add_street VARCHAR(100) '$.add_street',  
            add_city VARCHAR(50) '$.add_city',  
            add_state VARCHAR(50) '$.add_state',  
            add_state_code VARCHAR(10) '$.add_state_code',  
            add_pin_code VARCHAR(10) '$.add_pin_code',  
            add_reg_door_no VARCHAR(50) '$.add_reg_door_no',  
            add_reg_street VARCHAR(100) '$.add_reg_street',  
            add_reg_city VARCHAR(50) '$.add_reg_city',  
            add_reg_state VARCHAR(50) '$.add_reg_state',  
            add_reg_pincode VARCHAR(10) '$.add_reg_pincode',  
   add_pan VARCHAR(10) '$.add_pan',  
            is_gst_applicable VARCHAR(1) '$.is_gst_applicable',  
            add_gst VARCHAR(15) '$.add_gst',  
            add_tan VARCHAR(10) '$.add_tan',  
            add_cin VARCHAR(21) '$.add_cin'  
        );  
          
        -- Get the generated address ID  
        SET @AddressId = SCOPE_IDENTITY();  
      
        -- Step 2: Insert Company data with the address foreign key  
        INSERT INTO branch_master(  
            brn_name, brn_prefix,com_sno,div_sno, add_sno
            ,is_active
      ,created_date
        )  
        SELECT brn_name, brn_prefix,com_sno,div_sno, @AddressId,'Y',getDate()  
        FROM OPENJSON(@jsonInput)  
        WITH (  
            brn_name VARCHAR(100) '$.brn_name',  
            brn_prefix VARCHAR(10) '$.brn_prefix',  
    com_sno VARCHAR(10) '$.com_sno',  
    div_sno VARCHAR(10) '$.div_sno'  
        );  
          
        -- Get the generated company ID  
        SET @BranchId = SCOPE_IDENTITY();  
          
        COMMIT TRANSACTION;  
          
        -- Return success with both IDs  
        SELECT   
            @BranchId as BranchId,  
            @AddressId as AddressId,  
            'Success' as Status,  
            'Company and address created successfully' as Message;  
              
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
          
        -- Return detailed error information  
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();  
        DECLARE @ErrorNumber INT = ERROR_NUMBER();  
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();  
          
        -- Re-throw the original error  
        THROW;  
    END CATCH  
END  
GO
CREATE OR ALTER   PROCEDURE dbo.usp_InsertVendorDrivenPurchaseRequest
    @jsonInput NVARCHAR(MAX),
    @pr_no     VARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ------------------------------------------------------------------
    -- 1. Parse input JSON
    -- ------------------------------------------------------------------
    DECLARE
        @com_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.com_sno') AS INT),
        @div_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.div_sno') AS INT),
        @brn_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.brn_sno') AS INT),
        @dept_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.dept_sno') AS INT),
        @reg_date           DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.req_date') AS DATE),
        @required_date      DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.required_date') AS DATE),
        @priority_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.priority_sno') AS INT),
        @purpose            NVARCHAR(500) = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.purpose'), ''),
        @vendor_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.vendor_sno') AS INT),
        @payment_cycle_days INT           = COALESCE(TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.payment_cycle_days') AS INT), 15),
        @attachment         NVARCHAR(500) = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.attachment'), ''),
        @created_by         VARCHAR(20)   = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.created_by'), ''),
        @items              NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items'),

        @workflow_types_id  INT,
        @workflow_id        INT,
        @first_approver     VARCHAR(20),
        @pr_basic_sno       INT,
        @financial_year     VARCHAR(10),
        @sequence_number    INT,
        @items_inserted     INT;

    DECLARE @insertedItems TABLE
    (
        pr_item_sno    INT,
        item_rate      DECIMAL(18,4),
        gst_pct        DECIMAL(5,2),
        discount_pct   DECIMAL(5,2),
        taxable_amount DECIMAL(18,2),
        gst_amount     DECIMAL(18,2)
    );

    -- ------------------------------------------------------------------
    -- 2. Validate input
    -- ------------------------------------------------------------------
    IF ISJSON(@jsonInput) <> 1
        THROW 59001, 'Invalid vendor-driven requisition payload.', 1;

    IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
       OR @reg_date IS NULL OR @required_date IS NULL OR @priority_sno IS NULL
       OR @vendor_sno IS NULL OR @created_by IS NULL
        THROW 59002, 'Company, division, branch, department, dates, priority, supplier and creator are required.', 1;

    IF @payment_cycle_days < 1 OR @payment_cycle_days > 365
        THROW 59003, 'payment_cycle_days must be between 1 and 365.', 1;

    IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
        THROW 59004, 'At least one vendor-driven item is required.', 1;

    IF @attachment IS NULL
        THROW 59009, 'A verification document (bill/receipt) for the requisition is required.', 1;

    IF EXISTS (
        SELECT 1
        FROM OPENJSON(@items)
        WHERE TRY_CAST(JSON_VALUE(value, '$.prod_sno') AS INT) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.unit_sno') AS INT) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)) <= 0
           OR TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)) < 0
           OR (
                JSON_VALUE(value, '$.discount_pct') IS NOT NULL
                AND (
                    TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)) IS NULL
                    OR TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)) < 0
                    OR TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)) > 100
                )
              )
    )
        THROW 59005, 'Every vendor-driven item requires product, unit, positive quantity, rate, and (if present) a discount_pct between 0 and 100.', 1;

    -- ------------------------------------------------------------------
    -- 3. Resolve approval workflow
    -- ------------------------------------------------------------------
    SELECT
        @workflow_id       = wt.workflow_id,
        @workflow_types_id = wt.workflow_types_id
    FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE wt.com_sno  = @com_sno
      AND wt.div_sno  = @div_sno
      AND wt.brn_sno  = @brn_sno
      AND wt.dept_sno = @dept_sno
      AND awm.entity_type = 'VendorDrivenPurchaseRequisition';

    IF @workflow_types_id IS NULL
        THROW 59006, 'No VendorDrivenPurchaseRequisition workflow is configured for this organisation scope.', 1;

    SELECT @first_approver = JSON_VALUE(stage_member.value, '$.approver_ecno')
    FROM dbo.vw_workflow_stages ws
    CROSS APPLY OPENJSON(ws.stages_json) stage_group
    CROSS APPLY OPENJSON(JSON_VALUE(stage_group.value, '$.stage_order_json')) stage_member
    WHERE ws.workflow_types_id = @workflow_types_id
      AND stage_group.[key]  = '0'
      AND stage_member.[key] = '0';

    IF @first_approver IS NULL
        THROW 59007, 'The VendorDrivenPurchaseRequisition workflow has no first approver.', 1;

    -- ------------------------------------------------------------------
    -- 4. Create the requisition
    -- ------------------------------------------------------------------
    BEGIN TRANSACTION;
    BEGIN TRY

        SET @financial_year = dbo.fn_GetFinancialYear(GETDATE());

        SELECT @sequence_number = ISNULL(MAX(TRY_CAST(RIGHT(pr_no, 4) AS INT)), 0) + 1
        FROM dbo.pr_basic_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE 'VPR' + @financial_year + '-%';

        SET @pr_no = 'VPR' + @financial_year + '-' + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);

        INSERT INTO dbo.pr_basic_info
        (
            pr_no, com_sno, div_sno, brn_sno, dept_sno, reg_date, required_date,
            priority_sno, purpose, request_mode, vendor_sno, payment_cycle_days,
            is_active, created_by, created_date, workflow_types_id, current_approver_id, status
        )
        VALUES
        (
            @pr_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @reg_date, @required_date,
            @priority_sno, @purpose, 'VENDOR_DRIVEN', @vendor_sno, @payment_cycle_days,
            'Y', @created_by, GETDATE(), @workflow_types_id, @first_approver, 'P'
        );

        SET @pr_basic_sno = SCOPE_IDENTITY();

        INSERT INTO dbo.pr_item_details
        (
            pr_no, pr_basic_sno, prod_sno, qty, unit, est_cost, total_cost,
            remarks, specification, item_type, is_active,
            created_by, created_date, item_description, item_rate, gst_pct,
            discount_pct, taxable_amount, gst_amount
        )
        OUTPUT
            inserted.pr_item_sno, inserted.item_rate, inserted.gst_pct,
            inserted.discount_pct, inserted.taxable_amount, inserted.gst_amount
        INTO @insertedItems
        SELECT
            @pr_no,
            @pr_basic_sno,
            TRY_CAST(JSON_VALUE(value, '$.prod_sno') AS INT),
            TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)),
            TRY_CAST(JSON_VALUE(value, '$.unit_sno') AS INT),
            TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
            t.taxable_amount + g2.gst_amount,
            NULLIF(JSON_VALUE(value, '$.remarks'), ''),
            NULLIF(JSON_VALUE(value, '$.specification'), ''),
            'vendor_driven',
            'Y',
            @created_by,
            GETDATE(),
            NULLIF(JSON_VALUE(value, '$.prod_name'), ''),
            TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
            base.gst_pct_val,
            base.disc_pct,
            t.taxable_amount,
            g2.gst_amount
        FROM OPENJSON(@items)
        CROSS APPLY (
            SELECT
                gross       = TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4))
                              * TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
                disc_pct    = COALESCE(TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)), 0),
                gst_pct_val = COALESCE(TRY_CAST(JSON_VALUE(value, '$.gst_pct') AS DECIMAL(5,2)), 0)
        ) base
        CROSS APPLY (
            SELECT taxable_amount = ROUND(base.gross * (1 - base.disc_pct / 100), 2)
        ) t
        CROSS APPLY (
            SELECT gst_amount = ROUND(t.taxable_amount * base.gst_pct_val / 100, 2)
        ) g2;

        SET @items_inserted = @@ROWCOUNT;
        IF @items_inserted = 0
            THROW 59008, 'No vendor-driven items were inserted.', 1;

        INSERT INTO dbo.pr_vendor_driven_info (pr_basic_sno, vendor_sno, payment_cycle_days, attachment, created_by, created_date)
        VALUES (@pr_basic_sno, @vendor_sno, @payment_cycle_days, @attachment, @created_by, GETDATE());

        INSERT INTO dbo.pr_vendor_driven_item_details (pr_item_sno, item_rate, gst_pct, discount_pct, taxable_amount, gst_amount)
        SELECT pr_item_sno, item_rate, gst_pct, discount_pct, taxable_amount, gst_amount
        FROM @insertedItems;

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    -- ------------------------------------------------------------------
    -- 5. Return result
    -- ------------------------------------------------------------------
    SELECT
        @pr_basic_sno   AS pr_basic_sno,
        @pr_no          AS pr_no,
        @items_inserted AS items_inserted,
        'SUCCESS'       AS result;

END;
GO
CREATE OR ALTER   PROCEDURE [dbo].[sp_InsertKYCData]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE
            @kyc_basic_info_sno INT,
            @company_name       NVARCHAR(255),
            @contact_name       NVARCHAR(100),
            @email              NVARCHAR(100),
            @mobile_number      VARCHAR(15),
            @business_type      NVARCHAR(50),
            @is_gst_avail       CHAR(1),
            @gst_no             VARCHAR(20),
            @is_msme_avail      CHAR(1),
            @msme_no            VARCHAR(20),
            @pan_no             VARCHAR(20),
            @created_by         VARCHAR(50),
            @addresses          NVARCHAR(MAX),
            @bankDetails        NVARCHAR(MAX),
            @contacts           NVARCHAR(MAX),
            @document           NVARCHAR(MAX),
            @approver_ecno      VARCHAR(20),
            @supplier_cat_code  VARCHAR(20),
            @legal_name         VARCHAR(100),
            @trade_name         VARCHAR(100),
            @txp_type           VARCHAR(10),
            @gst_status         VARCHAR(1),
            @gst_blk_status     VARCHAR(10),
            @date_of_reg        date,
            @workflow_types_id  INT;
        -- Extract scalar values from JSON
        SELECT
            @company_name  = JSON_VALUE(@jsonInput, '$.company_name'),
            @contact_name  = JSON_VALUE(@jsonInput, '$.contact_name'),
            @email         = JSON_VALUE(@jsonInput, '$.email'),
            @mobile_number = JSON_VALUE(@jsonInput, '$.mobile_number'),
            @business_type = JSON_VALUE(@jsonInput, '$.business_type'),
            @is_gst_avail  = CASE WHEN JSON_VALUE(@jsonInput, '$.is_gst_avail')  = 'true' THEN 'Y' ELSE 'N' END,
            @gst_no        = JSON_VALUE(@jsonInput, '$.gst_no'),
            @is_msme_avail = CASE WHEN JSON_VALUE(@jsonInput, '$.is_msme_avail') = 'true' THEN 'Y' ELSE 'N' END,
            @msme_no       = JSON_VALUE(@jsonInput, '$.msme_no'),
            @pan_no        = JSON_VALUE(@jsonInput, '$.pan_no'),
            @created_by    = ISNULL(JSON_VALUE(@jsonInput, '$.created_by'), ''),
            @supplier_cat_code=JSON_VALUE(@jsonInput, '$.supplier_cat_code'),
            @legal_name=JSON_VALUE(@jsonInput, '$.legal_name'),
            @trade_name= JSON_VALUE(@jsonInput, '$.trade_name'),
            @txp_type=  JSON_VALUE(@jsonInput, '$.txp_type'),
            @gst_status  =  JSON_VALUE(@jsonInput, '$.gst_status'),
            @gst_blk_status=  JSON_VALUE(@jsonInput, '$.gst_blk_status'),
            @date_of_reg  =JSON_VALUE(@jsonInput, '$.date_of_reg');



        SET @workflow_types_id = 32; -- Non_Trade KYC workflow (Dev uses 5); environment-specific, do not sync from Dev
      SELECT @approver_ecno = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key]  = '0'
          AND s2.[key] = '0';

        --IF @approver_ecno IS NULL
        --    THROW 50007, 'No approver found for the first stage of the workflow.', 1;


        SET @addresses   = JSON_QUERY(@jsonInput, '$.addresses');
        SET @bankDetails = JSON_QUERY(@jsonInput, '$.bankDetails');
        SET @contacts    = JSON_QUERY(@jsonInput, '$.contacts');
        SET @document    = JSON_VALUE(@jsonInput, '$.document');

        -- 1. Insert into kyc_basic_info
        INSERT INTO kyc_basic_info (
            company_name, contact_person, email, mobile_number,
            business_type, is_gst_avail, gst_no, is_msme_avail,
            msme_no, pan_no, created_by, created_date, is_active, status ,workflow_types_id ,approver_ecno ,supplier_cat_code,
            legal_name,trade_name,txp_type, gst_status,gst_blk_status ,date_of_reg
        )
        VALUES (
            @company_name, @contact_name, @email, @mobile_number,
            @business_type, @is_gst_avail, @gst_no, @is_msme_avail,
            @msme_no, @pan_no, @created_by, GETDATE(), 'Y', 'P' ,@workflow_types_id ,@approver_ecno ,@supplier_cat_code
            ,@legal_name,@trade_name,@txp_type,@gst_status,@gst_blk_status,@date_of_reg
        );

        SET @kyc_basic_info_sno = SCOPE_IDENTITY();

        -- 2. Insert into kyc_address_info
        IF ISJSON(@addresses) = 1
        BEGIN
            INSERT INTO kyc_address_info (
                kyc_basic_info_sno, address_type, door_no, street, area, city,
                taluk, state, state_code, pincode, location_link, is_primary,
                created_date, is_active, status
            )
            SELECT
                @kyc_basic_info_sno,
                CASE WHEN JSON_VALUE(value, '$.isPrimary') = 'true' THEN 'PRIMARY' ELSE 'SECONDARY' END,
                JSON_VALUE(value, '$.door_no'),
                JSON_VALUE(value, '$.street'),
                JSON_VALUE(value, '$.area'),
                JSON_VALUE(value, '$.city'),
                JSON_VALUE(value, '$.taluk'),
                JSON_VALUE(value, '$.state'),
                TRY_CONVERT(INT, JSON_VALUE(value, '$.state_code')),
                JSON_VALUE(value, '$.pincode'),
                NULLIF(JSON_VALUE(value, '$.location_link'), ''),
                CASE WHEN JSON_VALUE(value, '$.isPrimary') = 'true' THEN 'Y' ELSE 'N' END,
                GETDATE(), 'Y', 'P'
            FROM OPENJSON(@addresses);
        END

        -- 3. Insert into kyc_bank_info
        IF ISJSON(@bankDetails) = 1
        BEGIN
            INSERT INTO kyc_bank_info (
                kyc_basic_info_sno, ac_holder_name, ac_number, ac_type, ifsc,
                bank_name, bank_branch_name, bank_address, is_primary,
                created_date, is_active, status
            )
            SELECT
                @kyc_basic_info_sno,
                JSON_VALUE(value, '$.ac_holder_name'),
                JSON_VALUE(value, '$.ac_number'),
                JSON_VALUE(value, '$.ac_type'),
                JSON_VALUE(value, '$.ifsc'),
                JSON_VALUE(value, '$.bank_name'),
                JSON_VALUE(value, '$.bank_branch_name'),
                JSON_VALUE(value, '$.bank_address'),
                CASE WHEN JSON_VALUE(value, '$.isPrimary') = 'true' THEN 'Y' ELSE 'N' END,
                GETDATE(), 'Y', 'P'
            FROM OPENJSON(@bankDetails);
        END

        -- 4. Insert into kyc_contact_info
        IF ISJSON(@contacts) = 1
        BEGIN
            INSERT INTO kyc_contact_info (
                kyc_basic_info_sno, contact_type, contact_name, contact_position,
                contact_mobile, contact_email, created_date, is_active, status
            )
            SELECT
                @kyc_basic_info_sno,
                CASE WHEN JSON_VALUE(value, '$.isPrimary') = 'true' THEN 'PRIMARY' ELSE 'SECONDARY' END,
                JSON_VALUE(value, '$.ownername'),
                JSON_VALUE(value, '$.ownerposition'),
                JSON_VALUE(value, '$.ownermobile'),
                JSON_VALUE(value, '$.owneremail'),
                GETDATE(), 'Y', 'P'
            FROM OPENJSON(@contacts);
        END

        -- 5. Insert into kyc_document_info
        IF ISJSON(@document) = 1
        BEGIN
            INSERT INTO kyc_document_info (
                kyc_basic_info_sno, document_type, document_name,
                document_path, file_size, uploaded_date, is_active, status
            )
            SELECT
                @kyc_basic_info_sno,
                JSON_VALUE(value, '$.documentType'),
                JSON_VALUE(value, '$.filename'),
                JSON_VALUE(value, '$.url'),
                JSON_VALUE(value, '$.size'),
                GETDATE(), 'Y', 'P'
            FROM OPENJSON(@document);
        END

        COMMIT TRANSACTION;
                  SELECT
            @kyc_basic_info_sno AS kyc_basic_info_sno,
            'KYC Data Saved Successfully' AS message,
            'Success' AS Status;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT            = ERROR_SEVERITY();
        DECLARE @ErrorState    INT            = ERROR_STATE();

        SELECT @ErrorMessage AS errorMessage, 'Error' AS Status;
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END;
GO
CREATE OR ALTER   PROCEDURE [dbo].[sp_nt_CreateCompanyRecords]  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
  
    BEGIN TRY  
        -- Input validation  
        SELECT @jsonInput
        IF @jsonInput IS NULL OR @jsonInput = ''  
        BEGIN  
            SELECT 'Failed' AS Status, 'Input is required' AS ErrorMessage;  
            RETURN;  
        END  
  
        IF JSON_VALUE(@jsonInput, '$.com_name') IS NULL   
            OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.com_name'))) = ''  
        BEGIN  
            SELECT 'Failed' AS Status, 'Company name is required' AS ErrorMessage;  
            RETURN;  
        END  
  
        BEGIN TRANSACTION;  
  
        DECLARE @AddressId INT;  
        DECLARE @CompanyId INT;  
  
        -- Step 1: Insert Address data  
        INSERT INTO address_master (  
            add_door_no, add_street, add_city, add_state, add_state_code, add_pin_code,  
            add_reg_door_no, add_reg_street, add_reg_city, add_reg_state, add_reg_pincode,  
            add_pan, is_gst_applicable, add_gst, add_tan, add_cin  
        )  
        SELECT *  
        FROM OPENJSON(@jsonInput)  
        WITH (  
            add_door_no       VARCHAR(50)  '$.add_door_no',  
            add_street        VARCHAR(100) '$.add_street',  
            add_city          VARCHAR(50)  '$.add_city',  
            add_state         VARCHAR(50)  '$.add_state',  
            add_state_code    VARCHAR(10)  '$.add_state_code',  
            add_pin_code      VARCHAR(10)  '$.add_pin_code',  
            add_reg_door_no   VARCHAR(50)  '$.add_reg_door_no',  
            add_reg_street    VARCHAR(100) '$.add_reg_street',  
            add_reg_city      VARCHAR(50)  '$.add_reg_city',  
            add_reg_state     VARCHAR(50)  '$.add_reg_state',  
            add_reg_pincode   VARCHAR(10)  '$.add_reg_pincode',  
            add_pan           VARCHAR(10)  '$.add_pan',  
            is_gst_applicable VARCHAR(1)   '$.is_gst_applicable',  
            add_gst           VARCHAR(15)  '$.add_gst',  
            add_tan           VARCHAR(10)  '$.add_tan',  
            add_cin           VARCHAR(21)  '$.add_cin'  
        );  
  
        -- Get the generated address ID  
        SET @AddressId = SCOPE_IDENTITY();  
  
        -- Step 2: Insert Company data  ✅ Fixed  
        -- Literal values (is_active, created_date) must be outside OPENJSON WITH clause  
        INSERT INTO company_master (  
            com_name, com_prefix, is_active, created_date, add_sno  
        )  
        SELECT  
            com_name,  
            com_prefix,  
            'Y',          -- literal default  
            GETDATE(),    -- literal default  
            @AddressId    -- FK from Step 1  
        FROM OPENJSON(@jsonInput)  
        WITH (  
            com_name   VARCHAR(100) '$.com_name',  
            com_prefix VARCHAR(10)  '$.com_prefix'  
        );  
  
        -- Get the generated company ID  
        SET @CompanyId = SCOPE_IDENTITY();  
  
        COMMIT TRANSACTION;  
  
        -- Return success with both IDs  
        SELECT  
            
            'Success'   AS Status,  
            'Company and address created successfully' AS Message;  
  
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
  
        -- Re-throw the original error to the caller  
        THROW;  
    END CATCH  
END
GO
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateDeptRecords]  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
      
    BEGIN TRY  
        BEGIN TRANSACTION;  
         
        -- Insert into dept_master table  
        INSERT INTO dept_master (  
            com_sno,div_sno, brn_sno, dept_name,is_active,created_date, dept_code  
        )  
        SELECT  
            com_sno,  
   div_sno,  
            brn_sno,  
            dept_name, 
            'Y',
            getDate(),
            dept_code  
        FROM OPENJSON(@jsonInput)  
        WITH (  
            com_sno INT '$.com_sno',  
   div_sno INT '$.div_sno',  
            brn_sno INT '$.brn_sno',  
            dept_name VARCHAR(50) '$.dept_name',  
            dept_code VARCHAR(50) '$.dept_code'
            
        );  
          
        COMMIT TRANSACTION;  
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
          
        -- Return detailed error information  
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();  
        DECLARE @ErrorNumber INT = ERROR_NUMBER();  
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();  
          
        THROW;  
    END CATCH  
END
GO
-- ============================================================
-- sp_nt_CreateVendorDrivenPOFromPR — sources vendor/rate/gst/discount from
-- the extension tables when building the PO. Its final SELECT is extended
-- (was just po_basic_sno/po_no/result) to also return the vendor's contact
-- info, dates, and a FOR JSON PATH item array, so the Node approval path
-- can auto-email the PO to the vendor in one round trip after final
-- approval (see PR.controller.js#approvePr and PRApprovalScreen.tsx).
-- ============================================================
CREATE OR ALTER   PROCEDURE dbo.sp_nt_CreateVendorDrivenPOFromPR
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @pr_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT),
        @created_by VARCHAR(20) = NULLIF(JSON_VALUE(@jsonInput, '$.created_by'), ''),
        @vendor_sno INT,
        @com_sno INT,
        @div_sno INT,
        @brn_sno INT,
        @dept_sno INT,
        @required_date DATE,
        @purpose NVARCHAR(500),
        @workflow_types_id INT,
        @po_basic_sno INT,
        @po_no VARCHAR(50),
        @sequence_number INT;

    IF @pr_basic_sno IS NULL OR @created_by IS NULL
        THROW 59020, 'pr_basic_sno and created_by are required.', 1;

    SELECT
        @vendor_sno = pvd.vendor_sno,
        @com_sno = p.com_sno,
        @div_sno = p.div_sno,
        @brn_sno = p.brn_sno,
        @dept_sno = p.dept_sno,
        @required_date = p.required_date,
        @purpose = p.purpose,
        @workflow_types_id = p.workflow_types_id
    FROM dbo.pr_basic_info p WITH (UPDLOCK, HOLDLOCK)
    INNER JOIN dbo.pr_vendor_driven_info pvd ON pvd.pr_basic_sno = p.pr_basic_sno
    WHERE p.pr_basic_sno = @pr_basic_sno
      AND p.request_mode = 'VENDOR_DRIVEN'
      AND p.status = 'A'
      AND p.is_active = 'Y';

    IF @vendor_sno IS NULL
        THROW 59021, 'Vendor-driven PR not found or not finally approved.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        SELECT @po_basic_sno = po_basic_sno, @po_no = po_df_no
        FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_basic_sno = @pr_basic_sno
          AND vendor_sno = @vendor_sno
          AND is_active = 'Y';

        IF @po_basic_sno IS NULL
        BEGIN
            SELECT @sequence_number = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
            FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
            WHERE po_df_no LIKE 'VPO-' + CAST(YEAR(GETDATE()) AS VARCHAR(4)) + '-%';

            SET @po_no = 'VPO-' + CAST(YEAR(GETDATE()) AS VARCHAR(4)) + '-'
                + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);

            INSERT INTO dbo.po_request_info (
                vendor_sno, brn_sno, dept_sno, com_sno, div_sno, pr_basic_sno,
                po_date, required_date, purpose, is_active, workflow_types_id,
                current_approver_id, status, po_df_no
            )
            VALUES (
                @vendor_sno, @brn_sno, @dept_sno, @com_sno, @div_sno, @pr_basic_sno,
                CAST(GETDATE() AS DATE), @required_date, @purpose, 'Y', @workflow_types_id,
                NULL, 'A', @po_no
            );

            SET @po_basic_sno = SCOPE_IDENTITY();

            INSERT INTO dbo.po_item_details (
                po_basic_sno, pr_item_sno, prod_sno, prod_name, specification,
                qty, unit, unit_name, agreed_unit_price, total_cost, discount_pct,
                tax_pct, net_cost, remarks, po_section, created_by, created_date, is_active
            )
            SELECT
                @po_basic_sno,
                pid.pr_item_sno,
                pid.prod_sno,
                COALESCE(pid.item_description, product.prod_name),
                pid.specification,
                pid.qty,
                pid.unit,
                uom.uom_name,
                pvid.item_rate,
                pvid.taxable_amount,
                pvid.discount_pct,
                pvid.gst_pct,
                pid.total_cost,
                pid.remarks,
                'MATERIAL',
                @created_by,
                GETDATE(),
                '1'
            FROM dbo.pr_item_details pid
            INNER JOIN dbo.pr_vendor_driven_item_details pvid ON pvid.pr_item_sno = pid.pr_item_sno
            LEFT JOIN dbo.product_master product ON product.prod_sno = pid.prod_sno
            LEFT JOIN dbo.uom_master uom ON uom.uom_sno = pid.unit
            WHERE pid.pr_basic_sno = @pr_basic_sno
              AND pid.is_active = 'Y';

            IF @@ROWCOUNT = 0
                THROW 59022, 'Vendor-driven PR has no active item lines.', 1;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT
        @po_basic_sno AS po_basic_sno,
        @po_no AS po_no,
        'SUCCESS' AS result,
        CONVERT(VARCHAR(10), po.po_date, 120) AS po_date,
        CONVERT(VARCHAR(10), po.required_date, 120) AS required_date,
        po.purpose,
        po.vendor_sno,
        k.company_name,
        k.email,
        (
            SELECT
                poi.prod_name,
                poi.qty,
                poi.unit_name,
                poi.agreed_unit_price AS rate,
                poi.discount_pct,
                poi.tax_pct AS gst_pct,
                poi.net_cost AS total_amount
            FROM dbo.po_item_details poi
            WHERE poi.po_basic_sno = @po_basic_sno
              AND poi.is_active = '1'
            FOR JSON PATH
        ) AS items
    FROM dbo.po_request_info po
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = po.vendor_sno
    WHERE po.po_basic_sno = @po_basic_sno;
END;
GO
CREATE OR ALTER  PROCEDURE [dbo].[sp_nt_CreateDivRecords]  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
      
    BEGIN TRY  
        -- Input validation  
        IF @jsonInput IS NULL OR @jsonInput = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'JSON input is required' as ErrorMessage;  
            RETURN;  
        END  
  
        -- Validate JSON format  
        IF ISJSON(@jsonInput) = 0  
        BEGIN  
            SELECT 'Failed' as Status, 'Invalid JSON format' as ErrorMessage;  
            RETURN;  
        END  
  
        -- Validate required fields  
        IF JSON_VALUE(@jsonInput, '$.div_name') IS NULL OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.div_name'))) = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'Division name is required' as ErrorMessage;  
            RETURN;  
        END  
  
        -- Validate com_sno is provided  
        IF JSON_VALUE(@jsonInput, '$.com_sno') IS NULL OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.com_sno'))) = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'Company serial number (com_sno) is required' as ErrorMessage;  
            RETURN;  
        END  
  
        BEGIN TRANSACTION;     
          
        DECLARE @InsertedCount INT;  
          
        -- Insert records  
        INSERT INTO division_master(  
            div_name,   
            div_prefix,   
            div_type,  
            com_sno  ,
            is_active,
            created_date
        )  
        SELECT   
            LTRIM(RTRIM(div_name)) as div_name,   
            LTRIM(RTRIM(div_prefix)) as div_prefix,   
            LTRIM(RTRIM(div_type)) as div_type,  
            LTRIM(RTRIM(com_sno)) as com_sno,
              'Y',
        GetDate()
        FROM OPENJSON(@jsonInput)  
        WITH (  
            div_name VARCHAR(100) '$.div_name',  
            div_prefix VARCHAR(10) '$.div_prefix',  
            div_type VARCHAR(10) '$.div_type',  
            com_sno VARCHAR(10) '$.com_sno'  
        ) 
      
        WHERE LTRIM(RTRIM(div_name)) IS NOT NULL AND LTRIM(RTRIM(div_name)) != '';  
          
        SET @InsertedCount = @@ROWCOUNT;  
          
        COMMIT TRANSACTION;  
          
        -- Return success message with count  
        SELECT   
            'Success' as Status,   
            CONCAT('Successfully inserted ', @InsertedCount, ' division record(s)') as Message,  
            @InsertedCount as RecordsInserted;  
              
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
          
        -- Return detailed error information  
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();  
        DECLARE @ErrorNumber INT = ERROR_NUMBER();  
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();  
          
        -- Re-throw the original error  
        THROW;  
    END CATCH  
END
GO
CREATE OR ALTER   PROCEDURE dbo.sp_nt_GetServiceAgreementsForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT sa.agreement_sno, sa.agreement_no, sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
           sa.service_sno, sm.service_name, st.service_type_code, st.service_type_name,
           sa.vendor_sno, k.company_name AS vendor_name,
           (
               SELECT v.vendor_sno, kv.company_name AS vendor_name, v.share_amount, v.share_pct
               FROM dbo.service_agreement_vendor v
               LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = v.vendor_sno
               WHERE v.agreement_sno = sa.agreement_sno
               ORDER BY v.sort_order, v.agreement_vendor_sno
               FOR JSON PATH
           ) AS vendors_json,
           sa.qty, sa.rate_amount, sa.rate_uom_sno, um.uom_name AS rate_uom_name,
           sa.recurrence_cadence_sno, rc.cadence_name,
           sa.po_generation_day, sa.notify_days_before,
           sa.period_start_date, sa.period_end_date, sa.agreement_doc_url, sa.remarks, sa.terms_conditions,
           sa.ceiling_amount,
           stt.facility_type, stt.facility_ref_no, stt.sanctioned_amount, stt.drawing_power,
           stt.rate_type, stt.benchmark_rate_pct, stt.spread_pct, stt.interest_rate_pct,
           stt.benchmark_name, stt.disbursed_amount, stt.disbursement_date, stt.interest_payment_day, stt.day_count_basis,
           cv.cur_version AS version_no,
           (SELECT ver.action_type FROM dbo.service_agreement_version ver WHERE ver.agreement_sno = sa.agreement_sno AND ver.version_no = cv.cur_version) AS submit_action,
           (SELECT ver.terms_json FROM dbo.service_agreement_version ver WHERE ver.agreement_sno = sa.agreement_sno AND ver.version_no = cv.cur_version - 1) AS prev_terms_json,
           sa.current_approver_id, sa.status, sa.created_by, sa.created_at,
           (
               SELECT ws.stage_order_json
               FROM dbo.workflow_stage ws
               WHERE ws.workflow_types_id = sa.workflow_types_id AND ws.is_active = 'Y'
           ) AS stage_order_json
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = sa.rate_uom_sno
    LEFT JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    LEFT JOIN dbo.service_agreement_statutory stt ON stt.agreement_sno = sa.agreement_sno
    OUTER APPLY (SELECT MAX(ver.version_no) AS cur_version FROM dbo.service_agreement_version ver WHERE ver.agreement_sno = sa.agreement_sno) cv
    WHERE sa.is_active = 'Y' AND sa.status = 'P' AND sa.current_approver_id = @Ecno
    ORDER BY sa.agreement_sno DESC;
END;
GO
CREATE OR ALTER     PROCEDURE [dbo].[sp_nt_CreateGstStateRecords]  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
      
    BEGIN TRY  
        -- Input validation  
        IF @jsonInput IS NULL OR @jsonInput = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'JSON input is required' as ErrorMessage;  
            RETURN;  
        END  
          
        -- Validate JSON format  
        IF ISJSON(@jsonInput) = 0  
        BEGIN  
            SELECT 'Failed' as Status, 'Invalid JSON format' as ErrorMessage;  
            RETURN;  
        END  
          
        -- Validate required fields  
        IF JSON_VALUE(@jsonInput, '$.gst_state_un_name') IS NULL OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.gst_state_un_name'))) = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'State/Un name is required' as ErrorMessage;  
            RETURN;  
        END  
        
        BEGIN TRANSACTION;     
          
        DECLARE @InsertedCount INT;  
     
        -- Insert records into gst_master table (corrected table name)  
        INSERT INTO [Non_Trade].[dbo].[gst_master](  
            gst_state_un_name,   
            gst_code,
            is_active,
            created_date,
            gst_alpha_code  
        )  
        SELECT   
            LTRIM(RTRIM(gst_state_un_name)) as gst_state_un_name,   
            LTRIM(RTRIM(gst_code)) as gst_code, 
            'Y',
            getDate(),
            LTRIM(RTRIM(gst_alpha_code)) as gst_alpha_code  
        FROM OPENJSON(@jsonInput)  
        WITH (  
            gst_state_un_name VARCHAR(50) '$.gst_state_un_name',  
            gst_code VARCHAR(10) '$.gst_code',  
            gst_alpha_code VARCHAR(5) '$.gst_alpha_code'  
        );  
          
        SET @InsertedCount = @@ROWCOUNT;  
          
        COMMIT TRANSACTION;  
          
        -- Return success message with count  
        SELECT   
            'Success' as Status,   
            CONCAT('Successfully inserted ', @InsertedCount, ' GST record(s)') as Message,  
            @InsertedCount as RecordsInserted;  
              
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
          
          DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();  
        DECLARE @ErrorNumber INT = ERROR_NUMBER();  
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();  
          
        -- Re-throw the original error  
        THROW;  
    END CATCH  
END
GO
CREATE OR ALTER   PROCEDURE dbo.sp_nt_IssueRecurringServicePOCycle
    @jsonInput NVARCHAR(MAX),
    @silent BIT = 0,
    @out_result VARCHAR(30) = NULL OUTPUT,
    @out_po_basic_sno INT = NULL OUTPUT,
    @out_po_no VARCHAR(50) = NULL OUTPUT,
    @out_pr_basic_sno INT = NULL OUTPUT,
    @out_pr_no VARCHAR(20) = NULL OUTPUT,
    @out_cycle_sno INT = NULL OUTPUT,
    @out_cycle_status VARCHAR(20) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @agreement_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
    DECLARE @billing_period_start DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.billing_period_start') AS DATE);
    DECLARE @issued_by VARCHAR(20) = ISNULL(JSON_VALUE(@jsonInput, '$.issued_by'), 'SYSTEM');

    -- Captured before any statement that could fail, so the CATCH block can
    -- always tell (a) whether a caller transaction was already open, and
    -- (b) whether THIS proc actually opened a transaction/savepoint of its
    -- own that it is responsible for undoing.
    DECLARE @outer_trancount INT = @@TRANCOUNT;
    DECLARE @own_scope_opened BIT = 0;

    BEGIN TRY
        IF @agreement_sno IS NULL OR @billing_period_start IS NULL
            THROW 58210, 'agreement_sno and billing_period_start are required.', 1;

        IF EXISTS (SELECT 1 FROM dbo.service_agreement_recurring_pr_log WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start)
        BEGIN
            SET @out_result = 'SKIPPED_ALREADY_CLAIMED';
            IF @silent = 0 SELECT @out_result AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start;
            RETURN;
        END

        DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @service_sno INT, @vendor_sno INT,
                @qty DECIMAL(18,4), @rate_amount DECIMAL(18,2), @rate_uom_sno INT, @agreement_no VARCHAR(30),
                @service_name NVARCHAR(150), @agr_status CHAR(1), @period_end DATE, @service_type_code VARCHAR(30);

        SELECT @com_sno = sa.com_sno, @div_sno = sa.div_sno, @brn_sno = sa.brn_sno, @dept_sno = sa.dept_sno,
               @service_sno = sa.service_sno, @vendor_sno = sa.vendor_sno, @qty = sa.qty, @rate_amount = sa.rate_amount,
               @rate_uom_sno = sa.rate_uom_sno, @agreement_no = sa.agreement_no, @agr_status = sa.status,
               @period_end = sa.period_end_date, @service_name = sm.service_name, @service_type_code = st.service_type_code
        FROM dbo.service_agreement sa
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sa.agreement_sno = @agreement_sno;

        IF @agr_status IS NULL THROW 58211, 'Agreement not found.', 1;
        IF @agr_status <> 'A' THROW 58212, 'Agreement is not Approved.', 1;

        -- sql/89: a Statutory agreement is a LOAN. It raises no PR / PO / cycle -- interest
        -- is billed through Bank Payment Vouchers (Loan Payments) instead.
        IF @service_type_code = 'STATUTORY'
        BEGIN
            SET @out_result = 'SKIPPED_STATUTORY';
            IF @silent = 0 SELECT @out_result AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start;
            RETURN;
        END
        IF @billing_period_start > @period_end THROW 58213, 'billing_period_start is past the agreement period_end_date.', 1;

        -- Claim the slot before doing any real work, outside the main
        -- transaction, so it survives a rollback and guarantees idempotency
        -- even under a concurrent sweep.
        INSERT INTO dbo.service_agreement_recurring_pr_log (agreement_sno, billing_period_start, status)
        VALUES (@agreement_sno, @billing_period_start, 'PENDING');

        -- Nestable-safe: reuse the caller's transaction via a savepoint
        -- instead of opening our own when one is already open (see file
        -- header) — a failure below then only undoes this proc's own
        -- work, never the caller's.
        IF @outer_trancount = 0
            BEGIN TRANSACTION;
        ELSE
            SAVE TRANSACTION svp_IssueCycle;
        SET @own_scope_opened = 1;

        DECLARE @default_priority_sno INT;
        SELECT TOP 1 @default_priority_sno = priority_sno
        FROM dbo.priority_master
        WHERE is_active = 'Y'
        ORDER BY CASE WHEN priority_name = 'Medium' THEN 0 ELSE 1 END, priority_sno;
        IF @default_priority_sno IS NULL
            THROW 58214, 'No active priority_master row found to assign to the auto-generated PR.', 1;

        DECLARE @current_year VARCHAR(10) = dbo.fn_GetFinancialYear(GETDATE());
        DECLARE @pr_prefix VARCHAR(20) = 'PR' + @current_year;
        DECLARE @pr_seq INT;
        SELECT @pr_seq = ISNULL(MAX(CASE WHEN pr_no LIKE @pr_prefix + '%' THEN TRY_CAST(SUBSTRING(pr_no, LEN(@pr_prefix) + 1, LEN(pr_no)) AS INT) ELSE 0 END), 0) + 1
        FROM dbo.pr_basic_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE @pr_prefix + '%';
        DECLARE @pr_no VARCHAR(20) = @pr_prefix + RIGHT('0000' + CAST(@pr_seq AS VARCHAR(4)), 4);

        -- Auto-approved: status='A', no workflow — same audit-trail-only PR
        -- as before this file, untouched.
        INSERT INTO dbo.pr_basic_info (
            pr_no, com_sno, div_sno, brn_sno, dept_sno, reg_date, required_date, priority_sno, purpose,
            is_active, created_by, created_date, workflow_types_id, current_approver_id, status
        )
        VALUES (
            @pr_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @billing_period_start, @billing_period_start, @default_priority_sno,
            N'Auto-generated recurring PR — Service Agreement ' + @agreement_no,
            'Y', @issued_by, GETDATE(), NULL, NULL, 'A'
        );
        DECLARE @pr_basic_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.pr_item_details (
            pr_no, pr_basic_sno, prod_sno, qty, unit, est_cost, total_cost, remarks, specification,
            item_type, service_sno, agreement_sno, is_active, created_by, created_date
        )
        VALUES (
            @pr_no, @pr_basic_sno, NULL, @qty, @rate_uom_sno, @rate_amount, @rate_amount * @qty, '', '',
            'service', @service_sno, @agreement_sno, 'Y', @issued_by, GETDATE()
        );

        -- ── Queue a service_po_cycle instead of issuing the PO directly.
        --    Fixed: nothing to enter, straight to Pending Approval with the
        --    agreement's already-agreed rate/qty. Unfixed: Pending Entry,
        --    rate resolved later by sp_nt_SubmitServicePoEntry. ───────────
        DECLARE @cycle_status VARCHAR(20), @cycle_workflow_types_id INT = NULL, @cycle_approver VARCHAR(30) = NULL,
                @cycle_rate DECIMAL(18,2) = NULL, @cycle_net_cost DECIMAL(18,2) = NULL;

        IF @service_type_code = 'FIXED_RECURRING'
        BEGIN
            SET @cycle_status = 'PENDING_APPROVAL';
            SET @cycle_rate = @rate_amount;
            SET @cycle_net_cost = @rate_amount * @qty;
            EXEC dbo.sp_nt_ResolveServicePoWorkflow
                @com_sno = @com_sno, @div_sno = @div_sno, @brn_sno = @brn_sno, @dept_sno = @dept_sno,
                @workflow_types_id = @cycle_workflow_types_id OUTPUT, @first_approver = @cycle_approver OUTPUT;
        END
        ELSE
            SET @cycle_status = 'PENDING_ENTRY';

        INSERT INTO dbo.service_po_cycle (
            agreement_sno, com_sno, div_sno, brn_sno, dept_sno, billing_period_start,
            pr_basic_sno, pr_no, qty, rate_amount, net_cost, status,
            workflow_types_id, current_approver_id
        )
        VALUES (
            @agreement_sno, @com_sno, @div_sno, @brn_sno, @dept_sno, @billing_period_start,
            @pr_basic_sno, @pr_no, @qty, @cycle_rate, @cycle_net_cost, @cycle_status,
            @cycle_workflow_types_id, @cycle_approver
        );
        DECLARE @cycle_sno INT = SCOPE_IDENTITY();

        -- sql/88: a Fixed cycle already knows its rate, so split it across the
        -- agreement's suppliers now (Unfixed/Statutory do this when the rate is entered).
        IF @cycle_status = 'PENDING_APPROVAL'
        BEGIN
            DECLARE @split_net DECIMAL(18,2);
            EXEC dbo.sp_nt_BuildServicePoCycleSplit
                @cycle_sno = @cycle_sno, @agreement_sno = @agreement_sno, @rate_amount = @rate_amount, @qty = @qty,
                @discount_pct = 0, @gst_pct = 0, @out_net_cost = @split_net OUTPUT;
            UPDATE dbo.service_po_cycle SET net_cost = @split_net WHERE cycle_sno = @cycle_sno;
        END

        INSERT INTO dbo.service_po_cycle_history (cycle_sno, action_type, status_by, comment)
        VALUES (@cycle_sno, 'CYCLE_CREATED', @issued_by,
                CASE WHEN @cycle_status = 'PENDING_APPROVAL' THEN N'Fixed agreement — queued directly for approval.' ELSE N'Unfixed agreement — awaiting rate/GST entry.' END);

        UPDATE dbo.service_agreement_recurring_pr_log
        SET status = 'CREATED', pr_basic_sno = @pr_basic_sno, pr_no = @pr_no, modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start;

        IF @outer_trancount = 0
            COMMIT TRANSACTION;

        SET @out_result = 'SUCCESS';
        SET @out_pr_basic_sno = @pr_basic_sno;
        SET @out_pr_no = @pr_no;
        SET @out_cycle_sno = @cycle_sno;
        SET @out_cycle_status = @cycle_status;

        IF @silent = 0
            SELECT 'SUCCESS' AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start,
                   @pr_basic_sno AS pr_basic_sno, @pr_no AS pr_no, @cycle_sno AS cycle_sno, @cycle_status AS cycle_status;
    END TRY
    BEGIN CATCH
        IF @own_scope_opened = 1 AND XACT_STATE() <> 0
        BEGIN
            IF @outer_trancount = 0 OR XACT_STATE() = -1
                ROLLBACK TRANSACTION;
            ELSE
                ROLLBACK TRANSACTION svp_IssueCycle;
        END

        UPDATE dbo.service_agreement_recurring_pr_log
        SET status = 'FAILED', error_message = ERROR_MESSAGE(), modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start AND status = 'PENDING';

        SET @out_result = 'ERROR';
        IF @silent = 0 THROW;
    END CATCH
END;
GO

 CREATE OR ALTER     PROCEDURE [dbo].[sp_nt_CreatePriorityRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
       
       
       
      
        BEGIN TRANSACTION;   
        
        DECLARE @InsertedCount INT;
     
        -- Insert records into ac_master table
        INSERT INTO [Non_Trade].[dbo].[priority_master](
            priority_name, 
            priority_desc
        )
        SELECT 
            LTRIM(RTRIM(priority_name)) as priority_name, 
            LTRIM(RTRIM(priority_desc)) as priority_desc
        FROM OPENJSON(@jsonInput)
        WITH (
            priority_name VARCHAR(50) '$.priority_name',
            priority_desc VARCHAR(50) '$.priority_desc'
        );
        
        SET @InsertedCount = @@ROWCOUNT;
        
        COMMIT TRANSACTION;
        
        -- Return success message with count
        SELECT 
            'Success' as Status, 
            CONCAT('Successfully inserted ', @InsertedCount, ' record(s)') as Message,
            @InsertedCount as RecordsInserted;
            
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        
        -- Return detailed error information
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        THROW;
    END CATCH
END

GO
CREATE OR ALTER     PROCEDURE [dbo].[sp_nt_CreateUomRecords]  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
      
    BEGIN TRY  
        -- Input validation  
        IF @jsonInput IS NULL OR @jsonInput = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'JSON input is required' as ErrorMessage;  
            RETURN;  
        END  
          
        -- Validate JSON format  
        IF ISJSON(@jsonInput) = 0  
        BEGIN  
            SELECT 'Failed' as Status, 'Invalid JSON format' as ErrorMessage;  
            RETURN;  
        END  
          
        -- Validate required fields  
        IF JSON_VALUE(@jsonInput, '$.uom_code') IS NULL OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.uom_code'))) = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'uom_code is required' as ErrorMessage;  
            RETURN;  
        END  
        
        BEGIN TRANSACTION;     
          
        DECLARE @InsertedCount INT;  
       
        -- Insert records into uom_master table  
        INSERT INTO [Non_Trade].[dbo].[uom_master](  
            uom_code,   
            uom_name,   
            uom_class,  
            uom_base_uom_flag,
            is_active,
            created_date,
            uom_con_factor
            
        )  
        SELECT   
            LTRIM(RTRIM(uom_code)) as uom_code,   
            LTRIM(RTRIM(uom_name)) as uom_name,   
            LTRIM(RTRIM(uom_class)) as uom_class,  
            LTRIM(RTRIM(uom_base_uom_flag)) as uom_base_uom_flag,
            'Y',
            getDate(),
            uom_con_factor  
        FROM OPENJSON(@jsonInput)  
        WITH (  
            uom_code CHAR(5) '$.uom_code',  
            uom_name VARCHAR(50) '$.uom_name',  
            uom_class VARCHAR(30) '$.uom_class',  
            uom_base_uom_flag CHAR(1) '$.uom_base_uom_flag',  
            uom_con_factor DECIMAL(18,6) '$.uom_con_factor'  
        )  
          
        SET @InsertedCount = @@ROWCOUNT;  
          
        COMMIT TRANSACTION;  
          
        -- Return success message with count  
        SELECT   
            'Success' as Status,   
            CONCAT('Successfully inserted ', @InsertedCount, ' UOM record(s)') as Message,  
            @InsertedCount as RecordsInserted;  
              
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
          
        -- Return detailed error information  
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();  
        DECLARE @ErrorNumber INT = ERROR_NUMBER();  
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();  
          
        -- Re-throw the original error  
        THROW;  
    END CATCH  
END  
GO
CREATE OR ALTER   PROCEDURE [dbo].[sp_nt_CreateScreenRecords]  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
  
    BEGIN TRY  
        -- Validate JSON is present and valid  
        IF @jsonInput IS NULL OR @jsonInput = ''  
        BEGIN  
            SELECT 'Failed' AS Status, 'JSON input is required' AS ErrorMessage;  
            RETURN;  
        END  
        IF ISJSON(@jsonInput) = 0  
        BEGIN  
            SELECT 'Failed' AS Status, 'Invalid JSON format' AS ErrorMessage;  
            RETURN;  
        END  
  
        -- Validate screen_name  
        IF JSON_VALUE(@jsonInput, '$.screen_name') IS NULL OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.screen_name'))) = ''  
        BEGIN  
            SELECT 'Failed' AS Status, 'Screen name is required' AS ErrorMessage;  
            RETURN;  
        END  
  
        BEGIN TRANSACTION;  
  
        -- Generate screen_code if not provided or empty  
        DECLARE @screen_code VARCHAR(10);  
        IF JSON_VALUE(@jsonInput, '$.screen_code') IS NULL OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.screen_code'))) = ''  
        BEGIN  
            DECLARE @NextScreenNo INT = 1;  
            SELECT @NextScreenNo = ISNULL(MAX(CAST(SUBSTRING(screen_code, 2, LEN(screen_code)) AS INT)), 0) + 1  
            FROM screens  
            WHERE LEFT(screen_code,1) = 'S'  
                  AND ISNUMERIC(SUBSTRING(screen_code, 2, LEN(screen_code))) = 1;  
  
            SET @screen_code = CONCAT('S', @NextScreenNo);  
        END  
        ELSE  
        BEGIN  
            SET @screen_code = JSON_VALUE(@jsonInput, '$.screen_code');  
        END  
  
        -- Table variable to capture inserted screen_id  
        DECLARE @InsertedScreen TABLE (screen_id INT);  
  
        -- Insert record  
        INSERT INTO screens (  
            screen_name,  
            screen_code,  
            parent_screen_id, 
            is_active,
            created_date,
            display_order  
        )  
        OUTPUT INSERTED.screen_id INTO @InsertedScreen  
        VALUES (  
            JSON_VALUE(@jsonInput, '$.screen_name'),  
            @screen_code,  
            TRY_CAST(JSON_VALUE(@jsonInput, '$.parent_screen_id') AS INT), 
            'Y',
            getDate(),
            TRY_CAST(JSON_VALUE(@jsonInput, '$.display_order') AS INT)  
        );  
  
        DECLARE @InsertedScreenId INT;  
        SELECT TOP 1 @InsertedScreenId = screen_id FROM @InsertedScreen;  
  
        COMMIT TRANSACTION;  
  
        SELECT   
            'Success' AS Status,  
            'Screen created successfully' AS Message,  
            @InsertedScreenId AS screen_id,  
            @screen_code AS screen_code;  
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
  
        SELECT   
            'Failed' AS Status,  
            ERROR_MESSAGE() AS ErrorMessage,  
            ERROR_NUMBER() AS ErrorNumber,  
            ERROR_SEVERITY() AS ErrorSeverity;  
    END CATCH  
END  
GO
  CREATE OR ALTER   PROCEDURE [dbo].[sp_nt_CreatePermissionRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        -- Validate JSON presence & format
        IF @jsonInput IS NULL OR LTRIM(RTRIM(@jsonInput)) = ''
        BEGIN
            SELECT 'Failed' AS Status, 'JSON input is required' AS ErrorMessage;
            RETURN;
        END

        IF ISJSON(@jsonInput) = 0
        BEGIN
            SELECT 'Failed' AS Status, 'Invalid JSON format' AS ErrorMessage;
            RETURN;
        END

        -- Validate permission_name (required)
        DECLARE @permName NVARCHAR(255) = LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.permission_name')));
        IF @permName IS NULL OR @permName = ''
        BEGIN
            SELECT 'Failed' AS Status, 'permission_name is required' AS ErrorMessage;
            RETURN;
        END

        BEGIN TRANSACTION;

        -- Determine permission_code (generate if not provided)
        DECLARE @permission_code VARCHAR(20) = NULL;
        DECLARE @inCode NVARCHAR(50) = LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.permission_code')));

        IF @inCode IS NULL OR @inCode = ''
        BEGIN
            DECLARE @NextPermNo INT = 1;
            SELECT @NextPermNo = ISNULL(MAX(TRY_CAST(SUBSTRING(permission_code, 2, LEN(permission_code)) AS INT)), 0) + 1
            FROM dbo.permissions
            WHERE LEFT(permission_code,1) = 'P'
                  AND ISNUMERIC(SUBSTRING(permission_code, 2, LEN(permission_code))) = 1;

            SET @permission_code = CONCAT('P', @NextPermNo);
        END
        ELSE
        BEGIN
            SET @permission_code = @inCode;
        END

        -- Prepare other fields
        DECLARE @permission_description NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.permission_description');
        DECLARE @is_active CHAR(1) = COALESCE(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.is_active'))), 'Y');

        -- Table var to capture inserted id
        DECLARE @Inserted TABLE (permission_id INT);

        -- Insert
        INSERT INTO dbo.permissions (
            permission_name,
            permission_code,
            permission_description,
            is_active
        )
        OUTPUT INSERTED.permission_id INTO @Inserted
        VALUES (
            @permName,
            @permission_code,
            @permission_description,
            @is_active
        );

        DECLARE @InsertedPermissionId INT;
        SELECT TOP 1 @InsertedPermissionId = permission_id FROM @Inserted;

        COMMIT TRANSACTION;

        -- Return success + inserted info
        SELECT
            'Success' AS Status,
            'Permission created successfully' AS Message,
            @InsertedPermissionId AS permission_id,
            @permission_code AS permission_code;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SELECT
            'Failed' AS Status,
            ERROR_MESSAGE() AS ErrorMessage,
            ERROR_NUMBER() AS ErrorNumber,
            ERROR_SEVERITY() AS ErrorSeverity;
    END CATCH
END

GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreatePOFromQuotation
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @pr_basic_sno       INT            = CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT);
        DECLARE @vendor_sno         INT            = CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @com_sno            INT            = CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno            INT            = CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno            INT            = CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno           INT            = CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @budget_sno         INT            = CAST(JSON_VALUE(@jsonInput, '$.budget_sno') AS INT);
        DECLARE @budget_code        VARCHAR(20)    = LEFT(ISNULL(JSON_VALUE(@jsonInput, '$.budget_code'), ''), 20);
        DECLARE @priority_sno       INT            = CAST(JSON_VALUE(@jsonInput, '$.priority_sno') AS INT);
        DECLARE @po_date            DATE           = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.po_date') AS DATE), CAST(GETDATE() AS DATE));
        DECLARE @required_date      DATE           = TRY_CAST(JSON_VALUE(@jsonInput, '$.required_date') AS DATE);
        DECLARE @purpose            VARCHAR(200)   = LEFT(ISNULL(JSON_VALUE(@jsonInput, '$.purpose'), ''), 200);
        DECLARE @terms_conditions   VARCHAR(MAX)   = JSON_VALUE(@jsonInput, '$.terms_conditions');
        DECLARE @delivery_address   VARCHAR(500)   = LEFT(ISNULL(JSON_VALUE(@jsonInput, '$.delivery_address'), ''), 500);
        DECLARE @split_pr_no        NVARCHAR(30)   = JSON_VALUE(@jsonInput, '$.split_pr_no');
        DECLARE @created_by         VARCHAR(20)    = JSON_VALUE(@jsonInput, '$.created_by');

        IF @pr_basic_sno IS NULL OR @vendor_sno IS NULL
            THROW 51001, 'pr_basic_sno and vendor_sno are required.', 1;

        DECLARE @pr_no VARCHAR(30);
        SELECT @pr_no = pr_no FROM pr_basic_info WHERE pr_basic_sno = @pr_basic_sno;
        IF @pr_no IS NULL
            THROW 51002, 'pr_no not found in pr_basic_info for given pr_basic_sno.', 1;

        IF @split_pr_no IS NULL SET @split_pr_no = @pr_no;

        IF NOT EXISTS (SELECT 1 FROM OPENJSON(@jsonInput, '$.items'))
            THROW 51003, 'No items found in JSON.', 1;

        INSERT INTO po_request_info (
            vendor_sno, brn_sno, dept_sno, com_sno, div_sno,
            budget_sno, budget_code, pr_basic_sno,
            po_date, required_date,
            priority_sno, purpose, terms_conditions, delivery_address,
            is_active, workflow_types_id, current_approver_id,
            status, po_df_no, split_pr_no
        )
        VALUES (
            @vendor_sno, @brn_sno, @dept_sno, @com_sno, @div_sno,
            @budget_sno, @budget_code, @pr_basic_sno,
            @po_date, @required_date,
            @priority_sno, @purpose, @terms_conditions, @delivery_address,
            'Y', 0, '0',
            'A', NULL, @split_pr_no
        );

        DECLARE @po_basic_sno INT = SCOPE_IDENTITY();
        DECLARE @po_no VARCHAR(30) = 'PO-' + CAST(YEAR(@po_date) AS VARCHAR(4)) + '-' + RIGHT('0000' + CAST(@po_basic_sno AS VARCHAR(10)), 4);

        UPDATE po_request_info SET po_df_no = @po_no WHERE po_basic_sno = @po_basic_sno;

        INSERT INTO po_item_details (
            po_basic_sno, pr_item_sno, prod_sno, prod_name,
            budget_sno, specification,
            qty, unit, unit_name,
            agreed_unit_price, total_cost,
            discount_pct, tax_pct, net_cost,
            remarks,
            created_by, created_date,
            is_active, split_pr_no
        )
        SELECT
            @po_basic_sno,
            TRY_CAST(JSON_VALUE(item.value, '$.pr_item_sno') AS INT),
            TRY_CAST(JSON_VALUE(item.value, '$.prod_sno') AS INT),
            LEFT(JSON_VALUE(item.value, '$.prod_name'), 200),
            @budget_sno,
            LEFT(ISNULL(JSON_VALUE(item.value, '$.specification'), ''), 200),
            TRY_CAST(JSON_VALUE(item.value, '$.qty') AS DECIMAL(18,4)),
            TRY_CAST(JSON_VALUE(item.value, '$.unit') AS INT),
            LEFT(JSON_VALUE(item.value, '$.unit_name'), 200),
            TRY_CAST(JSON_VALUE(item.value, '$.unit_price') AS DECIMAL(18,4)),
            ISNULL(TRY_CAST(JSON_VALUE(item.value, '$.qty') AS DECIMAL(18,4)), 0)
                * ISNULL(TRY_CAST(JSON_VALUE(item.value, '$.unit_price') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(JSON_VALUE(item.value, '$.discount_pct') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(JSON_VALUE(item.value, '$.tax_pct') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(JSON_VALUE(item.value, '$.total_amount') AS DECIMAL(18,4)),
                   ISNULL(TRY_CAST(JSON_VALUE(item.value, '$.qty') AS DECIMAL(18,4)), 0)
                       * ISNULL(TRY_CAST(JSON_VALUE(item.value, '$.unit_price') AS DECIMAL(18,4)), 0)),
            LEFT(ISNULL(JSON_VALUE(item.value, '$.remarks'), ''), 200),
            @created_by, GETDATE(),
            'Y', @split_pr_no
        FROM OPENJSON(@jsonInput, '$.items') AS item;

        COMMIT TRANSACTION;

        SELECT
            @po_basic_sno AS po_basic_sno,
            @po_no        AS po_no,
            @pr_no        AS pr_no,
            @vendor_sno   AS vendor_sno,
            'SUCCESS'     AS result;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        SELECT
            ERROR_NUMBER()  AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage,
            ERROR_LINE()    AS ErrorLine,
            'FAILED'        AS result;
    END CATCH
END
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetNotifications
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ecno VARCHAR(50) = JSON_VALUE(@jsonInput, '$.ecno');
    IF @ecno IS NULL
    BEGIN
        RAISERROR('ecno is required.', 16, 1);
        RETURN;
    END

    SELECT TOP 50
        notif_id AS id, type, title, message, data, is_read AS [read],
        CONVERT(VARCHAR(30), created_at, 127) AS createdAt
    FROM dbo.nt_notifications
    WHERE ecno = @ecno
    ORDER BY created_at DESC;
END;
GO
-- ── sp_get_pr_details_for_approval — PR approval queue, now hierarchy-scoped ──
CREATE OR ALTER   PROCEDURE dbo.sp_get_pr_details_for_approval
    @Ecno           VARCHAR(20),
    @HierarchyJson  NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        SELECT
            vw.*
        FROM dbo.vw_PR_Basic_Info vw
        WHERE vw.current_approver_id = @Ecno
          AND vw.status = 'P'
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
        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber   INT            = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT            = ERROR_SEVERITY();
        THROW;
    END CATCH
END;


GO
CREATE OR ALTER   PROCEDURE dbo.sp_nt_ResolveServicePoWorkflow
    @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT,
    @workflow_types_id INT OUTPUT,
    @first_approver VARCHAR(30) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @workflow_types_id = wt.workflow_types_id
    FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
      AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
      AND awm.entity_type = 'ServicePO';

    IF @workflow_types_id IS NULL
        THROW 58310, 'No ServicePO workflow configuration found for this company/division/branch/department.', 1;

    SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
    FROM dbo.vw_workflow_stages AS ws
    CROSS APPLY OPENJSON(ws.stages_json) AS s
    CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
    WHERE ws.workflow_types_id = @workflow_types_id
      AND s.[key] = '0' AND s2.[key] = '0';

    IF @first_approver IS NULL
        THROW 58311, 'No approver found for the first stage of the ServicePO workflow.', 1;
END;
GO
CREATE OR ALTER     PROCEDURE [dbo].[sp_nt_CreateWorkflowMaster]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        -- Input validation
        IF @jsonInput IS NULL OR @jsonInput = ''
        BEGIN
            SELECT 'Failed' AS Status, 'JSON input is required' AS ErrorMessage;
            RETURN;
        END

        -- Validate JSON format
        IF ISJSON(@jsonInput) = 0
        BEGIN
            SELECT 'Failed' AS Status, 'Invalid JSON format' AS ErrorMessage;
            RETURN;
        END

        BEGIN TRANSACTION;

        DECLARE @InsertedCount INT;

        -- Insert records into approval_workflow_master
        INSERT INTO [Non_Trade].[dbo].[approval_workflow_master] (
            workflow_name,
            workflow_code,
            entity_type,
            [description],
            is_active,
            created_by,
            created_at
        )
        SELECT
            LTRIM(RTRIM(workflow_name))   AS workflow_name,
            LTRIM(RTRIM(workflow_code))   AS workflow_code,
            LTRIM(RTRIM(entity_type))     AS entity_type,
            [description],
            ISNULL(is_active, 'Y')        AS is_active,   -- default 'Y' if not provided
            created_by,
            ISNULL(created_at, GETDATE()) AS created_at   -- default current timestamp
        FROM OPENJSON(@jsonInput)
        WITH (
            workflow_name  VARCHAR(200) '$.workflow_name',
            workflow_code  VARCHAR(100) '$.workflow_code',
            entity_type    VARCHAR(100) '$.entity_type',
            [description]  NVARCHAR(MAX) '$.description',
            is_active      CHAR(1)       '$.is_active',
            created_by     INT           '$.created_by',
            created_at     DATETIME      '$.created_at'
        );

        SET @InsertedCount = @@ROWCOUNT;

        COMMIT TRANSACTION;

        -- Return success message with count
        SELECT
            'Success'                                                    AS Status,
            CONCAT('Successfully inserted ', @InsertedCount, ' workflow record(s)') AS Message,
            @InsertedCount                                               AS RecordsInserted;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber   INT            = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT            = ERROR_SEVERITY();

        -- Return structured error instead of re-throwing (optional: use THROW to bubble up)
        SELECT
            'Failed'         AS Status,
            @ErrorMessage    AS ErrorMessage,
            @ErrorNumber     AS ErrorNumber,
            @ErrorSeverity   AS ErrorSeverity;

        -- Uncomment below if you want to re-throw to the caller instead:
        -- THROW;
    END CATCH
END

GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @cat_name        NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.cat_name'),
            @cat_description NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.cat_description'),
            @cat_notes       NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.cat_notes'),
            @created_by      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @cat_name IS NULL OR LTRIM(RTRIM(@cat_name)) = ''
       OR @cat_notes IS NULL OR LTRIM(RTRIM(@cat_notes)) = ''
    BEGIN
        THROW 50002, N'cat_name and cat_notes (product code prefix) are required.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.category_master WHERE cat_name = @cat_name AND cat_active = 'Y')
    BEGIN
        THROW 50003, N'A category with this name already exists.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.category_master WHERE cat_notes = @cat_notes AND cat_active = 'Y')
    BEGIN
        THROW 50004, N'A category with this code prefix already exists.', 1;
        RETURN;
    END;

    INSERT INTO dbo.category_master (
        cat_name, cat_description, cat_notes, cat_active, cat_created_date, cat_created_by
    )
    VALUES (
        @cat_name, @cat_description, @cat_notes, 'Y', GETDATE(), @created_by
    );

    SELECT SCOPE_IDENTITY() AS cat_sno,
           @cat_name        AS cat_name,
           N'SUCCESS'       AS status,
           N'Category created successfully.' AS message;
END;
GO
CREATE OR ALTER     PROCEDURE dbo.sp_nt_GetPODetailForSupplier  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
  
    /* ------------------------------------------------------------------  
       1. Parse input  
       ------------------------------------------------------------------ */  
    DECLARE @kyc_basic_info_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');  
    DECLARE @po_basic_sno       INT = JSON_VALUE(@jsonInput, '$.po_basic_sno');  
  
    /* ------------------------------------------------------------------  
       2. Guard clause  
       ------------------------------------------------------------------ */  
    IF @po_basic_sno IS NULL OR @kyc_basic_info_sno IS NULL  
    BEGIN  
        RAISERROR('po_basic_sno and kyc_basic_info_sno are required.', 16, 1);  
        RETURN;  
    END  
  
    /* ------------------------------------------------------------------  
       3. PO header + nested item lines  
       ------------------------------------------------------------------ */  
    SELECT  
        -- header  
        p.po_basic_sno,  
        p.po_df_no                                          AS po_no,  
        CONVERT(VARCHAR(10), p.po_date,       120)          AS po_date,  
        CONVERT(VARCHAR(10), p.required_date, 120)          AS required_date,  
        p.delivery_address,  
        p.terms_conditions,  
        p.purpose,  
        p.status,  
  
        -- acknowledgement  
        p.supplier_ack_status,  
        CONVERT(VARCHAR(30), p.supplier_ack_date, 120)      AS supplier_ack_date,  
  
        -- parties  
        c.com_name                                          AS com_name,  
        k.company_name                                      AS vendor_name,  
  
        -- line items  
        (  
            SELECT  
                i.po_item_sno,  
                i.prod_sno,  
                pm.prod_name,  
                i.specification,  
                i.qty                   AS ordered_qty,  
                um.uom_name             AS unit_name,  
                i.agreed_unit_price     AS unit_price,  
                i.net_cost              AS total_amount  
            FROM dbo.po_item_details  i  inner join product_master pm on i.prod_sno=pm.prod_sno inner join uom_master um on um.uom_sno=i.unit
            WHERE i.po_basic_sno = p.po_basic_sno  
              AND i.is_active    = 1  
            ORDER BY i.po_item_sno  
            FOR JSON PATH  
        )                                                   AS items  
  
    FROM dbo.po_request_info AS p  
        LEFT JOIN dbo.company_master  AS c ON c.com_sno            = p.com_sno  
        LEFT JOIN dbo.kyc_basic_info  AS k ON k.kyc_basic_info_sno = p.vendor_sno  
  
    WHERE p.is_active    = 'Y'  
      AND p.po_basic_sno = @po_basic_sno  
      AND p.vendor_sno   = @kyc_basic_info_sno;  
END;  
GO
-- ── 3. sp_nt_GetPRTrackingTimeline — add stage chain + full ordered history ─
-- Same 11 result sets as before (unchanged), PLUS two new ones at the end:
--   RS12: the PR's full approval STAGE CHAIN (stage_no, stage_name,
--         approver_ecno, approver_name, is_mandatory, required_approvals),
--         resolved from workflow_stage.stage_order_json — generic for any
--         number of stages, any approvers.
--   RS13: the full ORDERED pr_history_data audit trail, with approver name
--         and status included (the existing vw_PR_Basic_Info JSON omits
--         both) — lets the frontend match each stage to what actually
--         happened at it.
CREATE OR ALTER   PROCEDURE dbo.sp_nt_GetPRTrackingTimeline
    @pr_no VARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @base_pr_no VARCHAR(20) =
        LEFT(@pr_no, CASE WHEN CHARINDEX('/', @pr_no) > 0 THEN CHARINDEX('/', @pr_no) - 1 ELSE LEN(@pr_no) END);

    DECLARE @pr_basic_sno INT, @workflow_types_id INT;
    SELECT @pr_basic_sno = pr_basic_sno, @workflow_types_id = workflow_types_id
    FROM dbo.pr_basic_info
    WHERE pr_no = @base_pr_no AND is_active = 'Y';

    IF @pr_basic_sno IS NULL
    BEGIN
        SELECT CAST(NULL AS INT) AS pr_basic_sno WHERE 1 = 0;
        RETURN;
    END

    DECLARE @poIds TABLE (po_basic_sno INT PRIMARY KEY);
    INSERT INTO @poIds (po_basic_sno)
    SELECT po_basic_sno FROM dbo.po_request_info WHERE pr_basic_sno = @pr_basic_sno;

    -- RS1: PR header
    SELECT * FROM dbo.vw_PR_Basic_Info WHERE pr_basic_sno = @pr_basic_sno;

    -- RS2: Purchase Quotation header rows
    SELECT * FROM dbo.supplier_quotation_info
    WHERE pr_basic_sno = @pr_basic_sno
    ORDER BY created_date, sq_basic_sno;

    -- RS3: Purchase Quotation history/audit trail
    SELECT sqh.*
    FROM dbo.supplier_quotation_history sqh
    WHERE sqh.pr_basic_sno = @pr_basic_sno
    ORDER BY sqh.sq_history_sno;

    -- RS4: PO header rows
    SELECT * FROM dbo.po_request_info
    WHERE pr_basic_sno = @pr_basic_sno
    ORDER BY po_date, po_basic_sno;

    -- RS5: PO history/audit trail
    SELECT phd.*
    FROM dbo.po_history_data phd
    WHERE phd.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    ORDER BY phd.po_history_sno;

    -- RS6: Supplier dispatch slips
    SELECT ds.*
    FROM dbo.nt_dispatch_slip ds
    WHERE ds.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    ORDER BY ds.created_at;

    -- RS7: Dispatch delivery lines
    SELECT dd.*
    FROM dbo.nt_dispatch_slip_delivery dd
    WHERE dd.dispatch_slip_sno IN (
        SELECT dispatch_slip_sno FROM dbo.nt_dispatch_slip
        WHERE po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    )
    ORDER BY dd.created_at;

    -- RS8: Gate Entry
    SELECT ge.*
    FROM dbo.nt_gate_entry ge
    WHERE ge.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    ORDER BY ge.created_at;

    -- RS9: GRN header rows
    SELECT g.*
    FROM dbo.grn_basic_info g
    WHERE g.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    ORDER BY g.created_date;

    -- RS10: GRN history/audit trail
    SELECT gh.*
    FROM dbo.grn_history_data gh
    WHERE gh.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
    ORDER BY gh.status_at;

    -- RS11: Inventory movements
    SELECT sm.*
    FROM dbo.nt_stock_movements sm
    WHERE sm.reference_no IN (
        SELECT 'GRN-' + CAST(YEAR(g.created_date) AS VARCHAR(4)) + '-'
                + RIGHT('000000' + CAST(g.grn_no AS VARCHAR(6)), 6)
        FROM dbo.grn_basic_info g
        WHERE g.po_basic_sno IN (SELECT po_basic_sno FROM @poIds)
          AND g.grn_no IS NOT NULL
    )
    ORDER BY sm.created_at;

    -- RS12: Full PR approval stage chain, in order, with resolved names.
    SELECT
        CAST(s.[key] AS INT) + 1                AS stage_no,
        JSON_VALUE(s.value, '$.stage')           AS stage_name,
        JSON_VALUE(s.value, '$.approver_ecno')   AS approver_ecno,
        vve.ename                                AS approver_name,
        JSON_VALUE(s.value, '$.is_mandatory')    AS is_mandatory,
        JSON_VALUE(s.value, '$.required_approvals') AS required_approvals
    FROM dbo.workflow_stage ws
    CROSS APPLY OPENJSON(ws.stage_order_json) AS s
    LEFT JOIN dbo.vw_verified_employees vve
        ON vve.ecno = JSON_VALUE(s.value, '$.approver_ecno')
    WHERE ws.workflow_types_id = @workflow_types_id
      AND ws.is_active = 'Y'
    ORDER BY stage_no;

    -- RS13: Full ordered pr_history_data audit trail, with approver name and
    -- status included (the existing vw_PR_Basic_Info JSON has neither).
    SELECT
        phd.pr_history_sno,
        phd.approver_ecno,
        phd.status_by,
        vve.ename AS status_by_name,
        phd.status,
        phd.status_date,
        phd.commends
    FROM dbo.pr_history_data phd
    LEFT JOIN dbo.vw_verified_employees vve ON vve.ecno = phd.status_by
    WHERE phd.pr_basic_sno = @pr_basic_sno
    ORDER BY phd.pr_history_sno;
END;
GO
-- ============================================================
-- PR Tracking — surface approver NAMES and the full multi-stage chain
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Follow-up to sql/29_pr_tracking.sql, based on user feedback after the
-- first live walkthrough: the "PR Approval" stage only showed a generic
-- "Pending" status with no indication of WHO it's pending with, and no view
-- of the full approval chain (e.g. "Stage 1: KTM1148 -> Stage 2: KTM1006").
--
-- All 4 objects touched here are ones this feature itself created in file
-- 29 (not pre-existing/UAT procedures) — CREATE OR ALTER is safe, same as
-- every other proc in that file.
--
-- Root cause: the existing (pre-dates this feature, NOT touched)
-- vw_PR_Basic_Info.pr_history_data subquery omits status/approver_ecno/
-- ordering — it only has {status_by, ename, status_date, commends,
-- pr_edit_data}, no way to tell approve vs reject or which stage. Rather
-- than alter that view (also read by sp_get_pr_details_for_approval, which
-- UAT is actively using), this adds two new result sets to
-- sp_nt_GetPRTrackingTimeline that resolve the full stage chain (from
-- workflow_stage.stage_order_json) and the full ordered history (straight
-- from pr_history_data, not the view) independently.
-- ============================================================

-- ── 1. sp_nt_GetMyPRTracking — add current_approver_name ───────────────────
CREATE OR ALTER     PROCEDURE dbo.sp_nt_GetMyPRTracking
    @ecno VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        pbf.pr_basic_sno,
        pbf.pr_no,
        pbf.status                 AS pr_status,
        pbf.purpose,
        pbf.required_date,
        pbf.created_date,
        vadr.com_name, vadr.div_name, vadr.brn_name, vadr.dept_name,
        pbf.current_approver_id,
        vve_approver.ename         AS current_approver_name,
        sq.sq_basic_sno,
        sq.status                  AS quotation_status,
        po.po_basic_sno,
        po.status                  AS po_status,
        po.supplier_ack_status,
        po.po_pdf_url,
        ds.dispatch_slip_sno,
        ge.gate_entry_sno,
        ge.status                  AS gate_entry_status,
        grn.grn_basic_sno,
        grn.status                 AS grn_status,
        CASE
            WHEN grn.grn_basic_sno IS NOT NULL AND grn.status IN ('Received', 'Partial') THEN 'Received Stock'
            WHEN grn.grn_basic_sno IS NOT NULL                                            THEN 'GRN'
            WHEN ge.gate_entry_sno IS NOT NULL                                             THEN 'Gate Entry'
            WHEN ds.dispatch_slip_sno IS NOT NULL                                          THEN 'Dispatched'
            WHEN po.po_basic_sno IS NOT NULL AND po.status = 'A'                           THEN 'PO Sent / In Transit'
            WHEN po.po_basic_sno IS NOT NULL                                               THEN 'PO Approval'
            WHEN sq.sq_basic_sno IS NOT NULL                                               THEN 'Purchase Quotation'
            WHEN pbf.status = 'A'                                                          THEN 'PR Approved — Awaiting Quotation/PO'
            WHEN pbf.status = 'R'                                                          THEN 'PR Rejected'
            ELSE 'PR Approval Pending'
        END AS current_stage
    FROM dbo.pr_basic_info pbf
    INNER JOIN dbo.vw_ActiveDeptRecords vadr
        ON pbf.brn_sno = vadr.brn_sno AND pbf.dept_sno = vadr.dept_sno
    LEFT JOIN dbo.vw_verified_employees vve_approver
        ON vve_approver.ecno = pbf.current_approver_id
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.supplier_quotation_info
        WHERE pr_basic_sno = pbf.pr_basic_sno ORDER BY sq_basic_sno DESC
    ) sq
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.po_request_info
        WHERE pr_basic_sno = pbf.pr_basic_sno ORDER BY po_basic_sno DESC
    ) po
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.nt_dispatch_slip
        WHERE po_basic_sno = po.po_basic_sno ORDER BY dispatch_slip_sno DESC
    ) ds
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.nt_gate_entry
        WHERE po_basic_sno = po.po_basic_sno ORDER BY gate_entry_sno DESC
    ) ge
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.grn_basic_info
        WHERE po_basic_sno = po.po_basic_sno ORDER BY grn_basic_sno DESC
    ) grn
    WHERE pbf.created_by = @ecno AND pbf.is_active = 'Y'
    ORDER BY pbf.created_date DESC, pbf.pr_basic_sno DESC;
END;
GO
-- ── 2. sp_nt_GetOrgPRTracking — add current_approver_name ──────────────────
CREATE OR ALTER   PROCEDURE dbo.sp_nt_GetOrgPRTracking
    @com_sno  INT,
    @div_sno  INT = NULL,
    @brn_sno  INT = NULL,
    @dept_sno INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH PRList AS (
        SELECT
            pbf.pr_basic_sno,
            pbf.pr_no,
            pbf.status                 AS pr_status,
            pbf.purpose,
            pbf.required_date,
            pbf.created_date,
            pbf.created_by,
            vve.ename                  AS created_by_name,
            pbf.current_approver_id,
            vve_approver.ename         AS current_approver_name,
            vadr.com_name, vadr.div_name, vadr.brn_name, vadr.dept_name,
            sq.sq_basic_sno,
            sq.status                  AS quotation_status,
            po.po_basic_sno,
            po.status                  AS po_status,
            po.supplier_ack_status,
            ds.dispatch_slip_sno,
            ge.gate_entry_sno,
            ge.status                  AS gate_entry_status,
            grn.grn_basic_sno,
            grn.status                 AS grn_status,
            CASE
                WHEN grn.grn_basic_sno IS NOT NULL AND grn.status IN ('Received', 'Partial') THEN 'Received Stock'
                WHEN grn.grn_basic_sno IS NOT NULL                                            THEN 'GRN'
                WHEN ge.gate_entry_sno IS NOT NULL                                             THEN 'Gate Entry'
                WHEN ds.dispatch_slip_sno IS NOT NULL                                          THEN 'Dispatched'
                WHEN po.po_basic_sno IS NOT NULL AND po.status = 'A'                           THEN 'PO Sent / In Transit'
                WHEN po.po_basic_sno IS NOT NULL                                               THEN 'PO Approval'
                WHEN sq.sq_basic_sno IS NOT NULL                                               THEN 'Purchase Quotation'
                WHEN pbf.status = 'A'                                                          THEN 'PR Approved — Awaiting Quotation/PO'
                WHEN pbf.status = 'R'                                                          THEN 'PR Rejected'
                ELSE 'PR Approval Pending'
            END AS current_stage
        FROM dbo.pr_basic_info pbf
        INNER JOIN dbo.vw_ActiveDeptRecords vadr
            ON pbf.brn_sno = vadr.brn_sno AND pbf.dept_sno = vadr.dept_sno
        INNER JOIN dbo.vw_verified_employees vve
            ON pbf.created_by = vve.ecno
        LEFT JOIN dbo.vw_verified_employees vve_approver
            ON vve_approver.ecno = pbf.current_approver_id
        OUTER APPLY (
            SELECT TOP 1 * FROM dbo.supplier_quotation_info
            WHERE pr_basic_sno = pbf.pr_basic_sno ORDER BY sq_basic_sno DESC
        ) sq
        OUTER APPLY (
            SELECT TOP 1 * FROM dbo.po_request_info
            WHERE pr_basic_sno = pbf.pr_basic_sno ORDER BY po_basic_sno DESC
        ) po
        OUTER APPLY (
            SELECT TOP 1 * FROM dbo.nt_dispatch_slip
            WHERE po_basic_sno = po.po_basic_sno ORDER BY dispatch_slip_sno DESC
        ) ds
        OUTER APPLY (
            SELECT TOP 1 * FROM dbo.nt_gate_entry
            WHERE po_basic_sno = po.po_basic_sno ORDER BY gate_entry_sno DESC
        ) ge
        OUTER APPLY (
            SELECT TOP 1 * FROM dbo.grn_basic_info
            WHERE po_basic_sno = po.po_basic_sno ORDER BY grn_basic_sno DESC
        ) grn
        WHERE pbf.is_active = 'Y'
          AND pbf.com_sno  = @com_sno
          AND (@div_sno  IS NULL OR pbf.div_sno  = @div_sno)
          AND (@brn_sno  IS NULL OR pbf.brn_sno  = @brn_sno)
          AND (@dept_sno IS NULL OR pbf.dept_sno = @dept_sno)
    )
    SELECT * FROM PRList
    WHERE current_stage NOT IN ('Received Stock', 'PR Rejected')
    ORDER BY created_date DESC, pr_basic_sno DESC;
END;
GO
CREATE OR ALTER   PROCEDURE [dbo].[usp_InsertPurchaseRequest]
    @jsonInput NVARCHAR(MAX),
    @pr_no     VARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @com_sno            INT,
                @div_sno            INT,
                @brn_sno            INT,
                @dept_sno           INT,
                @reg_date           DATE,
                @required_date      DATE,
                @priority_sno       INT,
                @purpose            NVARCHAR(500),
                @current_year       VARCHAR(10),
                @pr_prefix          VARCHAR(20),
                @sequence_number    INT,
                @pr_basic_sno       INT,
                @created_by         VARCHAR(20),
                @workflow_types_id  INT,
                @first_approver     VARCHAR(20),
                @workflow_id        INT,
                @items_inserted     INT,
                @requisition_type   VARCHAR(30),
                @category           VARCHAR(20),
                @source_invoice_sno INT;

        SET @current_year = dbo.fn_GetFinancialYear(GETDATE());
        SET @pr_prefix    = 'PR' + @current_year ;

        SELECT @sequence_number = ISNULL(MAX(
            CASE
                WHEN pr_no LIKE @pr_prefix + '%'
                THEN TRY_CAST(
                         SUBSTRING(pr_no, LEN(@pr_prefix) + 1, LEN(pr_no))
                     AS INT)
                ELSE 0
            END
        ), 0) + 1
        FROM [Non_Trade].[dbo].[pr_basic_info] WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE @pr_prefix + '%';

        SET @pr_no = @pr_prefix + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);

        SELECT
            @com_sno            = JSON_VALUE(@jsonInput, '$.basicInfo.com_sno'),
            @div_sno            = JSON_VALUE(@jsonInput, '$.basicInfo.div_sno'),
            @brn_sno            = JSON_VALUE(@jsonInput, '$.basicInfo.brn_sno'),
            @dept_sno           = JSON_VALUE(@jsonInput, '$.basicInfo.dept_sno'),
            @reg_date           = JSON_VALUE(@jsonInput, '$.basicInfo.req_date'),
            @required_date      = JSON_VALUE(@jsonInput, '$.basicInfo.required_date'),
            @priority_sno       = JSON_VALUE(@jsonInput, '$.basicInfo.priority_sno'),
            @purpose            = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.purpose'), ''),
            @requisition_type   = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.requisition_type'), ''),
            @source_invoice_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.source_invoice_sno') AS INT),
            @created_by = ISNULL(NULLIF(JSON_VALUE(@jsonInput, '$.ecno'), ''), 'KTM1148')
        SET @category = CASE @requisition_type
            WHEN 'civil_works'     THEN 'CIVIL'
            WHEN 'electrical_works' THEN 'ELECTRICAL'
            WHEN 'transportation'  THEN 'TRANSPORTATION'
            WHEN 'routine'         THEN 'ROUTINE'
            ELSE NULL
        END;

        IF @com_sno IS NULL
            THROW 50010, 'Company (com_sno) is required.', 1;

        IF @div_sno IS NULL
            THROW 50011, 'Division (div_sno) is required.', 1;

        IF @brn_sno IS NULL
            THROW 50001, 'Branch (brn_sno) is required.', 1;

        IF @reg_date IS NULL
            THROW 50002, 'Request date (req_date) is required.', 1;

        IF @required_date IS NULL
            THROW 50003, 'Required date is required.', 1;

        --IF @created_by IS NULL
        --    THROW 50004, 'Created by is required.', 1;

        -- Validate items array has at least one valid PRODUCT line
        -- (prod_sno + unit_sno). Service lines removed along with the
        -- Service Agreement feature.
        IF NOT EXISTS (
            SELECT 1
            FROM OPENJSON(@jsonInput, '$.items')
            WHERE JSON_VALUE(value, '$.prod_sno') IS NOT NULL
              AND JSON_VALUE(value, '$.prod_sno') != ''
              AND JSON_VALUE(value, '$.unit_sno')  IS NOT NULL
              AND JSON_VALUE(value, '$.unit_sno')  != ''
        )
            THROW 50005, 'At least one valid item (prod_sno+unit_sno) is required.', 1;

      SELECT
    @workflow_id       = wt.workflow_id,
    @workflow_types_id = wt.workflow_types_id
FROM workflow_types wt
INNER JOIN approval_workflow_master awm
    ON awm.workflow_id = wt.workflow_id
WHERE wt.brn_sno  = @brn_sno
  AND wt.dept_sno = @dept_sno
  AND wt.com_sno  = @com_sno
  AND wt.div_sno  = @div_sno
  AND awm.entity_type  = 'PurchaseRequisition';
        SELECT @workflow_types_id = workflow_types_id
        FROM workflow_types
       WHERE brn_sno  = @brn_sno
          AND dept_sno = @dept_sno
          AND com_sno=@com_sno
          AND div_sno=@div_sno
          AND workflow_id=@workflow_id;

        IF @workflow_types_id IS NULL
            THROW 50006, 'No workflow configuration found for this branch and department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key]  = '0'
          AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 50007, 'No approver found for the first stage of the workflow.', 1;

        INSERT INTO [Non_Trade].[dbo].[pr_basic_info]
        (
            [pr_no],               [com_sno],            [div_sno],
            [brn_sno],             [dept_sno],           [reg_date],
            [required_date],       [priority_sno],       [purpose],
            [is_active],           [created_by],         [created_date],
            [workflow_types_id],   [current_approver_id],[status],
            [category],            [source_invoice_sno]
        )
        VALUES
        (
            @pr_no,                @com_sno,             @div_sno,
            @brn_sno,              @dept_sno,            @reg_date,
            @required_date,        @priority_sno,        @purpose,
            'Y',                   @created_by,          GETDATE(),
            @workflow_types_id,    @first_approver,      'P',
            @category,             @source_invoice_sno
        );

        SET @pr_basic_sno = SCOPE_IDENTITY();

        -- ── Insert PR Item Details (product lines only — service_sno/
        -- agreement_sno no longer populated; those columns remain on the
        -- table but are permanently NULL for new rows going forward) ──────
        INSERT INTO [Non_Trade].[dbo].[pr_item_details]
        (
            [pr_no],        [pr_basic_sno],  [prod_sno],
            [qty],          [unit],          [est_cost],
            [total_cost],   [remarks],       [specification],
            [pr_prod_file], [item_type],
            [is_active],
            [created_by],   [created_date]
        )
        SELECT
            @pr_no,
            @pr_basic_sno,
            NULLIF(JSON_VALUE(value, '$.prod_sno'), ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.qty'), ''), '0'),
            NULLIF(JSON_VALUE(value, '$.unit_sno'), ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.est_cost'), ''), 0),
            ISNULL(NULLIF(JSON_VALUE(value, '$.total_cost'), ''), 0),
            ISNULL(NULLIF(JSON_VALUE(value, '$.remarks'),        ''), ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.service_desc'),   ''), ''),
            NULLIF(JSON_VALUE(value, '$.item_attachment'),       ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.item_type'),      ''), 'product'),
            'Y',
            @created_by,
            GETDATE()
        FROM OPENJSON(@jsonInput, '$.items')
        WHERE JSON_VALUE(value, '$.prod_sno') IS NOT NULL
          AND JSON_VALUE(value, '$.prod_sno') != ''
          AND JSON_VALUE(value, '$.unit_sno')  IS NOT NULL
          AND JSON_VALUE(value, '$.unit_sno')  != '';

        SET @items_inserted = @@ROWCOUNT;

        IF @items_inserted = 0
            THROW 50008, 'No items were inserted. Check that items array is valid and non-empty.', 1;

        COMMIT TRANSACTION;

        SELECT
            'PR Data Saved Successfully. PR No: ' + @pr_no AS Message,
            'Success'                                       AS Status,
            @items_inserted                                 AS ItemsInserted;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT    = ERROR_SEVERITY();
        DECLARE @ErrorState    INT            = ERROR_STATE();

        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END;
GO
CREATE OR ALTER   PROCEDURE dbo.sp_nt_SaveServiceAgreementSuppliers
    @agreement_sno INT,
    @vendors_json NVARCHAR(MAX),
    @fallback_vendor_sno INT,
    @total_amount DECIMAL(18,2),
    @out_primary_vendor_sno INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @parsed TABLE (ord INT NOT NULL, vendor_sno INT NULL, share_amount DECIMAL(18,2) NULL);

    IF @vendors_json IS NOT NULL AND ISJSON(@vendors_json) = 1 AND LEFT(LTRIM(@vendors_json), 1) = '['
        INSERT INTO @parsed (ord, vendor_sno, share_amount)
        SELECT CAST(j.[key] AS INT) + 1,
               TRY_CAST(JSON_VALUE(j.[value], '$.vendor_sno') AS INT),
               TRY_CAST(JSON_VALUE(j.[value], '$.share_amount') AS DECIMAL(18,2))
        FROM OPENJSON(@vendors_json) AS j;

    IF NOT EXISTS (SELECT 1 FROM @parsed) AND @fallback_vendor_sno IS NOT NULL
        INSERT INTO @parsed (ord, vendor_sno, share_amount) VALUES (1, @fallback_vendor_sno, @total_amount);

    IF NOT EXISTS (SELECT 1 FROM @parsed)
        THROW 58150, 'At least one supplier is required.', 1;
    IF EXISTS (SELECT 1 FROM @parsed WHERE vendor_sno IS NULL OR share_amount IS NULL OR share_amount <= 0)
        THROW 58151, 'Every supplier needs a vendor and a share amount greater than zero.', 1;
    IF EXISTS (SELECT vendor_sno FROM @parsed GROUP BY vendor_sno HAVING COUNT(*) > 1)
        THROW 58152, 'The same supplier is listed more than once in the split.', 1;
    IF EXISTS (
        SELECT 1 FROM @parsed p
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.kyc_basic_info k
            WHERE k.kyc_basic_info_sno = p.vendor_sno AND k.status = 'A' AND k.is_active = 'Y'
        )
    )
        THROW 58153, 'One or more suppliers are not approved, active vendors.', 1;

    DECLARE @sum DECIMAL(18,2) = (SELECT SUM(share_amount) FROM @parsed);
    IF ABS(@sum - @total_amount) > 0.01
    BEGIN
        DECLARE @msg NVARCHAR(400) =
            N'Supplier shares total ' + CONVERT(NVARCHAR(30), @sum) +
            N' but the amount per cycle (rate x quantity) is ' + CONVERT(NVARCHAR(30), @total_amount) +
            N'. The shares must add up exactly.';
        THROW 58154, @msg, 1;
    END

    DELETE FROM dbo.service_agreement_vendor WHERE agreement_sno = @agreement_sno;

    INSERT INTO dbo.service_agreement_vendor (agreement_sno, vendor_sno, share_amount, share_pct, sort_order)
    SELECT @agreement_sno, vendor_sno, share_amount, ROUND(share_amount * 100.0 / @total_amount, 6), ord
    FROM @parsed
    ORDER BY ord;

    SELECT TOP 1 @out_primary_vendor_sno = vendor_sno FROM @parsed ORDER BY ord;
END;
GO
CREATE OR ALTER   PROCEDURE dbo.sp_nt_ApproveSupplierQuotation
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        ------------------------------------------------------------------
        -- 1. Validate input
        ------------------------------------------------------------------
        IF ISJSON(@jsonInput) = 0
        BEGIN
            RAISERROR('Invalid JSON format for @jsonInput', 16, 1);
            RETURN;
        END

        DECLARE @sq_basic_sno    INT            = TRY_CAST(JSON_VALUE(@jsonInput, '$.sq_basic_sno') AS INT),
                @pr_no           VARCHAR(30)    = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.pr_no'))), ''),
                @comments        VARCHAR(1000)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages NVARCHAR(MAX)  = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by     VARCHAR(30)    = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.approved_by'))), ''),
                @transfer_to     VARCHAR(30)    = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.transfer_to_ecno'))), ''),
                @action          VARCHAR(30)    = LOWER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.action'))));

        IF @sq_basic_sno IS NULL
        BEGIN
            RAISERROR('sq_basic_sno is required.', 16, 1);
            RETURN;
        END

        IF @action IS NULL OR @action NOT IN ('approve', 'reject', 'forward', 'backward')
        BEGIN
            RAISERROR('Invalid action. Use approve | reject | forward | backward.', 16, 1);
            RETURN;
        END

        IF @approved_by IS NULL
        BEGIN
            RAISERROR('approved_by (approver EC number) is required.', 16, 1);
            RETURN;
        END

        IF @action IN ('forward', 'backward')
           AND @transfer_to IS NULL
        BEGIN
            RAISERROR('transfer_to_ecno is required for forward/backward.', 16, 1);
            RETURN;
        END

        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
        BEGIN
            RAISERROR('Invalid or missing approval_stages.', 16, 1);
            RETURN;
        END

        ------------------------------------------------------------------
        -- 2. Load quotation header
        ------------------------------------------------------------------
        DECLARE @pr_basic_sno      INT,
                @vendor_sno        INT,
                @com_sno           INT,
                @div_sno           INT,
                @brn_sno           INT,
                @dept_sno          INT,
                @workflow_types_id INT,
                @cur_transfer_from VARCHAR(30),
                @sq_pr_no          VARCHAR(30);

        SELECT
            @pr_basic_sno      = sq.pr_basic_sno,
            @vendor_sno        = sq.vendor_sno,
            @com_sno           = pr.com_sno,
            @div_sno           = pr.div_sno,
            @brn_sno           = sq.brn_sno,
            @dept_sno          = sq.dept_sno,
            @workflow_types_id = sq.workflow_types_id,
            @cur_transfer_from = sq.transferred_from,
            @sq_pr_no          = sq.pr_no
        FROM supplier_quotation_info sq
        INNER JOIN pr_basic_info pr ON pr.pr_basic_sno = sq.pr_basic_sno
        WHERE sq.sq_basic_sno = @sq_basic_sno
          AND sq.is_active = 1;

        IF @pr_basic_sno IS NULL
        BEGIN
            RAISERROR('Invalid sq_basic_sno or inactive quotation.', 16, 1);
            RETURN;
        END

        IF @pr_no IS NULL
    SET @pr_no = @sq_pr_no;

        ------------------------------------------------------------------
        -- 3. Materialize approval stages into temp table
        ------------------------------------------------------------------
        CREATE TABLE #approval_stages (
            seq_no             INT,
            approver_ecno      VARCHAR(30),
          stage              VARCHAR(100),
            required_approvals VARCHAR(10),
            is_mandatory       CHAR(1),
            escalation_hours   VARCHAR(10),
            approver_condition VARCHAR(200),
            next_approver_ecno VARCHAR(30),
            can_forward        CHAR(1),
            can_backward       CHAR(1),
            can_edit_data      CHAR(1)
        );

        INSERT INTO #approval_stages (
            seq_no, approver_ecno, stage, required_approvals, is_mandatory,
            escalation_hours, approver_condition, next_approver_ecno,
            can_forward, can_backward, can_edit_data
        )
        SELECT
            CAST(oj.[key] AS INT),
            JSON_VALUE(oj.[value], '$.approver_ecno'),
            JSON_VALUE(oj.[value], '$.stage'),
            JSON_VALUE(oj.[value], '$.required_approvals'),
            JSON_VALUE(oj.[value], '$.is_mandatory'),
            JSON_VALUE(oj.[value], '$.escalation_hours'),
            JSON_VALUE(oj.[value], '$.approver_condition'),
            JSON_VALUE(oj.[value], '$.next_approver_ecno'),
            JSON_VALUE(oj.[value], '$.can_forward'),
            JSON_VALUE(oj.[value], '$.can_backward'),
            JSON_VALUE(oj.[value], '$.can_edit_data')
        FROM OPENJSON(@approval_stages) AS oj;

        DECLARE @stage_ecno VARCHAR(30) =
            CASE
                WHEN EXISTS (SELECT 1 FROM #approval_stages WHERE approver_ecno = @approved_by)
                    THEN @approved_by
                ELSE @cur_transfer_from
            END;

        IF @action IN ('approve', 'forward', 'backward')
           AND NOT EXISTS (SELECT 1 FROM #approval_stages WHERE approver_ecno = @stage_ecno)
        BEGIN
            RAISERROR('Current approver is not part of the approval workflow.', 16, 1);
            RETURN;
        END

        BEGIN TRANSACTION;

        ------------------------------------------------------------------
        -- 4A. REJECT
        -- Reject process for all quotations under same PR
        ------------------------------------------------------------------
        IF @action = 'reject'
        BEGIN
            INSERT INTO supplier_quotation_history (
                sq_basic_sno, sq_edit_data, is_active, workflow_types_id,
                approver_ecno, status, status_by, transferred_from,
                transferred_to, comment, action_type, pr_basic_sno,
                selected_by, pr_no
            )
            SELECT
                sq.sq_basic_sno, NULL, 1, sq.workflow_types_id,
                @approved_by, 'R', @approved_by, sq.transferred_from,
                sq.transferred_to, @comments, 'REJECTED', sq.pr_basic_sno,
                NULL, sq.pr_no
            FROM supplier_quotation_info sq
            WHERE sq.pr_no = @pr_no
              AND sq.is_active = 1;

            UPDATE supplier_quotation_info
            SET status           = 'R',
                approver_ecno    = NULL,
                transferred_from = NULL,
                transferred_to   = NULL,
                modifed_by       = @approved_by,
                modifed_date     = GETDATE()
            WHERE pr_no = @pr_no
              AND is_active = 1;

            COMMIT TRANSACTION;
            DROP TABLE #approval_stages;

            SELECT 'REJECTED'    AS result,
                   @sq_basic_sno AS sq_basic_sno,
                   @pr_no        AS pr_no,
                   @approved_by  AS rejected_by,
                   GETDATE()     AS rejected_on,
                   @comments     AS rejection_reason;
            RETURN;
        END

        ------------------------------------------------------------------
        -- 4B. FORWARD / BACKWARD
        -- Update workflow columns for all quotations under same PR
        -- Keep status as process flag only; do not touch is_selected
        ------------------------------------------------------------------
      IF @action IN ('forward', 'backward')
        BEGIN
            DECLARE @can CHAR(1);

            SELECT @can =
                CASE
                    WHEN @action = 'forward' THEN can_forward
                    ELSE can_backward
                END
            FROM #approval_stages
            WHERE approver_ecno = @stage_ecno;

            IF ISNULL(@can, 'N') <> 'Y'
            BEGIN
                ROLLBACK TRANSACTION;
                DROP TABLE #approval_stages;
                RAISERROR('Current approver is not allowed to %s.', 16, 1, @action);
                RETURN;
            END

            INSERT INTO supplier_quotation_history (
                sq_basic_sno, sq_edit_data, is_active, workflow_types_id,
                approver_ecno, status, status_by, transferred_from,
                transferred_to, comment, action_type, pr_basic_sno,
                selected_by, pr_no
            )
            SELECT
                sq.sq_basic_sno, NULL, 1, sq.workflow_types_id,
                @transfer_to, sq.status, @approved_by, @approved_by,
                @transfer_to, @comments, UPPER(@action), sq.pr_basic_sno,
                sq.is_selected, sq.pr_no
            FROM supplier_quotation_info sq
            WHERE sq.pr_no = @pr_no
              AND sq.is_active = 1;

            UPDATE supplier_quotation_info
            SET approver_ecno    = @transfer_to,
                transferred_from = @approved_by,
                transferred_to   = @transfer_to,
                modifed_by       = @approved_by,
                modifed_date     = GETDATE()
            WHERE pr_no = @pr_no
              AND is_active = 1;

            COMMIT TRANSACTION;
            DROP TABLE #approval_stages;

            SELECT UPPER(@action) AS result,
                   @sq_basic_sno  AS sq_basic_sno,
                   @pr_no         AS pr_no,
                   @approved_by   AS transferred_from,
                   @transfer_to   AS transferred_to,
                   GETDATE()      AS transferred_on;
            RETURN;
        END

        ------------------------------------------------------------------
        -- 4C. APPROVE — resolve next stage
        -- Update workflow columns for all quotations under same PR
        -- Keep final status/is_selected only for chosen quotation at final stage
        ------------------------------------------------------------------
        DECLARE @next_approver  VARCHAR(30),
                @next_condition VARCHAR(200);

        ;WITH stage_cte AS
        (
            SELECT
                seq_no,
                approver_ecno,
                LEAD(approver_ecno) OVER (ORDER BY seq_no) AS next_ecno
            FROM #approval_stages
        )
        SELECT
            @next_approver  = s2.approver_ecno,
            @next_condition = s2.approver_condition
        FROM stage_cte s1
        LEFT JOIN #approval_stages s2
               ON s2.approver_ecno = s1.next_ecno
        WHERE s1.approver_ecno = @stage_ecno;

        INSERT INTO supplier_quotation_history (
            sq_basic_sno, sq_edit_data, is_active, workflow_types_id,
            approver_ecno, status, status_by, transferred_from,
            transferred_to, comment, action_type, pr_basic_sno,
            selected_by, pr_no
        )
        VALUES (
            @sq_basic_sno, NULL, 1, @workflow_types_id,
            @approved_by,
            CASE WHEN @next_approver IS NULL THEN 'A' ELSE 'P' END,
            @approved_by, NULL,
            NULL,
            @comments,
            CASE WHEN @next_approver IS NULL THEN 'FINAL_APPROVED' ELSE 'APPROVED' END,
            @pr_basic_sno,
            CASE WHEN @next_approver IS NULL THEN @approved_by ELSE NULL END,
            @pr_no
        );

        ------------------------------------------------------------------
        -- Intermediate approval: move all quotations in same PR
    -- to next approver, but do not finalize selection/status
        ------------------------------------------------------------------
        IF @next_approver IS NOT NULL
        BEGIN
            UPDATE supplier_quotation_info
            SET approver_ecno    = @next_approver,
                transferred_from = NULL,
                transferred_to   = NULL,
                modifed_by       = @approved_by,
                modifed_date     = GETDATE()
            WHERE pr_no = @pr_no
              AND is_active = 1;

            COMMIT TRANSACTION;
            DROP TABLE #approval_stages;

            SELECT 'APPROVED'      AS result,
                   @sq_basic_sno   AS sq_basic_sno,
                   @pr_no          AS pr_no,
                   @approved_by    AS approved_by,
                   GETDATE()       AS approved_on,
                   @next_approver  AS next_approver,
                   @next_condition AS next_condition,
                   'N'             AS is_final;
            RETURN;
        END

        --================================================================
        -- 5. FINAL STAGE → selected quotation only gets approved/selected
        -- other quotations only workflow columns reset; status/is_selected
        -- remain independent
        --================================================================

        UPDATE supplier_quotation_info
        SET status           = 'A',
            is_selected      = 1,
            approver_ecno    = NULL,
            transferred_from = NULL,
            transferred_to   = NULL,
            modifed_by       = @approved_by,
            modifed_date     = GETDATE()
        WHERE sq_basic_sno = @sq_basic_sno
          AND is_active = 1;

        UPDATE supplier_quotation_info
        SET is_selected      = 0,
            approver_ecno    = NULL,
            transferred_from = NULL,
            transferred_to   = NULL,
            modifed_by       = @approved_by,
            modifed_date     = GETDATE()
        WHERE pr_no = @pr_no
          AND sq_basic_sno <> @sq_basic_sno
          AND is_active = 1;

        ------------------------------------------------------------------
        -- 5a. Insert PO header — OR reuse an existing active PO for the
        -- same (pr_basic_sno, vendor_sno) pair (Part B grouping rule: a
        -- Service PO for this vendor+PR may already exist, e.g. the
        -- Electrical worked example's combined PO). Symmetric to the
        -- merge-check in sp_nt_CreateServicePO.
        ------------------------------------------------------------------
        DECLARE @po_basic_sno INT;
        DECLARE @po_df_no VARCHAR(50);
        DECLARE @is_new_po BIT = 0;

        SELECT @po_basic_sno = po_basic_sno, @po_df_no = po_df_no
        FROM po_request_info
        WHERE pr_basic_sno = @pr_basic_sno
          AND vendor_sno = @vendor_sno
          AND is_active = 'Y';

        IF @po_basic_sno IS NULL
        BEGIN
            SET @is_new_po = 1;

            INSERT INTO po_request_info (
                vendor_sno, brn_sno, dept_sno, com_sno, div_sno,
                pr_basic_sno, po_date,
                terms_conditions,
      is_active, workflow_types_id, status,
                po_df_no,
                split_pr_no
            )
            SELECT
                sq.vendor_sno,
                sq.brn_sno,
                sq.dept_sno,
                pr.com_sno,
                pr.div_sno,
                sq.pr_basic_sno,
                GETDATE(),
                sq.payment_terms,
                'Y',
                sq.workflow_types_id,
                'A',
                NULL,
                @pr_no
            FROM supplier_quotation_info sq
            INNER JOIN pr_basic_info pr ON pr.pr_basic_sno = sq.pr_basic_sno
            WHERE sq.sq_basic_sno = @sq_basic_sno;

            SET @po_basic_sno = SCOPE_IDENTITY();

            ------------------------------------------------------------------
            -- 5b. Generate formatted PO number: com_prefix+div_prefix+brn_prefix+seq
            ------------------------------------------------------------------
            DECLARE @po_prefix VARCHAR(30),
                    @next_seq  INT;

            SELECT @po_prefix = ISNULL(vadr.com_prefix, '')
                              + ISNULL(vadr.div_prefix, '')
                              + ISNULL(vadr.brn_prefix, '')
            FROM vw_ActiveDeptRecords vadr
            WHERE vadr.com_sno  = @com_sno
              AND vadr.div_sno  = @div_sno
              AND vadr.brn_sno  = @brn_sno
              AND vadr.dept_sno = @dept_sno;

            IF @po_prefix IS NULL OR @po_prefix = ''
            BEGIN
                ROLLBACK TRANSACTION;
                DROP TABLE #approval_stages;
                RAISERROR('Unable to resolve PO prefix (company/division/branch).', 16, 1);
                RETURN;
            END

            -- Find last sequence for this prefix; lock to avoid duplicates under concurrency
            SELECT @next_seq = ISNULL(MAX(
                       TRY_CAST(SUBSTRING(po_df_no, LEN(@po_prefix) + 1, 20) AS INT)
                   ), 0) + 1
            FROM po_request_info WITH (UPDLOCK, HOLDLOCK)
            WHERE po_df_no LIKE @po_prefix + '%'
              AND TRY_CAST(SUBSTRING(po_df_no, LEN(@po_prefix) + 1, 20) AS INT) IS NOT NULL;

            SET @po_df_no = @po_prefix + RIGHT('000' + CAST(@next_seq AS VARCHAR(10)), 3);

            UPDATE po_request_info
            SET po_df_no = @po_df_no
            WHERE po_basic_sno = @po_basic_sno;
        END

        ------------------------------------------------------------------
        -- 5c. Insert PO line items (po_section='MATERIAL' — a combined PO
        -- may also carry SERVICE-section lines inserted separately by
        -- sp_nt_CreateServicePO, either before or after this runs)
        ------------------------------------------------------------------
       INSERT INTO po_item_details (
    po_basic_sno, pr_item_sno, prod_sno, specification,
    qty, unit, agreed_unit_price, discount_pct, tax_pct,
    total_cost, net_cost, remarks, po_section,
    created_by, created_date, is_active, split_pr_no
)
SELECT
    @po_basic_sno,
    sid.pr_item_sno,
    sid.prod_sno,
    sid.specification,
    sid.qty,
    sid.unit,
    sid.unit_price,
    sid.discount_pct,
    sid.tax_pct,
    sid.total_amount,              -- total_cost
    calc.net_cost,                 -- net_cost
    sid.remarks,
    'MATERIAL',
    @approved_by,
    GETDATE(),
    1,
    @pr_no
FROM supplier_quotation_items sid
CROSS APPLY (
    SELECT
      ((sid.qty * sid.unit_price - (sid.qty * sid.unit_price * ISNULL(sid.discount_pct,0) / 100.0))
            * ISNULL(sid.tax_pct,0) / 100.0) AS net_cost
) calc
WHERE sid.sq_basic_sno = @sq_basic_sno
  AND sid.is_active = 1;

        ------------------------------------------------------------------
        -- 5d. PO creation history
        ------------------------------------------------------------------
        INSERT INTO supplier_quotation_history (
            sq_basic_sno, sq_edit_data, is_active, workflow_types_id,
            approver_ecno, status, status_by, transferred_from,
            transferred_to, comment, action_type, pr_basic_sno,
            selected_by, pr_no
        )
        VALUES (
            @sq_basic_sno, NULL, 1, @workflow_types_id,
            @approved_by, 'A', @approved_by, NULL,
            NULL,
            'PO ' + @po_df_no + CASE WHEN @is_new_po = 1
                THEN ' auto-generated on final quotation approval'
                ELSE ' — MATERIAL lines appended to the existing PO already shared with this vendor on this PR'
                END,
            'PO_CREATED',
            @pr_basic_sno,
            @approved_by,
            @pr_no
        );

        COMMIT TRANSACTION;
        DROP TABLE #approval_stages;

        ------------------------------------------------------------------
        -- 6. Final response
        ------------------------------------------------------------------
        DECLARE @po_header_json NVARCHAR(MAX),
                @vendor_json    NVARCHAR(MAX),
                @po_items_json  NVARCHAR(MAX),
                @approver_name  NVARCHAR(200);

        SELECT @po_header_json = (
            SELECT
                po.po_basic_sno,
                po.po_df_no,
                po.split_pr_no                              AS po_pr_no,
                CONVERT(VARCHAR(23), po.po_date, 126)       AS po_date,
                po.status                                   AS po_status,
                po.terms_conditions,
                vadr.com_sno,
                vadr.com_name,
                ISNULL(vadr.logo, '')                       AS com_logo,
                vadr.company_address,
                vadr.branch_address,
                vadr.div_sno,
                vadr.div_name,
                vadr.div_prefix,
                vadr.brn_name,
                vadr.brn_prefix,
                vadr.dept_name,
                pr.pr_basic_sno                             AS source_pr_basic_sno,
                pr.pr_no                                    AS source_pr_no,
                CONVERT(VARCHAR(23), pr.reg_date, 126)      AS pr_reg_date,
                CONVERT(VARCHAR(23), pr.required_date, 126) AS pr_required_date,
                pr.purpose                                  AS pr_purpose,
                pr.priority_sno
            FROM po_request_info po
            INNER JOIN vw_ActiveDeptRecords vadr
                ON vadr.brn_sno = po.brn_sno
               AND vadr.dept_sno = po.dept_sno
            INNER JOIN pr_basic_info pr
                ON pr.pr_basic_sno = po.pr_basic_sno
            WHERE po.po_basic_sno = @po_basic_sno
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        SELECT @vendor_json = (
            SELECT
               vgaki.kyc_basic_info_sno AS vendor_sno,
                vgaki.company_name       AS vendor_name,
                vgaki.supp_code          AS vendor_code,
                vgaki.contact_person,
                vgaki.mobile_number      AS vendor_mobile,
                vgaki.email              AS vendor_email,
                vgaki.kyc_address        AS vendor_address,
                vgaki.gst_no,
                vgaki.pan_no,
                vgaki.business_type
            FROM vw_get_all_kyc_info vgaki
            WHERE vgaki.kyc_basic_info_sno = @vendor_sno
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        -- v2: LEFT JOIN product_master/uom_master/pr_item_details (were
        -- INNER — would silently exclude SERVICE-section lines already on a
        -- combined PO, since those rows have prod_sno=NULL) + LEFT JOIN
        -- po_section, so the response shows every line on
        -- the PO, both sections combined.
        SELECT @po_items_json = (
            SELECT
                pid.po_item_sno,
                pid.po_basic_sno,
                @po_df_no                                    AS po_df_no,
                pid.split_pr_no                              AS pr_no,
                pid.pr_item_sno,
                pid.po_section,
                pid.prod_sno,
                pm.prod_name,
                pm.prod_code,
                pm.prod_notes,
                pid.service_sno,
                pid.specification,
                pid.qty,
                pid.unit                                     AS uom_sno,
                uom.uom_name,
                uom.uom_code,
                pid.agreed_unit_price,
                pid.discount_pct,
                pid.tax_pct,
                pid.total_cost,
                pid.net_cost,
                pid.remarks,
                prid.est_cost                                AS pr_est_cost,
                prid.total_cost                              AS pr_total_cost,
                prid.qty                                     AS pr_qty,
                pid.created_by,
                CONVERT(VARCHAR(23), pid.created_date, 126)  AS created_date,
                pid.is_active
            FROM po_item_details pid
            LEFT JOIN product_master pm     ON pm.prod_sno = pid.prod_sno
            LEFT JOIN uom_master uom        ON uom.uom_sno = pid.unit
            LEFT JOIN pr_item_details prid  ON prid.pr_item_sno = pid.pr_item_sno
            WHERE pid.po_basic_sno = @po_basic_sno
              AND pid.is_active = 1
            ORDER BY pid.po_item_sno
            FOR JSON PATH
        );

        SELECT @approver_name = vve.ename
        FROM vw_verified_employees vve
        WHERE vve.ecno = @approved_by;

        IF @approver_name IS NULL
            SELECT @approver_name = nsl.full_name
            FROM dbo.nt_nonstaff_login nsl
            WHERE nsl.login_id = @approved_by;

        SELECT
            'FINAL_APPROVED'                     AS result,
            'Y'                                  AS is_final,
            @sq_basic_sno                        AS sq_basic_sno,
            @pr_no                               AS pr_no,
            @approved_by                         AS final_approved_by,
            @approver_name  AS final_approved_by_name,
            CONVERT(VARCHAR(23), GETDATE(), 126) AS final_approved_on,
            @is_new_po                           AS is_new_po,
            JSON_QUERY(@po_header_json)          AS po_header,
    JSON_QUERY(@vendor_json)             AS vendor,
            JSON_QUERY(@po_items_json)           AS po_items;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL
            DROP TABLE #approval_stages;

        SELECT
            'ERROR'            AS result,
            ERROR_NUMBER()     AS error_number,
            ERROR_MESSAGE()    AS error_message,
            ERROR_LINE()       AS error_line,
            ERROR_PROCEDURE()  AS error_procedure;
    END CATCH
END;
GO
-- One loan's history as JSON columns (parsed by the Node service):
--   rates_json     sanctioned rate + every entered rate, each with its end date
--   txns_json      opening disbursement + every principal movement, with a running balance
--   vouchers_json  the loan's bank payment vouchers, newest first
-- @jsonInput: { agreement_sno }
CREATE OR ALTER   PROCEDURE dbo.sp_nt_GetLoanDetail
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @agreement_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
    IF @agreement_sno IS NULL THROW 58400, 'agreement_sno is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.service_agreement_statutory WHERE agreement_sno = @agreement_sno)
        THROW 58400, 'Loan facility not found for this agreement.', 1;

    DECLARE @locked DATE = dbo.fn_LoanLockedThrough(@agreement_sno);

    SELECT @agreement_sno AS agreement_sno,
           dbo.fn_LoanBilledThrough(@agreement_sno) AS billed_through,
           @locked AS locked_through,
           (
               SELECT r.rate_period_sno, r.effective_from,
                      DATEADD(DAY, -1, LEAD(r.effective_from) OVER (ORDER BY r.effective_from)) AS effective_to,
                      r.benchmark_rate_pct, r.spread_pct, r.interest_rate_pct, r.source, r.remarks, r.created_by, r.created_at,
                      CASE WHEN r.source = 'ENTERED' AND r.effective_from >= @locked THEN 1 ELSE 0 END AS can_delete
               FROM (
                   SELECT CAST(NULL AS INT) AS rate_period_sno, s.disbursement_date AS effective_from, s.benchmark_rate_pct, s.spread_pct,
                          s.interest_rate_pct, 'SANCTIONED' AS source, CAST(N'Rate at sanction' AS NVARCHAR(300)) AS remarks,
                          CAST(NULL AS VARCHAR(30)) AS created_by, CAST(NULL AS DATETIME) AS created_at
                   FROM dbo.service_agreement_statutory s WHERE s.agreement_sno = @agreement_sno
                   UNION ALL
                   SELECT p.rate_period_sno, p.effective_from, p.benchmark_rate_pct, p.spread_pct, p.interest_rate_pct, 'ENTERED',
                          p.remarks, p.created_by, p.created_at
                   FROM dbo.loan_rate_period p WHERE p.agreement_sno = @agreement_sno
               ) r
               ORDER BY r.effective_from
               FOR JSON PATH
           ) AS rates_json,
           (
               SELECT m.txn_sno, m.txn_date, m.txn_type, m.amount, m.voucher_sno, m.remarks, m.created_by, m.source,
                      SUM(CASE m.txn_type WHEN 'DRAWDOWN' THEN m.amount ELSE -m.amount END)
                          OVER (ORDER BY m.txn_date, m.ord, m.txn_sno ROWS UNBOUNDED PRECEDING) AS principal_after,
                      CASE WHEN m.source = 'MANUAL' AND m.txn_date >= @locked THEN 1 ELSE 0 END AS can_delete
               FROM (
                   SELECT CAST(NULL AS INT) AS txn_sno, s.disbursement_date AS txn_date, 'DRAWDOWN' AS txn_type, s.disbursed_amount AS amount,
                          CAST(NULL AS INT) AS voucher_sno, CAST(N'Disbursement' AS NVARCHAR(300)) AS remarks, CAST(NULL AS VARCHAR(30)) AS created_by,
                          'OPENING' AS source, 0 AS ord
                   FROM dbo.service_agreement_statutory s WHERE s.agreement_sno = @agreement_sno AND ISNULL(s.disbursed_amount, 0) > 0
                   UNION ALL
                   SELECT t.txn_sno, t.txn_date, t.txn_type, t.amount, t.voucher_sno, t.remarks, t.created_by,
                          CASE WHEN t.voucher_sno IS NULL THEN 'MANUAL' ELSE 'VOUCHER' END, 1
                   FROM dbo.loan_principal_txn t WHERE t.agreement_sno = @agreement_sno AND t.is_active = 'Y'
               ) m
               ORDER BY m.txn_date, m.ord, m.txn_sno
               FOR JSON PATH
           ) AS txns_json,
           (
               SELECT v.voucher_sno, v.voucher_no, v.period_from, v.period_to, v.days, v.interest_amount, v.principal_repayment,
                      v.total_payable, v.principal_after, v.rate_pct, v.status, v.created_at, v.paid_on
               FROM dbo.bank_payment_voucher v WHERE v.agreement_sno = @agreement_sno
               ORDER BY v.voucher_sno DESC
               FOR JSON PATH
           ) AS vouchers_json;
END;
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateWorkflowMaster
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @workflow_id   INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.workflow_id') AS INT),
            @workflow_name NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.workflow_name'),
            @description   NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.description'),
            @is_active     CHAR(1)       = JSON_VALUE(@jsonInput, '$.is_active'),
            @modified_by   VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.modified_by');

    IF @workflow_id IS NULL
    BEGIN
        THROW 50002, N'workflow_id is required.', 1;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.approval_workflow_master WHERE workflow_id = @workflow_id)
    BEGIN
        THROW 50003, N'Workflow not found.', 1;
        RETURN;
    END;

    -- Snapshot the row as it stands, for the audit column.
    DECLARE @before NVARCHAR(MAX) = (
        SELECT workflow_name, description, is_active
        FROM dbo.approval_workflow_master
        WHERE workflow_id = @workflow_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    UPDATE dbo.approval_workflow_master
    SET workflow_name = ISNULL(@workflow_name, workflow_name),
        description   = ISNULL(@description,   description),
        is_active     = ISNULL(@is_active,     is_active),
        modified_data = @before,
        modified_by   = @modified_by,
        modified_at   = GETDATE()
    WHERE workflow_id = @workflow_id;

    SELECT workflow_id,
           workflow_code,
           workflow_name,
           entity_type,
           description,
           is_active,
           N'SUCCESS' AS status,
           N'Workflow updated successfully.' AS message
    FROM dbo.approval_workflow_master
    WHERE workflow_id = @workflow_id;
END;
GO
-- ── sp_nt_GetQuotationsForApproval — PO approval queue, now hierarchy-scoped ──

CREATE OR ALTER   PROCEDURE dbo.sp_nt_GetQuotationsForApproval
    @Ecno VARCHAR(20),
    @HierarchyJson NVARCHAR(MAX) = NULL
AS
BEGIN TRY
    SET NOCOUNT ON;

    ;WITH pr_groups AS
    (
        SELECT
            pbf.pr_basic_sno,
            pbf.brn_sno,
            vadr.brn_name,
            vadr.brn_prefix,
            vadr.dept_name,
            vadr.div_prefix,
            vadr.div_name,
            vadr.div_sno,
            vadr.com_name,
            vadr.com_sno,
            vadr.company_address,
            vadr.branch_address,
            vve.ename AS pr_created_by_name,
            pbf.dept_sno,
            pbf.reg_date,
            pbf.required_date,
            pbf.priority_sno,
            pbf.purpose,
            pbf.is_active,
            pbf.created_by,
            pbf.created_date,
            pbf.modified_by,
            pbf.modified_date,
            pbf.workflow_types_id AS pr_workflow_types_id,
            pbf.current_approver_id AS pr_current_approver_id,
            pbf.status AS pr_status,
            pbf.pr_no AS base_pr_no,
            g.grp,
            gc.group_count,
            -- ✅ DISPLAY value: suffix /group only when there is more than one bucket
            CASE
                WHEN g.grp IS NOT NULL AND gc.group_count > 1
                    THEN pbf.pr_no + '/' + CAST(g.grp AS VARCHAR(10))
                ELSE pbf.pr_no
            END AS split_pr_no
        FROM pr_basic_info pbf
        INNER JOIN vw_ActiveDeptRecords vadr
            ON pbf.brn_sno = vadr.brn_sno
           AND pbf.dept_sno = vadr.dept_sno
        INNER JOIN vw_verified_employees vve
            ON pbf.created_by = vve.ecno
        OUTER APPLY
        (
            SELECT DISTINCT pid.[group] AS grp
            FROM pr_item_details pid
            WHERE pid.pr_basic_sno = pbf.pr_basic_sno
              AND pid.is_active = 'Y'
        ) g

        OUTER APPLY
        (
            -- ✅ FIX: COUNT(DISTINCT [group]) ignores NULLs, so a PR with
            --        ungrouped items (group = NULL) + one numbered group (group = 1)
            --        was counted as 1 instead of 2, which made the CASE above
            --        skip the "/group" suffix. We add 1 if any NULL-group item exists.
            SELECT
                COUNT(DISTINCT pid2.[group])
                + MAX(CASE WHEN pid2.[group] IS NULL THEN 1 ELSE 0 END) AS group_count
            FROM pr_item_details pid2
            WHERE pid2.pr_basic_sno = pbf.pr_basic_sno
              AND pid2.is_active = 'Y'
        ) gc
        WHERE pbf.is_active = 'Y'
          AND pbf.status = 'A'
    ),

    -- ✅ Pre-filter only PRs that have quotations pending for this approver.
    --    Quotations are stored against the BASE pr_no, so we match on base_pr_no.
    --    (If your quotations are stored as 'PR.../group', change to pg.split_pr_no.)
    eligible_prs AS
    (
        SELECT DISTINCT pg.pr_basic_sno, pg.grp
        FROM pr_groups pg
        INNER JOIN supplier_quotation_info sq
            ON sq.pr_no = pg.split_pr_no
           AND sq.pr_no = pg.split_pr_no          -- ⬅ join key (was split_pr_no)
        WHERE sq.is_active = 1
          AND sq.status IN ('P')
        AND sq.approver_ecno = @Ecno
    )

    SELECT
        -- ── PR Header ────────────────────────────────────────────
        pg.pr_basic_sno,
        pg.split_pr_no          AS pr_no,          -- ✅ now returns PR26270001/1 for grouped rows
        pg.base_pr_no,
        pg.grp                  AS [group],

        pg.brn_sno,
        pg.brn_name,
        pg.brn_prefix,
        pg.dept_name,
        pg.div_prefix,
        pg.div_name,
        pg.div_sno,
        pg.com_name,
        pg.com_sno,
        pg.company_address,
        pg.branch_address,
        pg.dept_sno,

        pg.reg_date,
        pg.required_date,
        pg.priority_sno,
        pg.purpose,

        pg.pr_created_by_name,
        pg.created_by           AS pr_created_by,
        pg.created_date         AS pr_created_date,

        -- ── PR Items (original) ───────────────────────────────────
        JSON_QUERY(
        (
            SELECT
                pid.pr_item_sno,
                pid.pr_basic_sno,
                pid.prod_sno,
                pm.prod_name,
                pm.prod_code,
                pm.prod_notes,
                pid.specification,
                pid.qty,
                pid.unit,
                uom.uom_name,
                uom.uom_code,
                pid.est_cost,
                pid.total_cost,
                pid.remarks,
                pid.[group],
                CASE
                    WHEN pid.[group] IS NOT NULL AND pg.group_count > 1
                        THEN pg.base_pr_no + '/' + CAST(pid.[group] AS VARCHAR(10))
                    ELSE pg.base_pr_no
                END AS pr_no
            FROM pr_item_details pid
            INNER JOIN product_master pm   ON pm.prod_sno  = pid.prod_sno
            INNER JOIN uom_master uom      ON uom.uom_sno  = pid.unit
            WHERE pid.pr_basic_sno = pg.pr_basic_sno
              AND pid.is_active = 'Y'
              AND (
                    (pid.[group] = pg.grp)
                    OR (pid.[group] IS NULL AND pg.grp IS NULL)
                  )
            FOR JSON PATH
        )) AS original_pr_item_details,

        -- ── ✅ All Quotations for this PR as a JSON array ─────────
        JSON_QUERY(
        (
            SELECT
                sq.sq_basic_sno,
                sq.vendor_sno,
                vgaki.company_name,
                vgaki.contact_person,
                vgaki.email,
                vgaki.mobile_number,
                vgaki.business_type,
                vgaki.gst_no,
                vgaki.pan_no,
                vgaki.supp_code,
                vgaki.kyc_address,
                sq.quotation_ref_no,
                sq.quotation_date,
                sq.valid_upto,
                sq.currency_code,
                sq.payment_terms,
                sq.delivery_days,
                sq.remarks,

                CAST(CASE WHEN ISNULL(sq.is_selected, 0) = 1 THEN 1 ELSE 0 END AS BIT) AS is_selected,

                sq.is_active,
                sq.workflow_types_id,
                sq.status,
                sq.created_by,
                sq.created_date,
                sq.modifed_by,
                sq.modifed_date,
                sq.sq_quotation_file,
                sq.transferred_from,
                sq.transferred_to,
                sq.approver_ecno,
                sq.buyback_available,
                sq.buyback_value,
                sq.advance_payment_required,
                sq.advance_payment_pct,
                sq.sq_adv_sno,

                COALESCE(appr.ename, apprns.full_name)  AS approver_name,
                sqcr.ename  AS quotation_created_by_name,

                -- Quotation Items
                JSON_QUERY(
                (
                    SELECT
                        sid.sq_item_sno,
                        sid.sq_basic_sno,
                        sid.pr_item_sno,
                        sid.prod_sno,
                        pm2.prod_name,
                        pm2.prod_code,
                       sid.specification,
                        sid.qty,
                        sid.unit,
                        uom2.uom_name,
                        uom2.uom_code,
                        sid.unit_price,
                        sid.discount_pct,
                        sid.tax_pct,
                        sid.total_amount,
                        sid.delivery_days,                            sid.remarks,
                        pid2.est_cost   AS pr_est_cost,
                        pid2.total_cost AS pr_total_cost,
                        pid2.qty        AS pr_qty
                    FROM supplier_quotation_items sid
                    INNER JOIN product_master pm2  ON pm2.prod_sno  = sid.prod_sno
                    INNER JOIN uom_master uom2     ON uom2.uom_sno  = sid.unit
              INNER  JOIN pr_item_details pid2 ON pid2.pr_item_sno = sid.pr_item_sno
                    WHERE
                    --sid.sq_basic_sno = sq.sq_basic_sno AND
                       sid.is_active = 1    AND
                      pr_no= pg.split_pr_no
                    FOR JSON PATH
                )) AS quotation_item_details,

                -- Advance Details
                JSON_QUERY(
                (
                    SELECT
                        sad.sq_adv_sno,
                        sad.sq_basic_sno,
                        sad.quotation_ref_no,
                        sad.payment_terms,
                        sad.advance_payment_pct,
                        sad.gst_applicable,
                        sad.gst_pct,
                        sad.reason,
                        sad.note,
                        sad.adv_issue_stages,
                        sad.is_active,
                        sad.created_by,
                        sad.created_date
                    FROM supplier_advance sad
                    WHERE sad.sq_basic_sno = sq.sq_basic_sno
                      AND sad.is_active = 'Y'
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
                )) AS advance_details,

                -- Quotation History
                JSON_QUERY(
                (
                    SELECT
                        sh.sq_history_sno,
     sh.sq_basic_sno,
                        sh.status,
                        sh.status_by,
                        COALESCE(ve.ename, vens.full_name)  AS status_by_name,
                        sh.comment,
                        sh.action_type,
                        sh.pr_basic_sno,
                        sh.selected_by,
                        sh.pr_no,
                        sh.transferred_from,
                        sh.transferred_to,
                        sh.sq_edit_data
                    FROM supplier_quotation_history sh
                    LEFT JOIN vw_verified_employees ve ON ve.ecno = sh.status_by
                    LEFT JOIN dbo.nt_nonstaff_login vens ON vens.login_id = sh.status_by
                    WHERE sh.sq_basic_sno = sq.sq_basic_sno
                      AND sh.is_active = 1
                    FOR JSON PATH
                )) AS quotation_history,

                -- Workflow Stage
                (
                    SELECT  ws.stage_order_json
                    FROM workflow_stage ws
                    WHERE ws.workflow_types_id = sq.workflow_types_id
                      AND ws.is_active = 'Y'
                ) AS stage_order_json

            FROM supplier_quotation_info sq
            INNER  JOIN kyc_basic_info vm          ON vm.kyc_basic_info_sno = sq.vendor_sno
            LEFT   JOIN vw_verified_employees appr ON appr.ecno = sq.approver_ecno
            LEFT   JOIN dbo.nt_nonstaff_login apprns ON apprns.login_id = sq.approver_ecno
            INNER  JOIN vw_verified_employees sqcr ON sqcr.ecno = sq.created_by
            INNER JOIN vw_get_all_kyc_info vgaki  ON vgaki.kyc_basic_info_sno = sq.vendor_sno

            WHERE sq.pr_basic_sno = pg.pr_basic_sno
              AND sq.pr_no        = pg.split_pr_no   --
              AND sq.is_active    = 1
              AND sq.status      IN ('P')
              AND sq.approver_ecno = @Ecno
            ORDER BY
                CAST(CASE WHEN ISNULL(sq.is_selected, 0) = 1 THEN 1 ELSE 0 END AS BIT) DESC,
                sq.sq_basic_sno
            FOR JSON PATH   -- ✅ produces: [{ quotation1 }, { quotation2 }, ...]
        )) AS quotations

    FROM pr_groups pg
    INNER JOIN eligible_prs ep
        ON ep.pr_basic_sno = pg.pr_basic_sno
       AND (ep.grp = pg.grp OR (ep.grp IS NULL AND pg.grp IS NULL))
    WHERE (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = pg.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = pg.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = pg.brn_sno)
          )
      )
    ORDER BY
        pg.pr_basic_sno,
        pg.grp;

END TRY
BEGIN CATCH
    DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE(),
            @ErrorSeverity INT            = ERROR_SEVERITY(),
            @ErrorState    INT            = ERROR_STATE();

    RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
END CATCH;
GO
-- ============================================================
-- Fix: non-staff approvers (e.g. IA001) saw an EMPTY PO approval screen.
-- Database: Non_Trade + Non_trade_Dev (MSSQL)
--
-- Root cause (reported 2026-09-24, IA001 "no details shown" on PO Approvals):
--
-- Every org-scoped GET endpoint runs the attachHierarchyScope middleware,
-- which calls sp_nt_GetUserHierarchy(@Ecno = req.user_ecno) and hands the
-- result to the endpoint's SP as @HierarchyJson. For a non-staff login,
-- req.user_ecno is the LOGIN ID ("IA001") — getEcnoFromUser falls back to
-- login_id, see project-nonstaff-dashboard-merge — but non-staff permission
-- rows in nt_user_permissions_json are keyed by login_id with ecno = NULL
-- (32_nonstaff_role_approval.sql). sp_nt_GetUserHierarchy only matched
-- `ecno = @Ecno`, so it returned zero rows for every non-staff user.
--
-- The middleware is deliberately fail-closed: no rows -> hierarchyJson = []
-- (never NULL, since NULL means "no filter"). sp_nt_GetQuotationsForApproval
-- then evaluates EXISTS(SELECT 1 FROM OPENJSON('[]') ...) = false for every
-- row and returns nothing — even though IA001 has a pending quotation
-- (PR26270016-1) assigned to them. Verified live: the same SP with
-- @HierarchyJson = NULL or IA001's real hierarchy returns that row; with
-- '[]' it returns 0.
--
-- Same latent defect affected every other hierarchy-scoped endpoint for any
-- non-staff user (PR approvals, masters, inventory, GRN, ...): they were all
-- silently seeing nothing. This one shared read fixes them all.
--
-- Fix: fall back to the login_id-keyed row when no staff (ecno) row exists.
-- A staff ecno match always wins (ORDER BY), and the login_id branch is
-- restricted to rows where ecno IS NULL so it can never pick up a staff
-- user's row. Return shape is unchanged (com_sno, div_sno, brn_sno,
-- dept_sno), so no consumer changes.
--
-- Re-runnable (CREATE OR ALTER). Rollback:
-- backups/nonstaff_hierarchy_2026-09-24_ROLLBACK.sql
-- ============================================================

CREATE OR ALTER   PROCEDURE dbo.sp_nt_GetUserHierarchy
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX);
    SELECT TOP 1 @HierarchyJson = hierarchy_json
    FROM dbo.nt_user_permissions_json
    WHERE is_active = 'Y'
      AND (ecno = @Ecno OR (ecno IS NULL AND login_id = @Ecno))
    ORDER BY CASE WHEN ecno = @Ecno THEN 0 ELSE 1 END,
             user_perm_json_sno DESC;

    SELECT com_sno, div_sno, brn_sno, dept_sno
    FROM OPENJSON(@HierarchyJson)
    WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno', dept_sno INT '$.dept_sno');
END;
GO
-- ============================================================
-- Approval Workflow list — division short name + branches per workflow
-- Database : Non_Trade / Non_trade_Dev (MSSQL, 10.0.21.8)
-- Used by  : GET /api/workflow_approval/getWorkflows -> Approval Workflows screen
--
-- Why
-- ---
-- The workflow dropdown showed "<workflow_name> (<workflow_code>)", e.g.
-- "PurchaseRequisition Approval Workflow (WF_PURCHASEREQUISITION_016)". Too long,
-- and three different PR workflows were all called the same thing, told apart only
-- by that code. The screen now builds a short label ("PR · TCS · TCS-Coimbatore",
-- or just "KYC") — but a workflow's division/branches live on its workflow_types
-- rows, not on approval_workflow_master, which is all this procedure returned.
--
-- What changed
-- ------------
-- sp_nt_GetWorkflowMasters returns two extra columns, both '|'-delimited so the
-- caller can shorten/join them however it likes:
--     division_short  distinct division prefixes of the workflow's ACTIVE types
--     branch_names    distinct branch names of the workflow's ACTIVE types
-- Existing columns, ordering and the is_active filter are unchanged, so nothing
-- else that reads this list (entity-type counts, the entity dropdown) is affected.
-- A workflow with no active types gets '' for both.
--
-- Rollback: sql/backups/pre_workflow_master_labels_2026-09-24_ROLLBACK.sql
-- ============================================================

CREATE OR ALTER   PROCEDURE dbo.sp_nt_GetWorkflowMasters
AS
BEGIN
    SET NOCOUNT ON;

    SELECT awm.workflow_id,
           awm.workflow_code,
           awm.workflow_name,
           awm.entity_type,
           awm.description,
           awm.is_active,
           ISNULL(scope.division_short, N'') AS division_short,
           ISNULL(scope.branch_names,   N'') AS branch_names
    FROM dbo.approval_workflow_master AS awm
    OUTER APPLY (
        SELECT
            (SELECT STRING_AGG(x.div_prefix, N'|') WITHIN GROUP (ORDER BY x.div_prefix)
             FROM (SELECT DISTINCT CAST(LTRIM(RTRIM(d.div_prefix)) AS NVARCHAR(50)) AS div_prefix
                   FROM dbo.workflow_types AS wt
                   JOIN dbo.division_master AS d ON d.div_sno = wt.div_sno
                   WHERE wt.workflow_id = awm.workflow_id
                     AND wt.is_active = 'Y'
                     AND NULLIF(LTRIM(RTRIM(d.div_prefix)), N'') IS NOT NULL) AS x) AS division_short,
            (SELECT STRING_AGG(y.brn_name, N'|') WITHIN GROUP (ORDER BY y.brn_name)
             FROM (SELECT DISTINCT CAST(LTRIM(RTRIM(b.brn_name)) AS NVARCHAR(200)) AS brn_name
                   FROM dbo.workflow_types AS wt
                   JOIN dbo.branch_master AS b ON b.brn_sno = wt.brn_sno
                   WHERE wt.workflow_id = awm.workflow_id
                     AND wt.is_active = 'Y'
                     AND NULLIF(LTRIM(RTRIM(b.brn_name)), N'') IS NOT NULL) AS y) AS branch_names
    ) AS scope
    WHERE awm.is_active = 'Y'
    ORDER BY awm.workflow_name;
END;
GO
-- Objects created by the sync (drop manually if rolling back fully):
-- FN fn_nt_DefaultTermsText
-- FN fn_resolve_approval_entity
-- FN fn_approval_field_entity
-- FN fn_scopeless_workflow_types
-- FN fn_approval_code
-- FN fn_approval_condition_met
-- FN fn_approval_next_seq
-- IF fn_nt_QuotationSupplyInfo
-- IF fn_pr_approval_context
-- V vw_nt_asset_requests
-- V vw_approval_route_variant
-- P sp_nt_ClaimApproverChangeNotices
-- P sp_nt_MarkApproverChangeNoticeSent
-- P sp_nt_UploadServiceAgreementSignedDoc
-- P sp_nt_GetServiceAgreementSignedDocs
-- P sp_nt_UploadServicePoInvoice
-- P sp_nt_GetServicePoInvoices
-- P sp_nt_AttachServicePoEntryInvoice
-- P sp_nt_GetUserIdentitiesInScope
-- P sp_nt_GetUomClassRecords
-- P sp_nt_CreateUomClassRecords
-- P sp_nt_UpdateUomClassRecords
-- P sp_nt_DeleteUomClassRecords
-- P sp_nt_GetTermsConditionsForScope
-- P sp_nt_GetApprovalConditionFields
-- P sp_nt_UpdateUomRecords
-- P sp_nt_DeleteUomRecords
-- P sp_nt_UpdateGstStateRecords
-- P sp_nt_DeleteGstStateRecords
-- P sp_nt_GetAssetRegister
-- P sp_nt_UpdatePriorityRecords
-- P sp_nt_GetAssetRequests
-- P sp_nt_DeletePriorityRecords
-- P sp_nt_GetAssetRequestDetail
-- P sp_nt_UpdateScreenRecords
-- P sp_nt_GetAssetSuppliers
-- P sp_nt_DeleteScreenRecords
-- P sp_nt_AssetIsStoreIncharge
-- P sp_nt_UpdatePermissionRecords
-- P sp_nt_CreateAssetRequest
-- P sp_nt_DeletePermissionRecords
-- P sp_nt_AssetRequestAction
-- P sp_nt_DeleteWorkflowMaster
-- P sp_nt_UpdateCategoryRecords
-- P sp_nt_DeleteCategoryRecords
-- P sp_nt_UpdateSubCategoryRecords
-- P sp_nt_DeleteSubCategoryRecords
-- P sp_nt_UpdateProductRecord
-- P sp_nt_DeleteProductRecord
-- P sp_nt_UpdateBankAccountTypeRecords
-- P sp_nt_DeleteBankAccountTypeRecords
-- P sp_nt_UpdateWarehouseLocationRecords
-- P sp_nt_DeleteWarehouseLocationRecords
-- P sp_nt_UpdateDesignationRecords
-- P sp_nt_DeleteDesignationRecords
-- P sp_nt_UpdateSupplierCategoryRecords
-- P sp_nt_DeleteSupplierCategoryRecords
-- P sp_nt_UpdatePaymentModeRecords
-- P sp_nt_DeletePaymentModeRecords
-- P sp_nt_UpdateServiceTypeRecords
-- P sp_nt_DeleteServiceTypeRecords
-- P sp_nt_UpdateServiceRecords
-- P sp_nt_DeleteServiceRecords
-- P sp_nt_UpdateRecurrenceCadenceRecords
-- P sp_nt_DeleteRecurrenceCadenceRecords
-- P sp_nt_UpdateDivRecords
-- P sp_nt_DeleteDivRecords
-- P sp_nt_UpdateDeptRecords
-- P sp_nt_DeleteDeptRecords
-- P sp_nt_UpdateCompanyRecords
-- P sp_nt_DeleteCompanyRecords
-- P sp_nt_UpdateBranchRecords
-- P sp_nt_DeleteBranchRecords
-- P sp_nt_ClaimServicePoAlerts
-- P sp_nt_MarkServicePoAlertSent
-- P sp_nt_GetApprovalRoutes
-- P sp_nt_SaveApprovalRoute
-- P sp_nt_CreateApprovalVariantEntity
-- P sp_nt_ClaimApprovalNotices
-- P sp_nt_MarkApprovalNoticeSent
-- P sp_nt_GetSupplierFullDetails
-- P sp_nt_ResolveWorkflow
-- P sp_nt_SaveApprovalModule
-- P sp_nt_SaveApprovalVariant
-- P sp_nt_GetPaymentTermsRecords
-- P sp_nt_CreatePaymentTermsRecords
-- P sp_nt_UpdatePaymentTermsRecords
-- P sp_nt_DeletePaymentTermsRecords
-- P sp_nt_GetQuotationSupplyInfo
-- P sp_nt_PrApprovalAct
-- P sp_nt_GetApprovedServiceKycVendorsForPicker
-- P sp_nt_PrApprovalContext
-- P sp_nt_DeleteNotification
-- P sp_nt_ClearReadNotifications
-- P sp_nt_GetSupplierStatusList
-- P sp_nt_GetSupplierStatusTimeline
-- TR trg_workflow_stage_reassign_approvers
-- TR trg_pr_basic_info_approval_instance
