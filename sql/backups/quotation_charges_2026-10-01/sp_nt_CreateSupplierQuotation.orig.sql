CREATE   PROCEDURE dbo.sp_nt_CreateSupplierQuotation
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
