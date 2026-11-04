-- 144: Supplier quotation — per-item "Additional" covers, replacing the fixed Warranty/AMC columns of sql/143.
--  * supplier_quotation_items.additional_json: JSON list of {type: Warranty|AMC|Other, label, years, cost_type: Free|Paid|Semi-paid, terms}.
--  * Create/Update/Get quotation procs + sp_nt_GetQuotationsForApproval read and write it (returned as "additional").
--  * The six sql/143 columns are dropped (never used by a release). Procs are rebuilt from the pre-143 definitions
--    in sql/backups/warranty_amc_2026-10-28/*.before.sql. Re-runnable.
IF COL_LENGTH('dbo.supplier_quotation_items','additional_json') IS NULL ALTER TABLE dbo.supplier_quotation_items ADD additional_json NVARCHAR(MAX) NULL;
GO
-- sp_nt_CreateSupplierQuotation: PO routed through the mapping
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

        -- MSME flag/type and intrastate-vs-interstate are NOT entered: taken from the supplier KYC and the
        -- billing company's GST (see sp_nt_GetQuotationSupplyInfo), overriding anything the client sent.
        SELECT @is_msme = si.is_msme, @msme_type = si.msme_type, @is_intrastate = si.is_intrastate
        FROM dbo.fn_nt_QuotationSupplyInfo(@vendor_sno, @com_sno) si;
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
          AND awm.entity_type = dbo.fn_resolve_approval_entity('PurchaseOrder', 'STANDARD')
          AND wt.is_active = 'Y' AND awm.is_active = 'Y'
          AND EXISTS (SELECT 1 FROM dbo.workflow_stage act_ws WHERE act_ws.workflow_types_id = wt.workflow_types_id AND act_ws.is_active = 'Y');

        IF @workflow_types_id IS NULL
            THROW 52112, N'No active approval workflow is configured for this branch and department.', 1;

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
            is_active,
            additional_json
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
            ISNULL(is_active, 1),
            additional_json
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
            is_active     BIT             '$.is_active',
            additional_json NVARCHAR(MAX) '$.additional' AS JSON
        );

        -- Additional covers (Warranty / AMC / Others): keep NULL when the list is empty.
        UPDATE dbo.supplier_quotation_items SET additional_json = NULL
        WHERE sq_basic_sno = @sq_basic_sno AND (additional_json IS NULL OR ISJSON(additional_json) = 0 OR additional_json = N'[]');


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

-- 142: Purchase screen — edit a supplier quotation that is still pending approval.
--  * new sp_nt_UpdateSupplierQuotation: updates the header, the items (matched on pr_item_sno; items the user
--    drops are soft-deactivated, new ones inserted) and the advance row (updated / created / deactivated).
--    Allowed only while the quotation is status 'P', not selected and no PO/history row exists.
--  * sp_nt_GetSupplierQuotations now (a) skips inactive items / advance rows (needed because edits soft-delete),
--    (b) returns the unit sno + UOM name per item so the edit dialog can show the UOM.
-- Previous definition of sp_nt_GetSupplierQuotations: sql/112_quotation_payment_terms_charges_msme_gst.sql.
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateSupplierQuotation
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRAN;

        IF ISJSON(@jsonInput) <> 1
            THROW 52120, N'Invalid JSON input.', 1;

        DECLARE
            @sq_basic_sno             INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.sq_basic_sno') AS INT),
            @modified_by              NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.modified_by'),
            @quotation_ref_no         NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.quotation_ref_no'),
            @quotation_date           DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.quotation_date') AS DATE),
            @valid_upto               DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.valid_upto') AS DATE),
            @currency_code            NVARCHAR(20)  = JSON_VALUE(@jsonInput, '$.currency_code'),
            @payment_terms            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.payment_terms'),
            @delivery_days            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.delivery_days') AS INT),
            @remarks                  NVARCHAR(1000)= JSON_VALUE(@jsonInput, '$.remarks'),
            @sq_quotation_file        NVARCHAR(500) = NULLIF(JSON_VALUE(@jsonInput, '$.sq_quotation_file'), ''),
            @freight_charges          DECIMAL(18,2) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.freight_charges') AS DECIMAL(18,2)), 0),
            @other_charges            DECIMAL(18,2) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.other_charges') AS DECIMAL(18,2)), 0),
            @freight_gst_pct          DECIMAL(5,2)  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.freight_gst_pct') AS DECIMAL(5,2)), 0),
            @other_charges_gst_pct    DECIMAL(5,2)  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.other_charges_gst_pct') AS DECIMAL(5,2)), 0),
            @buyback_available        BIT           = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.buyback_available') AS BIT), 0),
            @buyback_value            DECIMAL(18,3) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.buyback_value') AS DECIMAL(18,3)), 0),
            @advance_payment_required BIT           = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.advance_payment_required') AS BIT), 0),
            @advance_payment_pct      DECIMAL(10,3) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.advance_payment_pct') AS DECIMAL(10,3)), 0),
            @adv_gst_pct              DECIMAL(10,3) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.advance_payment_data.gst_pct') AS DECIMAL(10,3)), 0),
            @adv_reason               VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.advance_payment_data.reason'),
            @adv_note                 VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.advance_payment_data.note'),
            @adv_issue_stages         NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.advance_payment_data.stages'),
            @adv_gst_applicable       CHAR(1)       = CASE WHEN ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.advance_payment_data.gst_applicable') AS BIT), 0) = 1 THEN 'Y' ELSE 'N' END,
            @vendor_sno               INT,
            @com_sno                  INT,
            @status                   NVARCHAR(50),
            @is_selected              BIT,
            @pr_no                    VARCHAR(50),
            @sq_adv_sno               INT,
            @is_msme                  CHAR(1),
            @msme_type                VARCHAR(20),
            @is_intrastate            BIT;

        SELECT @vendor_sno = vendor_sno, @com_sno = com_sno, @status = status,
               @is_selected = is_selected, @pr_no = pr_no, @sq_adv_sno = sq_adv_sno
        FROM dbo.supplier_quotation_info WITH (UPDLOCK, HOLDLOCK)
        WHERE sq_basic_sno = @sq_basic_sno AND is_active = 1;

        IF @vendor_sno IS NULL
            THROW 52121, N'Quotation not found.', 1;
        IF ISNULL(@status, 'P') <> 'P' OR ISNULL(@is_selected, 0) = 1
            THROW 52122, N'Only a quotation that is still pending approval can be edited.', 1;
        IF EXISTS (SELECT 1 FROM dbo.supplier_quotation_history WHERE pr_no = @pr_no AND is_active = 1)
            THROW 52123, N'A PO has already been created for this PR; its quotations can no longer be edited.', 1;
        IF @quotation_date IS NULL
            THROW 52124, N'quotation_date is required.', 1;
        IF NOT EXISTS (SELECT 1 FROM OPENJSON(@jsonInput, '$.items'))
            THROW 52125, N'At least one item is required.', 1;
        IF @freight_gst_pct < 0 OR @freight_gst_pct > 100 OR @other_charges_gst_pct < 0 OR @other_charges_gst_pct > 100
            THROW 52126, N'Charges GST % must be between 0 and 100.', 1;
        IF @freight_charges < 0 OR @other_charges < 0
            THROW 52127, N'Freight / other charges cannot be negative.', 1;

        -- MSME + intrastate come from the supplier KYC / billing GST, never from the client.
        SELECT @is_msme = si.is_msme, @msme_type = si.msme_type, @is_intrastate = si.is_intrastate
        FROM dbo.fn_nt_QuotationSupplyInfo(@vendor_sno, @com_sno) si;

        UPDATE dbo.supplier_quotation_info
        SET quotation_ref_no         = @quotation_ref_no,
            quotation_date           = @quotation_date,
            valid_upto               = @valid_upto,
            currency_code            = @currency_code,
            payment_terms            = @payment_terms,
            delivery_days            = @delivery_days,
            remarks                  = @remarks,
            buyback_available        = @buyback_available,
            buyback_value            = @buyback_value,
            advance_payment_required = @advance_payment_required,
            advance_payment_pct      = @advance_payment_pct,
            freight_charges          = @freight_charges,
            other_charges            = @other_charges,
            freight_gst_pct          = @freight_gst_pct,
            other_charges_gst_pct    = @other_charges_gst_pct,
            is_msme                  = @is_msme,
            msme_type                = @msme_type,
            is_intrastate            = @is_intrastate,
            sq_quotation_file        = ISNULL(@sq_quotation_file, sq_quotation_file),
            modifed_by               = @modified_by,
            modifed_date             = GETDATE()
        WHERE sq_basic_sno = @sq_basic_sno;

        -- Items: parse once, update the ones that exist, deactivate the ones dropped, insert the new ones.
        SELECT pr_item_sno, prod_sno, specification, qty, unit, unit_price, discount_pct, tax_pct,
               total_amount, delivery_days, remarks, additional_json
        INTO #new_items
        FROM OPENJSON(@jsonInput, '$.items')
        WITH
        (
            pr_item_sno   INT            '$.pr_item_sno',
            prod_sno      INT            '$.prod_sno',
            specification NVARCHAR(1000) '$.specification',
            qty           DECIMAL(18,4)  '$.qty',
            unit          INT            '$.unit',
            unit_price    DECIMAL(18,4)  '$.unit_price',
            discount_pct  DECIMAL(18,4)  '$.discount_pct',
            tax_pct       DECIMAL(18,4)  '$.tax_pct',
            total_amount  DECIMAL(18,4)  '$.total_amount',
            delivery_days INT            '$.delivery_days',
            remarks       NVARCHAR(1000) '$.remarks',
            additional_json NVARCHAR(MAX) '$.additional' AS JSON
        );

        UPDATE qi
        SET qi.is_active = 0
        FROM dbo.supplier_quotation_items qi
        WHERE qi.sq_basic_sno = @sq_basic_sno AND qi.is_active = 1
          AND NOT EXISTS (SELECT 1 FROM #new_items n WHERE n.pr_item_sno = qi.pr_item_sno);

        UPDATE qi
        SET qi.specification = n.specification, qi.qty = n.qty,
            qi.unit_price = n.unit_price, qi.discount_pct = n.discount_pct, qi.tax_pct = n.tax_pct,
            qi.total_amount = n.total_amount, qi.delivery_days = n.delivery_days, qi.remarks = n.remarks, qi.additional_json = n.additional_json,
            qi.is_active = 1
        FROM dbo.supplier_quotation_items qi
        JOIN #new_items n ON n.pr_item_sno = qi.pr_item_sno
        WHERE qi.sq_basic_sno = @sq_basic_sno;

        INSERT INTO dbo.supplier_quotation_items
            (sq_basic_sno, pr_item_sno, prod_sno, specification, qty, unit, unit_price, discount_pct, tax_pct,
             total_amount, delivery_days, remarks, is_active, additional_json)
        SELECT @sq_basic_sno, n.pr_item_sno, n.prod_sno, n.specification, n.qty, n.unit, n.unit_price, n.discount_pct,
               n.tax_pct, n.total_amount, n.delivery_days, n.remarks, 1, n.additional_json
        FROM #new_items n
        WHERE NOT EXISTS (SELECT 1 FROM dbo.supplier_quotation_items qi
                          WHERE qi.sq_basic_sno = @sq_basic_sno AND qi.pr_item_sno = n.pr_item_sno);

        -- Additional covers (Warranty / AMC / Others): keep NULL when the list is empty.
        UPDATE dbo.supplier_quotation_items SET additional_json = NULL
        WHERE sq_basic_sno = @sq_basic_sno AND (additional_json IS NULL OR ISJSON(additional_json) = 0 OR additional_json = N'[]');

        -- Advance: switched off -> deactivate; on -> update the existing row or create one.
        IF @advance_payment_required = 1 AND JSON_QUERY(@jsonInput, '$.advance_payment_data') IS NOT NULL
        BEGIN
            IF @sq_adv_sno IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.supplier_advance WHERE sq_adv_sno = @sq_adv_sno)
                UPDATE dbo.supplier_advance
                SET quotation_ref_no = @quotation_ref_no, payment_terms = @payment_terms,
                    advance_payment_pct = @advance_payment_pct, gst_applicable = @adv_gst_applicable,
                    gst_pct = @adv_gst_pct, reason = @adv_reason, note = @adv_note,
                    adv_issue_stages = @adv_issue_stages, is_active = 'Y'
                WHERE sq_adv_sno = @sq_adv_sno;
            ELSE
            BEGIN
                INSERT INTO dbo.supplier_advance
                    (sq_basic_sno, quotation_ref_no, payment_terms, advance_payment_pct, gst_applicable, gst_pct,
                     reason, note, adv_issue_stages, is_active, created_by, created_date)
                VALUES
                    (@sq_basic_sno, @quotation_ref_no, @payment_terms, @advance_payment_pct, @adv_gst_applicable,
                     @adv_gst_pct, @adv_reason, @adv_note, @adv_issue_stages, 'Y', @modified_by, CAST(GETDATE() AS DATE));
                SET @sq_adv_sno = SCOPE_IDENTITY();
                UPDATE dbo.supplier_quotation_info SET sq_adv_sno = @sq_adv_sno WHERE sq_basic_sno = @sq_basic_sno;
            END;
        END
        ELSE
            UPDATE dbo.supplier_advance SET is_active = 'N' WHERE sq_basic_sno = @sq_basic_sno AND is_active = 'Y';

        COMMIT TRAN;

        SELECT 1 AS success, 'Supplier quotation updated successfully' AS message, @sq_basic_sno AS sq_basic_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        THROW;
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
                sqi.unit       AS unit_sno,
                um.uom_name    AS unit_name,
                sqi.unit_price,
                sqi.discount_pct,
                sqi.tax_pct,
                sqi.total_amount,
                sqi.delivery_days,
                sqi.remarks,
                JSON_QUERY(sqi.additional_json) AS additional,
                sqi.is_active
            FROM supplier_quotation_items sqi
            INNER JOIN product_master pm
                ON sqi.prod_sno = pm.prod_sno
            LEFT JOIN uom_master um
                ON um.uom_sno = sqi.unit
            WHERE sqi.sq_basic_sno = sq.sq_basic_sno
              AND sqi.is_active = 1
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
              AND sa.is_active = 'Y'
            FOR JSON PATH
        ) AS supplier_advance
    FROM supplier_quotation_info sq
    WHERE
        sq.is_active   = 1
        AND sq.pr_basic_sno = @pr_basic_sno
        AND sq.pr_no        = @pr_no;
END;
GO

-- 114: PO approval queue showed every quotation's items under EACH quotation (qty doubled with 2 quotations).
-- The per-quotation item subquery had `sid.sq_basic_sno = sq.sq_basic_sno` commented out and filtered on an
-- unqualified pr_no (which resolved to the outer quotation row's pr_no), so it matched all quotations of the PR.
-- Restored the per-quotation filter. Original in sql/backups/quotation_charges_2026-10-01.
-- ── sp_nt_GetQuotationsForApproval — PO approval queue, now hierarchy-scoped ──

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetQuotationsForApproval
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
                        JSON_QUERY(sid.additional_json) AS additional,
                        pid2.est_cost   AS pr_est_cost,
                        pid2.total_cost AS pr_total_cost,
                        pid2.qty        AS pr_qty
                    FROM supplier_quotation_items sid
                    INNER JOIN product_master pm2  ON pm2.prod_sno  = sid.prod_sno
                    INNER JOIN uom_master uom2     ON uom2.uom_sno  = sid.unit
              INNER  JOIN pr_item_details pid2 ON pid2.pr_item_sno = sid.pr_item_sno
                    WHERE
                    sid.sq_basic_sno = sq.sq_basic_sno
                      AND sid.is_active = 1
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

-- Drop the sql/143 columns (procs no longer reference them).
DECLARE @s NVARCHAR(MAX) = N'';
SELECT @s += N'ALTER TABLE dbo.supplier_quotation_items DROP CONSTRAINT ' + QUOTENAME(dc.name) + N';'
FROM sys.default_constraints dc JOIN sys.columns col ON col.object_id = dc.parent_object_id AND col.column_id = dc.parent_column_id
WHERE dc.parent_object_id = OBJECT_ID('dbo.supplier_quotation_items') AND col.name IN ('warranty_applicable','amc_applicable');
EXEC (@s);
IF COL_LENGTH('dbo.supplier_quotation_items','warranty_applicable') IS NOT NULL ALTER TABLE dbo.supplier_quotation_items DROP COLUMN warranty_applicable;
IF COL_LENGTH('dbo.supplier_quotation_items','warranty_period') IS NOT NULL ALTER TABLE dbo.supplier_quotation_items DROP COLUMN warranty_period;
IF COL_LENGTH('dbo.supplier_quotation_items','warranty_terms') IS NOT NULL ALTER TABLE dbo.supplier_quotation_items DROP COLUMN warranty_terms;
IF COL_LENGTH('dbo.supplier_quotation_items','amc_applicable') IS NOT NULL ALTER TABLE dbo.supplier_quotation_items DROP COLUMN amc_applicable;
IF COL_LENGTH('dbo.supplier_quotation_items','amc_details') IS NOT NULL ALTER TABLE dbo.supplier_quotation_items DROP COLUMN amc_details;
IF COL_LENGTH('dbo.supplier_quotation_items','amc_terms') IS NOT NULL ALTER TABLE dbo.supplier_quotation_items DROP COLUMN amc_terms;
GO
