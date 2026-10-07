CREATE PROCEDURE dbo.sp_nt_CreateServiceVendorKyc
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
        DECLARE @company_name       NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.company_name');
        DECLARE @contact_person     NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.contact_person');
        DECLARE @email              NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.email');
        DECLARE @mobile_number      VARCHAR(15)   = JSON_VALUE(@jsonInput, '$.mobile_number');
        DECLARE @business_type      NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.business_type');
        DECLARE @is_gst_avail       CHAR(1)       = ISNULL(JSON_VALUE(@jsonInput, '$.is_gst_avail'), 'N');
        DECLARE @gst_no             VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.gst_no');
        DECLARE @is_msme_avail      CHAR(1)       = ISNULL(JSON_VALUE(@jsonInput, '$.is_msme_avail'), 'N');
        DECLARE @msme_no            VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.msme_no');
        DECLARE @pan_no             VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.pan_no');
        DECLARE @supplier_cat_code  VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.supplier_cat_code');
        DECLARE @legal_name         VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.legal_name');
        DECLARE @trade_name         VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.trade_name');
        DECLARE @gst_status         VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.gst_status');
        DECLARE @gst_blk_status     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.gst_blk_status');
        DECLARE @date_of_reg        VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.date_of_reg');
        DECLARE @taluk              NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.taluk');
        DECLARE @city               NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.city');
        DECLARE @state              NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.state');
        DECLARE @state_code         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.state_code') AS INT);
        DECLARE @ac_holder_name     NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.ac_holder_name');
        DECLARE @ac_number          VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.ac_number');
        DECLARE @ac_type            VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.ac_type');
        DECLARE @ifsc               VARCHAR(15)   = JSON_VALUE(@jsonInput, '$.ifsc');
        DECLARE @bank_name          NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.bank_name');
        DECLARE @bank_branch_name   NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.bank_branch_name');
        DECLARE @bank_address       NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.bank_address');
        DECLARE @preferred_payment_mode VARCHAR(30) = JSON_VALUE(@jsonInput, '$.preferred_payment_mode');
        DECLARE @document           NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.document');
        DECLARE @remarks            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @created_by         VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @created_by IS NULL
            THROW 58201, 'com_sno, div_sno, brn_sno, dept_sno and created_by are required.', 1;

        IF @company_name IS NULL OR LTRIM(RTRIM(@company_name)) = ''
            THROW 58202, 'company_name is required.', 1;

        IF @contact_person IS NULL OR LTRIM(RTRIM(@contact_person)) = ''
            THROW 58203, 'contact_person is required.', 1;

        IF @mobile_number IS NULL OR LTRIM(RTRIM(@mobile_number)) = ''
            THROW 58204, 'mobile_number is required.', 1;

        IF @email IS NULL OR LTRIM(RTRIM(@email)) = ''
            THROW 58205, 'email is required.', 1;

        IF @business_type IS NULL OR LTRIM(RTRIM(@business_type)) = ''
            THROW 58206, 'business_type is required.', 1;

        IF @pan_no IS NULL OR LTRIM(RTRIM(@pan_no)) = ''
            THROW 58207, 'pan_no is required.', 1;

        IF @ac_holder_name IS NULL OR LTRIM(RTRIM(@ac_holder_name)) = ''
           OR @ac_number IS NULL OR LTRIM(RTRIM(@ac_number)) = ''
           OR @ac_type IS NULL OR LTRIM(RTRIM(@ac_type)) = ''
           OR @ifsc IS NULL OR LTRIM(RTRIM(@ifsc)) = ''
           OR @bank_name IS NULL OR LTRIM(RTRIM(@bank_name)) = ''
           OR @bank_branch_name IS NULL OR LTRIM(RTRIM(@bank_branch_name)) = ''
           OR @bank_address IS NULL OR LTRIM(RTRIM(@bank_address)) = ''
            THROW 58210, 'Bank account details (holder name, account number, account type, IFSC, bank name, branch name, address) are required.', 1;

        -- ── Resolve the ServiceVendorKYC workflow for this org scope ───────
        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);

        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceVendorKYC';

        IF @workflow_types_id IS NULL
            THROW 58208, 'No ServiceVendorKYC workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key] = '0' AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 58209, 'No approver found for the first stage of the ServiceVendorKYC workflow.', 1;

        INSERT INTO dbo.service_vendor_kyc (
            com_sno, div_sno, brn_sno, dept_sno, company_name, contact_person, email, mobile_number,
            business_type, is_gst_avail, gst_no, is_msme_avail, msme_no, pan_no, supplier_cat_code,
            legal_name, trade_name, gst_status, gst_blk_status, date_of_reg, taluk, city, state, state_code,
            ac_holder_name, ac_number, ac_type, ifsc, bank_name, bank_branch_name, bank_address,
            preferred_payment_mode, document, remarks, workflow_types_id, current_approver_id,
            status, is_active, created_by
        )
        VALUES (
            @com_sno, @div_sno, @brn_sno, @dept_sno, @company_name, @contact_person, @email, @mobile_number,
            @business_type, @is_gst_avail, @gst_no, @is_msme_avail, @msme_no, @pan_no, @supplier_cat_code,
            @legal_name, @trade_name, @gst_status, @gst_blk_status, @date_of_reg, @taluk, @city, @state, @state_code,
            @ac_holder_name, @ac_number, @ac_type, @ifsc, @bank_name, @bank_branch_name, @bank_address,
            @preferred_payment_mode, @document, @remarks, @workflow_types_id, @first_approver,
            'P', 'Y', @created_by
        );

        DECLARE @service_vendor_kyc_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.service_vendor_kyc_history (service_vendor_kyc_sno, action_type, status_by, comment, is_active)
        VALUES (@service_vendor_kyc_sno, 'SUBMITTED', @created_by, NULL, 'Y');

        COMMIT TRANSACTION;

        SELECT
            @service_vendor_kyc_sno AS service_vendor_kyc_sno,
            'SUCCESS'                AS result,
            N'Service vendor KYC submitted for approval.' AS message;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;