-- ============================================================
-- 129_kyc_insert_workflow_no_hardcode.sql
-- sp_InsertKYCData no longer hard-codes the workflow type id (Dev fell back to 5, Non_Trade was pinned
-- to 16). KYC is organisation-independent, so the workflow is looked up from the configured KYC workflow
-- (fn_scopeless_workflow_types) and the insert fails loudly if none is configured.
-- Apply to Non_Trade deliberately: resolves to the lowest-id active KYC type (16 today).
-- ============================================================
-- sp_InsertKYCData: KYC routed through the mapping
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

        -- KYC is not tied to company/division/branch/department: one KYC workflow serves every organisation,
        -- so take the lowest-id active workflow type routed to KYC. No hard-coded id.
        SET @workflow_types_id = dbo.fn_scopeless_workflow_types(dbo.fn_resolve_approval_entity('KYC', 'SUPPLIER'));
        IF @workflow_types_id IS NULL
            THROW 50008, 'No active KYC approval workflow is configured.', 1;
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
