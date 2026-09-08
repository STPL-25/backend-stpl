-- ============================================================
-- sp_approve_service_vendor_kyc — single-stage progression, copies
-- sp_approve_service_agreement v2's exact shape
-- (23_service_recurring_flow_redesign.sql:740-909): RAISERROR-based
-- validation, #approval_stages temp table + LEAD-based next-approver
-- resolution, reject branch, approve branch.
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/ServiceVendorKyc module
--
-- On final-stage approval only: generates service_vendor_code
-- (SVK-YYYY-NNNN, same per-year MAX(RIGHT(...,4))+1 under UPDLOCK,HOLDLOCK
-- idiom as service_agreement.agreement_no), then provisions a matching
-- kyc_basic_info row (see 43_service_vendor_kyc.sql's header for why) and
-- writes the new kyc_basic_info_sno back onto service_vendor_kyc. The same
-- generated code is used as kyc_basic_info.supp_code too, so both rows
-- carry one shared, recognizable identity.
--
-- kyc_basic_info's columns are ALL nullable except the identity PK
-- (confirmed live via INFORMATION_SCHEMA.COLUMNS — see 43_...sql's header),
-- so this INSERT only needs to set the fields service_vendor_kyc actually
-- collected; everything else (legal_name, trade_name, gst_status,
-- reference_no, instance_id, ...) is left NULL, same as any other row that
-- doesn't have that data yet.
-- @jsonInput: { service_vendor_kyc_sno, approved_by, comments, approval_stages, action }
-- action: 'approve' | 'reject'
-- ============================================================
IF OBJECT_ID('dbo.sp_approve_service_vendor_kyc', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_approve_service_vendor_kyc;
GO
CREATE PROCEDURE dbo.sp_approve_service_vendor_kyc
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

        DECLARE @service_vendor_kyc_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_vendor_kyc_sno') AS INT),
                @comments               VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages        NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by            VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action                 VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');

        IF @service_vendor_kyc_sno IS NULL
        BEGIN
            RAISERROR('service_vendor_kyc_sno is required.', 16, 1);
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

        IF NOT EXISTS (SELECT 1 FROM dbo.service_vendor_kyc WHERE service_vendor_kyc_sno = @service_vendor_kyc_sno AND is_active = 'Y')
        BEGIN
            RAISERROR('Service vendor KYC record not found or inactive.', 16, 1);
            RETURN;
        END

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
            INSERT INTO dbo.service_vendor_kyc_history (service_vendor_kyc_sno, action_type, status_by, comment, is_active)
            VALUES (@service_vendor_kyc_sno, 'REJECTED', @approved_by, @comments, 'Y');

            UPDATE dbo.service_vendor_kyc
            SET status = 'R', current_approver_id = NULL
            WHERE service_vendor_kyc_sno = @service_vendor_kyc_sno;

            DROP TABLE #approval_stages;

            SELECT 'REJECTED' AS result, @service_vendor_kyc_sno AS service_vendor_kyc_sno, @approved_by AS rejected_by, GETDATE() AS rejected_on;
            RETURN;
        END

        DECLARE @next_current_approver VARCHAR(30);

        SELECT @next_current_approver = next_stage.approver_ecno
        FROM (
            SELECT approver_ecno, LEAD(approver_ecno, 1, NULL) OVER (ORDER BY seq_no) AS next_approver_ecno
            FROM #approval_stages
        ) current_stage
        LEFT JOIN #approval_stages next_stage
            ON next_stage.approver_ecno = current_stage.next_approver_ecno
        WHERE current_stage.approver_ecno = @approved_by;

        INSERT INTO dbo.service_vendor_kyc_history (service_vendor_kyc_sno, action_type, status_by, comment, is_active)
        VALUES (@service_vendor_kyc_sno, 'APPROVED', @approved_by, @comments, 'Y');

        UPDATE dbo.service_vendor_kyc
        SET current_approver_id = @next_current_approver
        WHERE service_vendor_kyc_sno = @service_vendor_kyc_sno;

        DECLARE @new_kyc_basic_info_sno INT = NULL, @service_vendor_code VARCHAR(30) = NULL;

        IF @next_current_approver IS NULL
        BEGIN
            -- ── Final stage: generate the shared code, provision kyc_basic_info ──
            DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
            DECLARE @seq  INT;
            SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(service_vendor_code, 4) AS INT)), 0) + 1
            FROM dbo.service_vendor_kyc WITH (UPDLOCK, HOLDLOCK)
            WHERE service_vendor_code LIKE 'SVK-' + @year + '-%';
            SET @service_vendor_code = 'SVK-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

            DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT,
                    @company_name NVARCHAR(50), @contact_person NVARCHAR(50), @email NVARCHAR(50),
                    @mobile_number VARCHAR(15), @business_type NVARCHAR(50),
                    @is_gst_avail CHAR(1), @gst_no VARCHAR(20), @is_msme_avail CHAR(1), @msme_no VARCHAR(20),
                    @pan_no VARCHAR(20), @supplier_cat_code VARCHAR(20), @created_by VARCHAR(20);

            SELECT @com_sno = com_sno, @div_sno = div_sno, @brn_sno = brn_sno, @dept_sno = dept_sno,
                   @company_name = company_name, @contact_person = contact_person, @email = email,
                   @mobile_number = mobile_number, @business_type = business_type,
                   @is_gst_avail = is_gst_avail, @gst_no = gst_no, @is_msme_avail = is_msme_avail, @msme_no = msme_no,
                   @pan_no = pan_no, @supplier_cat_code = supplier_cat_code, @created_by = created_by
            FROM dbo.service_vendor_kyc
            WHERE service_vendor_kyc_sno = @service_vendor_kyc_sno;

            INSERT INTO dbo.kyc_basic_info (
                com_sno, div_sno, brn_sno, dept_sno, company_name, contact_person, email, mobile_number,
                business_type, is_gst_avail, gst_no, is_msme_avail, msme_no, pan_no, supplier_cat_code,
                approver_ecno, workflow_types_id, status, supp_code, is_active, created_by, created_date
            )
            VALUES (
                @com_sno, @div_sno, @brn_sno, @dept_sno, @company_name, @contact_person, @email, @mobile_number,
                @business_type, @is_gst_avail, @gst_no, @is_msme_avail, @msme_no, @pan_no, @supplier_cat_code,
                @approved_by, NULL, 'A', @service_vendor_code, 'Y', @created_by, GETDATE()
            );
            SET @new_kyc_basic_info_sno = SCOPE_IDENTITY();

            UPDATE dbo.service_vendor_kyc
            SET status = 'A', service_vendor_code = @service_vendor_code, kyc_basic_info_sno = @new_kyc_basic_info_sno
            WHERE service_vendor_kyc_sno = @service_vendor_kyc_sno;
        END

        DROP TABLE #approval_stages;

        SELECT
            'SUCCESS'                                      AS result,
            @service_vendor_kyc_sno                        AS service_vendor_kyc_sno,
            @approved_by                                    AS approved_by,
            GETDATE()                                        AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE')     AS next_approver,
            @service_vendor_code                              AS service_vendor_code,
            @new_kyc_basic_info_sno                            AS kyc_basic_info_sno;

    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL
            DROP TABLE #approval_stages;

        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT OBJECT_ID('dbo.sp_approve_service_vendor_kyc');
--   -- end-to-end (once a ServiceVendorKYC workflow is configured, see file 48):
--   -- create a record, approve it, then:
--   SELECT service_vendor_kyc_sno, service_vendor_code, status, kyc_basic_info_sno FROM dbo.service_vendor_kyc;
--   SELECT kyc_basic_info_sno, company_name, supp_code, status FROM dbo.kyc_basic_info WHERE supp_code LIKE 'SVK-%';
-- ============================================================
