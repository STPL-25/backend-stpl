-- 142: Purchase screen — edit a supplier quotation that is still pending approval.
--  * new sp_nt_UpdateSupplierQuotation: updates the header, the items (matched on pr_item_sno; items the user
--    drops are soft-deactivated, new ones inserted) and the advance row (updated / created / deactivated).
--    Allowed only while the quotation is status 'P', not selected and no PO/history row exists.
--  * sp_nt_GetSupplierQuotations now (a) skips inactive items / advance rows (needed because edits soft-delete),
--    (b) returns the unit sno + UOM name per item so the edit dialog can show the UOM.
-- Previous definition of sp_nt_GetSupplierQuotations: sql/112_quotation_payment_terms_charges_msme_gst.sql.
CREATE   PROCEDURE dbo.sp_nt_UpdateSupplierQuotation
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
               total_amount, delivery_days, remarks
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
            remarks       NVARCHAR(1000) '$.remarks'
        );

        UPDATE qi
        SET qi.is_active = 0
        FROM dbo.supplier_quotation_items qi
        WHERE qi.sq_basic_sno = @sq_basic_sno AND qi.is_active = 1
          AND NOT EXISTS (SELECT 1 FROM #new_items n WHERE n.pr_item_sno = qi.pr_item_sno);

        UPDATE qi
        SET qi.specification = n.specification, qi.qty = n.qty,
            qi.unit_price = n.unit_price, qi.discount_pct = n.discount_pct, qi.tax_pct = n.tax_pct,
            qi.total_amount = n.total_amount, qi.delivery_days = n.delivery_days, qi.remarks = n.remarks,
            qi.is_active = 1
        FROM dbo.supplier_quotation_items qi
        JOIN #new_items n ON n.pr_item_sno = qi.pr_item_sno
        WHERE qi.sq_basic_sno = @sq_basic_sno;

        INSERT INTO dbo.supplier_quotation_items
            (sq_basic_sno, pr_item_sno, prod_sno, specification, qty, unit, unit_price, discount_pct, tax_pct,
             total_amount, delivery_days, remarks, is_active)
        SELECT @sq_basic_sno, n.pr_item_sno, n.prod_sno, n.specification, n.qty, n.unit, n.unit_price, n.discount_pct,
               n.tax_pct, n.total_amount, n.delivery_days, n.remarks, 1
        FROM #new_items n
        WHERE NOT EXISTS (SELECT 1 FROM dbo.supplier_quotation_items qi
                          WHERE qi.sq_basic_sno = @sq_basic_sno AND qi.pr_item_sno = n.pr_item_sno);

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