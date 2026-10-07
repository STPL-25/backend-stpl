CREATE PROCEDURE dbo.sp_approve_service_vendor_kyc
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @service_vendor_kyc_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_vendor_kyc_sno') AS INT);
        DECLARE @approved_by            VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by');
        DECLARE @comments               VARCHAR(1000) = JSON_VALUE(@jsonInput, '$.comments');
        DECLARE @approval_stages        NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages');
        DECLARE @action                 VARCHAR(20)   = LOWER(JSON_VALUE(@jsonInput, '$.action'));

        IF @service_vendor_kyc_sno IS NULL
            THROW 58220, 'service_vendor_kyc_sno is required.', 1;
        IF @approved_by IS NULL OR LTRIM(RTRIM(@approved_by)) = ''
            THROW 58221, 'approved_by is required.', 1;
        IF @action NOT IN ('approve', 'reject')
            THROW 58222, 'action must be approve or reject.', 1;
        IF @action = 'reject' AND (@comments IS NULL OR LTRIM(RTRIM(@comments)) = '')
            THROW 58223, 'comments are required when rejecting.', 1;
        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
            THROW 58224, 'Invalid or missing approval_stages.', 1;

        DECLARE @current_status CHAR(1), @current_approver VARCHAR(30);
        SELECT @current_status = status, @current_approver = current_approver_id
        FROM dbo.service_vendor_kyc WHERE service_vendor_kyc_sno = @service_vendor_kyc_sno AND is_active = 'Y';

        IF @current_status IS NULL
            THROW 58225, 'Service vendor KYC record not found.', 1;
        IF @current_status <> 'P'
            THROW 58226, 'This record is not pending approval.', 1;
        IF @current_approver <> @approved_by
            THROW 58227, 'You are not the current approver for this record.', 1;

        CREATE TABLE #approval_stages (
            seq_no             INT,
            approver_ecno      VARCHAR(30),
            stage              VARCHAR(100),
            can_forward        CHAR(1),
            can_backward       CHAR(1)
        );
        INSERT INTO #approval_stages (seq_no, approver_ecno, stage, can_forward, can_backward)
        SELECT
            CAST(oj.[key] AS INT),
            JSON_VALUE(oj.[value], '$.approver_ecno'),
            JSON_VALUE(oj.[value], '$.stage'),
            JSON_VALUE(oj.[value], '$.can_forward'),
            JSON_VALUE(oj.[value], '$.can_backward')
        FROM OPENJSON(@approval_stages) AS oj;

        BEGIN TRANSACTION;

        IF @action = 'reject'
        BEGIN
            UPDATE dbo.service_vendor_kyc
            SET status = 'R', current_approver_id = NULL, modified_by = @approved_by, modified_at = GETDATE()
            WHERE service_vendor_kyc_sno = @service_vendor_kyc_sno;

            INSERT INTO dbo.service_vendor_kyc_history (service_vendor_kyc_sno, action_type, status_by, comment, is_active)
            VALUES (@service_vendor_kyc_sno, 'REJECTED', @approved_by, @comments, 'Y');

            COMMIT TRANSACTION;
            DROP TABLE #approval_stages;

            SELECT 'REJECTED' AS result, @service_vendor_kyc_sno AS service_vendor_kyc_sno;
            RETURN;
        END

        -- APPROVE: resolve next stage
        DECLARE @next_current_approver VARCHAR(30);
        ;WITH stage_cte AS (
            SELECT seq_no, approver_ecno, LEAD(approver_ecno) OVER (ORDER BY seq_no) AS next_ecno
            FROM #approval_stages
        )
        SELECT @next_current_approver = next_ecno FROM stage_cte WHERE approver_ecno = @approved_by;

        INSERT INTO dbo.service_vendor_kyc_history (service_vendor_kyc_sno, action_type, status_by, comment, is_active)
        VALUES (@service_vendor_kyc_sno, 'APPROVED', @approved_by, @comments, 'Y');

        IF @next_current_approver IS NOT NULL
        BEGIN
            UPDATE dbo.service_vendor_kyc
            SET current_approver_id = @next_current_approver, modified_by = @approved_by, modified_at = GETDATE()
            WHERE service_vendor_kyc_sno = @service_vendor_kyc_sno;

            COMMIT TRANSACTION;
            DROP TABLE #approval_stages;

            SELECT 'APPROVED' AS result, 'N' AS is_final, @service_vendor_kyc_sno AS service_vendor_kyc_sno,
                   @next_current_approver AS next_approver;
            RETURN;
        END

        -- FINAL STAGE: generate service_vendor_code, provision kyc_basic_info
        DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT,
                @company_name NVARCHAR(50), @contact_person NVARCHAR(50), @email NVARCHAR(50),
                @mobile_number VARCHAR(15), @business_type NVARCHAR(50), @is_gst_avail CHAR(1),
                @gst_no VARCHAR(20), @is_msme_avail CHAR(1), @msme_no VARCHAR(20), @pan_no VARCHAR(20),
                @supplier_cat_code VARCHAR(20), @created_by VARCHAR(20);

        SELECT
            @com_sno = com_sno, @div_sno = div_sno, @brn_sno = brn_sno, @dept_sno = dept_sno,
            @company_name = company_name, @contact_person = contact_person, @email = email,
            @mobile_number = mobile_number, @business_type = business_type, @is_gst_avail = is_gst_avail,
            @gst_no = gst_no, @is_msme_avail = is_msme_avail, @msme_no = msme_no, @pan_no = pan_no,
            @supplier_cat_code = supplier_cat_code, @created_by = created_by
        FROM dbo.service_vendor_kyc WHERE service_vendor_kyc_sno = @service_vendor_kyc_sno;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(service_vendor_code, 4) AS INT)), 0) + 1
        FROM dbo.service_vendor_kyc WITH (UPDLOCK, HOLDLOCK)
        WHERE service_vendor_code LIKE 'SVK-' + @year + '-%';

        DECLARE @service_vendor_code VARCHAR(30) = 'SVK-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.kyc_basic_info (
            com_sno, div_sno, brn_sno, dept_sno, company_name, contact_person, email, mobile_number,
            business_type, is_gst_avail, gst_no, is_msme_avail, msme_no, pan_no, supplier_cat_code,
            approver_ecno, workflow_types_id, status, supp_code, vendor_category, is_active, created_by, created_date
        )
        VALUES (
            @com_sno, @div_sno, @brn_sno, @dept_sno, @company_name, @contact_person, @email, @mobile_number,
            @business_type, @is_gst_avail, @gst_no, @is_msme_avail, @msme_no, @pan_no, @supplier_cat_code,
            @approved_by, NULL, 'A', @service_vendor_code, 'SERVICE', 'Y', @created_by, GETDATE()
        );

        DECLARE @new_kyc_basic_info_sno INT = SCOPE_IDENTITY();

        UPDATE dbo.service_vendor_kyc
        SET status = 'A', service_vendor_code = @service_vendor_code,
            kyc_basic_info_sno = @new_kyc_basic_info_sno,
            current_approver_id = NULL, modified_by = @approved_by, modified_at = GETDATE()
        WHERE service_vendor_kyc_sno = @service_vendor_kyc_sno;

        COMMIT TRANSACTION;
        DROP TABLE #approval_stages;

        SELECT 'FINAL_APPROVED' AS result, 'Y' AS is_final, @service_vendor_kyc_sno AS service_vendor_kyc_sno,
               @service_vendor_code AS service_vendor_code, @new_kyc_basic_info_sno AS kyc_basic_info_sno;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL DROP TABLE #approval_stages;
        THROW;
    END CATCH
END;