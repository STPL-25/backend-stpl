-- Rollback for sql/125: restores the 3 procs; new objects are left (harmless) except the screen row.

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

CREATE OR ALTER PROCEDURE [dbo].[sp_InsertKYCData]
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
            @workflow_types_id  INT,
            @pay_via_portal     CHAR(1),
            @portal_name        NVARCHAR(150),
            @portal_url         NVARCHAR(500),
            @pay_instructions   NVARCHAR(1000);
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



        -- Supplier pays via its own website/portal instead of a bank account.
        SET @pay_via_portal = CASE WHEN JSON_VALUE(@jsonInput, '$.pay_via_portal') IN ('true','1','Y') THEN 'Y' ELSE 'N' END;
        SET @portal_name      = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.payment_portal_name'))), '');
        SET @portal_url       = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.payment_portal_url'))), '');
        SET @pay_instructions = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.payment_instructions'))), '');
        IF @pay_via_portal = 'Y' AND (@portal_name IS NULL OR @portal_url IS NULL)
            THROW 50021, 'Portal payment needs the portal name and portal URL.', 1;

        SET  @workflow_types_id=5;
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
            legal_name,trade_name,txp_type, gst_status,gst_blk_status ,date_of_reg,
            pay_via_portal, payment_portal_name, payment_portal_url, payment_instructions
        )
        VALUES (
            @company_name, @contact_name, @email, @mobile_number,
            @business_type, @is_gst_avail, @gst_no, @is_msme_avail,
            @msme_no, @pan_no, @created_by, GETDATE(), 'Y', 'P' ,@workflow_types_id ,@approver_ecno ,@supplier_cat_code
            ,@legal_name,@trade_name,@txp_type,@gst_status,@gst_blk_status,@date_of_reg,
            @pay_via_portal, @portal_name, @portal_url, @pay_instructions
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

        -- 3. Insert into kyc_bank_info (none when the supplier pays via its portal)
        IF @pay_via_portal = 'N' AND ISJSON(@bankDetails) = 1
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

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetApprovalRoutes
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.module_code, m.module_label, m.variant_label AS variants_called,
           v.variant_code, v.variant_label,
           x.entity_code, em.entity_name,
           CAST(CASE WHEN r.route_id IS NULL THEN 0 ELSE 1 END AS BIT) AS has_route,
           (SELECT COUNT(*) FROM dbo.vw_approval_route_variant v2
             WHERE v2.module_code = v.module_code AND v2.variant_code <> v.variant_code
               AND dbo.fn_resolve_approval_entity(v2.module_code, v2.variant_code) = x.entity_code) AS shared_with,
           (SELECT COUNT(*) FROM dbo.approval_workflow_master w WHERE w.is_active = 'Y' AND w.entity_type = x.entity_code) AS workflows_configured,
           (SELECT e.entity_code, e.entity_name
              FROM dbo.entity_master e
             WHERE e.is_active = 'Y' AND e.route_module_code = m.module_code
             ORDER BY e.entity_name FOR JSON PATH) AS eligible_entities
    FROM dbo.approval_route_module m
    JOIN dbo.vw_approval_route_variant v ON v.module_code = m.module_code
    CROSS APPLY (SELECT dbo.fn_resolve_approval_entity(v.module_code, v.variant_code) AS entity_code) x
    LEFT JOIN dbo.approval_entity_route r ON r.module_code = v.module_code AND r.variant_code = v.variant_code AND r.is_active = 'Y'
    LEFT JOIN dbo.entity_master em ON em.entity_code = x.entity_code
    ORDER BY m.sort_order, v.sort_order, v.variant_code;
END;
GO

DELETE FROM dbo.screens WHERE comp = 'ApprovalRoutingPage';
GO
