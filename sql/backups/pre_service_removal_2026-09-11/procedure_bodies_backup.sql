-- ==== sp_approve_service_agreement ====
CREATE PROCEDURE dbo.sp_approve_service_agreement
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

        DECLARE @agreement_sno   INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT),
                @comments        VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by     VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action          VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');

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
            INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, is_active)
            VALUES (@agreement_sno, 'REJECTED', @approved_by, @comments, 'Y');

            UPDATE dbo.service_agreement
            SET status = 'R', current_approver_id = NULL
            WHERE agreement_sno = @agreement_sno;

            DROP TABLE #approval_stages;

            SELECT 'REJECTED' AS result, @agreement_sno AS agreement_sno, @approved_by AS rejected_by, GETDATE() AS rejected_on;
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

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, is_active)
        VALUES (@agreement_sno, 'APPROVED', @approved_by, @comments, 'Y');

        UPDATE dbo.service_agreement
        SET current_approver_id = @next_current_approver
        WHERE agreement_sno = @agreement_sno;

        DECLARE @auto_po_result VARCHAR(30) = NULL, @auto_po_basic_sno INT = NULL, @auto_po_no VARCHAR(50) = NULL,
                @auto_pr_basic_sno INT = NULL, @auto_pr_no VARCHAR(20) = NULL;

        IF @next_current_approver IS NULL
        BEGIN
            UPDATE dbo.service_agreement SET status = 'A' WHERE agreement_sno = @agreement_sno;

            -- Final approval: for a FIXED_RECURRING agreement, immediately
            -- issue the first billing cycle rather than waiting on the sweep
            -- — but ONLY if this agreement has never had a cycle issued
            -- before (a true first approval). A re-approval of an EDIT to an
            -- already-cycling agreement must not re-trigger this — cycles
            -- for it are already running via the hourly sweep, and issuing
            -- again here would double-bill the current period.
            IF NOT EXISTS (
                SELECT 1 FROM dbo.service_agreement_recurring_pr_log
                WHERE agreement_sno = @agreement_sno
            )
            BEGIN
                DECLARE @service_type_code VARCHAR(30), @period_start DATE;
                SELECT @service_type_code = st.service_type_code, @period_start = sa.period_start_date
                FROM dbo.service_agreement sa
                JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
                JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
                WHERE sa.agreement_sno = @agreement_sno;

                IF @service_type_code = 'FIXED_RECURRING'
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
                        -- Do not fail the approval itself — see file header.
                        SET @auto_po_result = 'ERROR: ' + ERROR_MESSAGE();
                    END CATCH
                END
            END
        END

        DROP TABLE #approval_stages;

        SELECT
            'SUCCESS'                                      AS result,
            @agreement_sno                                 AS agreement_sno,
            @approved_by                                    AS approved_by,
            GETDATE()                                        AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE')     AS next_approver,
            @auto_po_result                                    AS auto_po_result,
            @auto_po_basic_sno                                  AS auto_po_basic_sno,
            @auto_po_no                                          AS auto_po_no,
            @auto_pr_basic_sno                                    AS auto_pr_basic_sno,
            @auto_pr_no                                            AS auto_pr_no;

    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL
            DROP TABLE #approval_stages;

        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO

-- ==== sp_approve_service_vendor_kyc ====
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

-- ==== sp_nt_ApproveServiceBillRequest ====
CREATE PROCEDURE dbo.sp_nt_ApproveServiceBillRequest
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

        DECLARE @bill_request_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.bill_request_sno') AS INT),
                @comments         VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages  NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by      VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action           VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');

        IF @bill_request_sno IS NULL
        BEGIN
            RAISERROR('bill_request_sno is required.', 16, 1);
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

        IF NOT EXISTS (SELECT 1 FROM dbo.service_bill_request WHERE bill_request_sno = @bill_request_sno AND is_active = 'Y')
        BEGIN
            RAISERROR('Service bill request not found or inactive.', 16, 1);
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
            INSERT INTO dbo.service_bill_request_history (bill_request_sno, action_type, status_by, comment, is_active)
            VALUES (@bill_request_sno, 'REJECTED', @approved_by, @comments, 'Y');

            UPDATE dbo.service_bill_request
            SET status = 'R', current_approver_id = NULL
            WHERE bill_request_sno = @bill_request_sno;

            DROP TABLE #approval_stages;

            SELECT 'REJECTED' AS result, @bill_request_sno AS bill_request_sno, @approved_by AS rejected_by, GETDATE() AS rejected_on;
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

        INSERT INTO dbo.service_bill_request_history (bill_request_sno, action_type, status_by, comment, is_active)
        VALUES (@bill_request_sno, 'APPROVED', @approved_by, @comments, 'Y');

        UPDATE dbo.service_bill_request
        SET current_approver_id = @next_current_approver
        WHERE bill_request_sno = @bill_request_sno;

        DECLARE @auto_po_result VARCHAR(30) = NULL, @auto_po_basic_sno INT = NULL, @auto_po_no VARCHAR(50) = NULL,
                @auto_po_vendor_sno INT = NULL;

        IF @next_current_approver IS NULL
        BEGIN
            UPDATE dbo.service_bill_request SET status = 'A' WHERE bill_request_sno = @bill_request_sno;

            DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @service_sno INT, @vendor_sno INT,
                    @billing_period_start DATE, @billing_period_end DATE,
                    @ceiling_amount DECIMAL(18,2), @variance_tolerance_pct DECIMAL(5,2), @agreement_sno INT;

            SELECT @com_sno = sbr.com_sno, @div_sno = sbr.div_sno, @brn_sno = sbr.brn_sno, @dept_sno = sbr.dept_sno,
                   @service_sno = sbr.service_sno, @vendor_sno = sbr.vendor_sno,
                   @billing_period_start = sbr.billing_period_start, @billing_period_end = sbr.billing_period_end,
                   @agreement_sno = sbr.agreement_sno, @ceiling_amount = sa.ceiling_amount,
                   @variance_tolerance_pct = sa.variance_tolerance_pct
            FROM dbo.service_bill_request sbr
            JOIN dbo.service_agreement sa ON sa.agreement_sno = sbr.agreement_sno
            WHERE sbr.bill_request_sno = @bill_request_sno;

            SET @auto_po_vendor_sno = @vendor_sno;

            DECLARE @itemsJson NVARCHAR(MAX) = (
                SELECT service_sno, qty, uom_sno, unit_price, remarks
                FROM dbo.service_bill_request_item_details
                WHERE bill_request_sno = @bill_request_sno AND is_active = 'Y'
                FOR JSON PATH
            );

            DECLARE @poJson NVARCHAR(MAX) = (
                SELECT @com_sno AS com_sno, @div_sno AS div_sno, @brn_sno AS brn_sno, @dept_sno AS dept_sno,
                       @vendor_sno AS vendor_sno, 1 AS is_retrospective,
                       JSON_QUERY(@itemsJson) AS items, 'RECURRING' AS po_type,
                       @billing_period_start AS validity_from, @billing_period_end AS validity_to,
                       @ceiling_amount AS ceiling_amount, @variance_tolerance_pct AS variance_tolerance_pct,
                       @approved_by AS issued_by,
                       (N'Auto-issued Service PO — Service Bill Request ' + CAST(@bill_request_sno AS VARCHAR(10))
                        + N', against ceiling Service Agreement ' + CAST(@agreement_sno AS VARCHAR(10))) AS source_note,
                       (N'Variable Recurring service PO — Bill Request ' + CAST(@bill_request_sno AS VARCHAR(10))) AS purpose
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
            );

            BEGIN TRY
                EXEC dbo.sp_nt_DirectIssueServicePO
                    @jsonInput = @poJson, @silent = 1,
                    @out_result = @auto_po_result OUTPUT, @out_po_basic_sno = @auto_po_basic_sno OUTPUT, @out_po_no = @auto_po_no OUTPUT;

                IF @auto_po_basic_sno IS NOT NULL
                    UPDATE dbo.service_bill_request SET po_basic_sno = @auto_po_basic_sno WHERE bill_request_sno = @bill_request_sno;
            END TRY
            BEGIN CATCH
                -- Do not fail the approval itself — see file header of the
                -- original sp_nt_ApproveServiceBillRequest (23_..._redesign.sql).
                -- po_basic_sno stays NULL; retryable via
                -- sp_nt_RetryServiceBillRequestPOIssue.
                SET @auto_po_result = 'ERROR: ' + ERROR_MESSAGE();
            END CATCH
        END

        DROP TABLE #approval_stages;

        SELECT
            'SUCCESS'                                      AS result,
            @bill_request_sno                              AS bill_request_sno,
            @approved_by                                    AS approved_by,
            GETDATE()                                        AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE')     AS next_approver,
            @auto_po_result                                    AS auto_po_result,
            @auto_po_basic_sno                                  AS auto_po_basic_sno,
            @auto_po_no                                          AS auto_po_no,
            @auto_po_vendor_sno                                   AS auto_po_vendor_sno;

    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL
            DROP TABLE #approval_stages;

        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO

-- ==== sp_nt_ApproveServicePO ====
CREATE PROCEDURE dbo.sp_nt_ApproveServicePO
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

        DECLARE @po_basic_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT),
                @comments        VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by     VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action          VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');

        IF @po_basic_sno IS NULL
        BEGIN
            RAISERROR('po_basic_sno is required.', 16, 1);
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

        IF NOT EXISTS (SELECT 1 FROM dbo.po_request_info WHERE po_basic_sno = @po_basic_sno AND is_active = 'Y')
        BEGIN
            RAISERROR('Service PO not found or inactive.', 16, 1);
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
            INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
            VALUES (@po_basic_sno, 'REJECTED', @approved_by, @comments, 'Y');

            UPDATE dbo.po_request_info
            SET status = 'R', current_approver_id = NULL
            WHERE po_basic_sno = @po_basic_sno;

            DROP TABLE #approval_stages;

            SELECT 'REJECTED' AS result, @po_basic_sno AS po_basic_sno, @approved_by AS rejected_by, GETDATE() AS rejected_on;
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

        INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
        VALUES (@po_basic_sno, 'APPROVED', @approved_by, @comments, 'Y');

        UPDATE dbo.po_request_info
        SET current_approver_id = @next_current_approver
        WHERE po_basic_sno = @po_basic_sno;

        IF @next_current_approver IS NULL
        BEGIN
            UPDATE dbo.po_request_info SET status = 'A' WHERE po_basic_sno = @po_basic_sno;
        END

        DROP TABLE #approval_stages;

        SELECT
            'SUCCESS'                                      AS result,
            @po_basic_sno                                  AS po_basic_sno,
            @approved_by                                   AS approved_by,
            GETDATE()                                       AS approved_on,
            ISNULL(@next_current_approver, 'FINAL_STAGE')   AS next_approver;

    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL
            DROP TABLE #approval_stages;

        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO

-- ==== sp_nt_ApproveServiceVendorDailyEntry ====
CREATE PROCEDURE dbo.sp_nt_ApproveServiceVendorDailyEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @entry_sno    INT          = TRY_CAST(JSON_VALUE(@jsonInput, '$.entry_sno') AS INT);
    DECLARE @action       VARCHAR(20)  = JSON_VALUE(@jsonInput, '$.action');
    DECLARE @approved_by  VARCHAR(20)  = JSON_VALUE(@jsonInput, '$.approved_by');
    DECLARE @comments     VARCHAR(500) = JSON_VALUE(@jsonInput, '$.comments');

    IF @entry_sno IS NULL OR @approved_by IS NULL
        THROW 54160, 'entry_sno and approved_by are required.', 1;

    IF @action NOT IN ('Approve', 'Reject')
        THROW 54161, 'action must be Approve or Reject.', 1;

    DECLARE @current_status VARCHAR(20), @current_approver VARCHAR(20);
    SELECT @current_status = status, @current_approver = current_approver_id
    FROM dbo.service_vendor_daily_entry
    WHERE entry_sno = @entry_sno;

    IF @current_status IS NULL
        THROW 54162, 'Entry not found.', 1;

    IF @current_status <> 'PENDING_APPROVAL'
        THROW 54163, 'This entry is not awaiting approval (already actioned or consolidated).', 1;

    IF @current_approver IS NULL OR @current_approver <> @approved_by
        THROW 54164, 'You are not the assigned approver for this entry.', 1;

    IF @action = 'Reject' AND (@comments IS NULL OR LTRIM(RTRIM(@comments)) = '')
        THROW 54165, 'Comments are required when rejecting an entry.', 1;

    UPDATE dbo.service_vendor_daily_entry
    SET status = CASE WHEN @action = 'Approve' THEN 'PENDING' ELSE 'REJECTED' END,
        approved_by = @approved_by,
        approved_at = GETDATE(),
        approval_comments = @comments,
        current_approver_id = NULL
    WHERE entry_sno = @entry_sno;

    SELECT
        e.entry_sno, e.com_sno, e.div_sno, e.brn_sno, e.dept_sno,
        e.vendor_sno, k.company_name AS vendor_name,
        e.service_sno, sm.service_name,
        e.entry_date, e.qty, e.unit, um.uom_name AS unit_name, e.unit_price, e.total_amount,
        e.specification, e.remarks, e.receipt_doc_url, e.status,
        e.workflow_types_id, e.current_approver_id, e.approved_by, e.approved_at, e.approval_comments,
        e.created_by, e.created_date
    FROM dbo.service_vendor_daily_entry e
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = e.vendor_sno
    LEFT JOIN dbo.service_master sm ON sm.service_sno = e.service_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = e.unit
    WHERE e.entry_sno = @entry_sno;
END;
GO

-- ==== sp_nt_CancelServiceVendorDailyEntry ====
CREATE PROCEDURE dbo.sp_nt_CancelServiceVendorDailyEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @entry_sno   INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.entry_sno') AS INT);
    DECLARE @cancelled_by VARCHAR(20) = JSON_VALUE(@jsonInput, '$.cancelled_by');

    IF @entry_sno IS NULL OR @cancelled_by IS NULL
        THROW 54150, 'entry_sno and cancelled_by are required.', 1;

    UPDATE dbo.service_vendor_daily_entry
    SET status = 'CANCELLED'
    WHERE entry_sno = @entry_sno AND status = 'PENDING';

    IF @@ROWCOUNT = 0
        THROW 54151, 'Entry not found or is no longer PENDING (already consolidated or cancelled).', 1;

    SELECT 'SUCCESS' AS result, @entry_sno AS entry_sno;
END;
GO

-- ==== sp_nt_CreateRecurrenceCadenceRecords ====
CREATE PROCEDURE dbo.sp_nt_CreateRecurrenceCadenceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
        THROW 54001, N'Invalid JSON payload provided.', 1;

    DECLARE @cadence_code    VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.cadence_code'),
            @cadence_name    NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.cadence_name'),
            @interval_unit   VARCHAR(10)   = UPPER(JSON_VALUE(@jsonInput, '$.interval_unit')),
            @interval_value  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.interval_value') AS INT),
            @description     NVARCHAR(200) = JSON_VALUE(@jsonInput, '$.description'),
            @created_by      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @cadence_code IS NULL OR @cadence_name IS NULL OR @interval_unit IS NULL OR @interval_value IS NULL
        THROW 54002, N'cadence_code, cadence_name, interval_unit and interval_value are required.', 1;

    IF @interval_unit NOT IN ('DAY','MONTH')
        THROW 54003, N'interval_unit must be DAY or MONTH.', 1;

    IF @interval_value <= 0
        THROW 54004, N'interval_value must be positive.', 1;

    IF EXISTS (SELECT 1 FROM dbo.recurrence_cadence_master WHERE cadence_code = @cadence_code)
        THROW 54005, N'A recurrence cadence with this code already exists.', 1;

    INSERT INTO dbo.recurrence_cadence_master (cadence_code, cadence_name, interval_unit, interval_value, description, is_active, created_by)
    VALUES (@cadence_code, @cadence_name, @interval_unit, @interval_value, @description, 'Y', @created_by);

    SELECT SCOPE_IDENTITY() AS recurrence_cadence_sno, @cadence_code AS cadence_code, N'SUCCESS' AS status;
END;
GO

-- ==== sp_nt_CreateServiceAgreement ====
CREATE PROCEDURE dbo.sp_nt_CreateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @com_sno              INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno              INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno              INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno             INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @service_sno          INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @vendor_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @rate_amount          DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @rate_uom_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_uom_sno') AS INT);
        DECLARE @ceiling_amount       DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @variance_tolerance_pct DECIMAL(5,2)= TRY_CAST(JSON_VALUE(@jsonInput, '$.variance_tolerance_pct') AS DECIMAL(5,2));
        DECLARE @recurrence_cadence   VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.recurrence_cadence');
        DECLARE @recurrence_cadence_sno INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_cadence_sno') AS INT);
        DECLARE @po_generation_day    SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_generation_day') AS SMALLINT);
        DECLARE @notify_days_before   SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.notify_days_before') AS SMALLINT);
        DECLARE @period_start_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date      DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url    NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks              NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @created_by           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @service_sno IS NULL OR @created_by IS NULL
            THROW 53001, 'com_sno, div_sno, brn_sno, dept_sno, service_sno and created_by are required.', 1;

        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 53003, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;

        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 53004, 'agreement_doc_url is required — upload the agreement document before submitting.', 1;

        -- ── Resolve recurrence cadence against the master (mandatory) ──────
        IF @recurrence_cadence_sno IS NULL AND @recurrence_cadence IS NOT NULL
            SELECT @recurrence_cadence_sno = recurrence_cadence_sno
            FROM dbo.recurrence_cadence_master
            WHERE cadence_code = @recurrence_cadence AND is_active = 'Y';

        IF @recurrence_cadence_sno IS NULL
            THROW 53020, 'recurrence_cadence_sno (or a matching recurrence_cadence code) is required — see sp_nt_GetRecurrenceCadenceRecords for valid options.', 1;

        DECLARE @interval_unit VARCHAR(10);
        SELECT @recurrence_cadence = cadence_code, @interval_unit = interval_unit
        FROM dbo.recurrence_cadence_master
        WHERE recurrence_cadence_sno = @recurrence_cadence_sno AND is_active = 'Y';

        IF @recurrence_cadence IS NULL
            THROW 53021, 'recurrence_cadence_sno does not reference an active recurrence cadence.', 1;

        DECLARE @service_type_code VARCHAR(30), @is_recurring BIT;
        SELECT @service_type_code = st.service_type_code,
               @is_recurring      = sm.is_recurring
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';

        IF @service_type_code IS NULL
            THROW 53005, 'Unknown or inactive service_sno.', 1;

        IF ISNULL(@is_recurring, 0) = 0 OR @service_type_code NOT IN ('FIXED_RECURRING', 'VARIABLE_RECURRING')
            THROW 53006, 'service_sno must reference an active Fixed Recurring or Variable Recurring, recurring service.', 1;

        -- Branch by billing pattern: Fixed Recurring authorizes a rate,
        -- Variable Recurring authorizes a ceiling + tolerance.
        IF @service_type_code = 'FIXED_RECURRING'
        BEGIN
            IF @rate_amount IS NULL OR @rate_amount <= 0
                THROW 53002, 'rate_amount must be a positive amount.', 1;

            -- po_generation_day only means something for a MONTH-unit cadence
            -- (a DAY-unit cadence like FIFTEEN_DAYS counts elapsed days from
            -- period_start_date, not a calendar day-of-month) — required
            -- there so every new agreement has an explicit trigger day
            -- rather than silently depending on the anniversary fallback.
            IF @interval_unit = 'MONTH'
            BEGIN
                IF @po_generation_day IS NULL OR @po_generation_day NOT BETWEEN 1 AND 31
                    THROW 53022, 'po_generation_day (1-31) is required for a Fixed Recurring agreement on a monthly-family cadence.', 1;
            END
            ELSE
                SET @po_generation_day = NULL;

            IF @notify_days_before IS NOT NULL AND @notify_days_before < 0
                THROW 53023, 'notify_days_before must not be negative.', 1;
        END
        ELSE -- VARIABLE_RECURRING
        BEGIN
            IF @ceiling_amount IS NULL OR @ceiling_amount <= 0
                THROW 53010, 'ceiling_amount must be a positive amount for a Variable Recurring agreement.', 1;
            IF @variance_tolerance_pct IS NULL
                THROW 53011, 'variance_tolerance_pct is required for a Variable Recurring agreement.', 1;

            -- po_generation_day still doesn't apply — no auto-PO date for
            -- this type. notify_days_before now DOES apply (this is the
            -- change from v5): the bell reminds the user before the next
            -- expected billing cycle so they remember to submit a Service
            -- Bill Request. Validated the same way as Fixed Recurring's.
            SET @po_generation_day = NULL;

            IF @notify_days_before IS NOT NULL AND @notify_days_before < 0
                THROW 53023, 'notify_days_before must not be negative.', 1;
        END

        -- ── Resolve the ServiceAgreement workflow for this org scope ───────
        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);

        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceAgreement';

        IF @workflow_types_id IS NULL
            THROW 53007, 'No ServiceAgreement workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key] = '0' AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 53008, 'No approver found for the first stage of the ServiceAgreement workflow.', 1;

        -- ── Number: AGR-YYYY-NNNN, same scheme as ServicePO's SVO-YYYY-NNNN ─
        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(agreement_no, 4) AS INT)), 0) + 1
        FROM dbo.service_agreement WITH (UPDLOCK, HOLDLOCK)
        WHERE agreement_no LIKE 'AGR-' + @year + '-%';
        DECLARE @agreement_no VARCHAR(30) = 'AGR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.service_agreement (
            agreement_no, com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
            rate_amount, rate_uom_sno, ceiling_amount, variance_tolerance_pct,
            recurrence_cadence, recurrence_cadence_sno, po_generation_day, notify_days_before,
            period_start_date, period_end_date,
            agreement_doc_url, remarks, workflow_types_id, current_approver_id, status,
            is_active, created_by
        )
        VALUES (
            @agreement_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @service_sno, @vendor_sno,
            @rate_amount, @rate_uom_sno, @ceiling_amount, @variance_tolerance_pct,
            @recurrence_cadence, @recurrence_cadence_sno, @po_generation_day, @notify_days_before,
            @period_start_date, @period_end_date,
            @agreement_doc_url, @remarks, @workflow_types_id, @first_approver, 'P',
            'Y', @created_by
        );

        DECLARE @agreement_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, is_active)
        VALUES (@agreement_sno, 'SUBMITTED', @created_by, NULL, 'Y');

        COMMIT TRANSACTION;

        SELECT
            @agreement_sno AS agreement_sno,
            @agreement_no  AS agreement_no,
            'SUCCESS'      AS result,
            N'Service agreement submitted for approval.' AS message;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==== sp_nt_CreateServiceBillRequest ====
CREATE PROCEDURE dbo.sp_nt_CreateServiceBillRequest
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @agreement_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
        DECLARE @billing_period_start DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.billing_period_start') AS DATE);
        DECLARE @billing_period_end   DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.billing_period_end') AS DATE);
        DECLARE @invoice_no           VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.invoice_no');
        DECLARE @invoice_date         DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_date') AS DATE);
        DECLARE @invoice_doc_url      NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.invoice_doc_url');
        DECLARE @remarks              NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @created_by           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
        DECLARE @items                NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');

        IF @agreement_sno IS NULL OR @created_by IS NULL
            THROW 56010, 'agreement_sno and created_by are required.', 1;

        IF @billing_period_start IS NULL OR @billing_period_end IS NULL OR @billing_period_end < @billing_period_start
            THROW 56011, 'billing_period_start and billing_period_end are required, and the period must not end before it starts.', 1;

        IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
            THROW 56012, 'At least one item (service, qty, unit_price) is required.', 1;

        IF @invoice_doc_url IS NULL OR LTRIM(RTRIM(@invoice_doc_url)) = ''
            THROW 56013, 'invoice_doc_url is required — upload the invoice document before submitting.', 1;

        DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @service_sno INT, @vendor_sno INT,
                @ceiling_amount DECIMAL(18,2), @variance_tolerance_pct DECIMAL(5,2), @agr_status CHAR(1),
                @period_end DATE, @service_type_code VARCHAR(30);

        SELECT @com_sno = sa.com_sno, @div_sno = sa.div_sno, @brn_sno = sa.brn_sno, @dept_sno = sa.dept_sno,
               @service_sno = sa.service_sno, @vendor_sno = sa.vendor_sno,
               @ceiling_amount = sa.ceiling_amount, @variance_tolerance_pct = sa.variance_tolerance_pct,
               @agr_status = sa.status, @period_end = sa.period_end_date, @service_type_code = st.service_type_code
        FROM dbo.service_agreement sa
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sa.agreement_sno = @agreement_sno;

        IF @agr_status IS NULL
            THROW 56014, 'Unknown agreement_sno.', 1;
        IF @service_type_code <> 'VARIABLE_RECURRING'
            THROW 56015, 'agreement_sno must reference a Variable Recurring ceiling agreement.', 1;
        IF @agr_status <> 'A'
            THROW 56016, 'The ceiling Service Agreement must be Approved before a bill can be submitted against it.', 1;
        IF CAST(GETDATE() AS DATE) > @period_end
            THROW 56017, 'The ceiling Service Agreement has expired.', 1;

        DECLARE @lineItems TABLE (service_sno INT, qty DECIMAL(18,4), uom_sno INT, unit_price DECIMAL(18,2), amount DECIMAL(18,2), remarks VARCHAR(500));
        INSERT INTO @lineItems (service_sno, qty, uom_sno, unit_price, amount, remarks)
        SELECT
            TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 1),
            TRY_CAST(JSON_VALUE(j.value, '$.uom_sno') AS INT),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.unit_price') AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 1) * ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.unit_price') AS DECIMAL(18,2)), 0),
            JSON_VALUE(j.value, '$.remarks')
        FROM OPENJSON(@items) j;

        IF EXISTS (SELECT 1 FROM @lineItems WHERE unit_price <= 0 OR qty <= 0)
            THROW 56021, 'Every item requires a positive qty and unit_price.', 1;

        DECLARE @invoice_amount DECIMAL(18,2);
        SELECT @invoice_amount = SUM(amount) FROM @lineItems;

        IF @ceiling_amount IS NOT NULL AND @invoice_amount > @ceiling_amount * (1 + ISNULL(@variance_tolerance_pct, 0) / 100.0)
            THROW 56018, 'Total item amount exceeds the ceiling agreement''s authorized ceiling plus its variance tolerance.', 1;

        -- ── Resolve the ServiceBillRequest workflow for this org scope ─────
        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);

        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceBillRequest';

        IF @workflow_types_id IS NULL
            THROW 56019, 'No ServiceBillRequest workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key] = '0' AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 56020, 'No approver found for the first stage of the ServiceBillRequest workflow.', 1;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(request_no, 4) AS INT)), 0) + 1
        FROM dbo.service_bill_request WITH (UPDLOCK, HOLDLOCK)
        WHERE request_no LIKE 'SBR-' + @year + '-%';
        DECLARE @request_no VARCHAR(30) = 'SBR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.service_bill_request (
            request_no, agreement_sno, com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
            billing_period_start, billing_period_end, invoice_no, invoice_date, invoice_amount, invoice_doc_url,
            remarks, workflow_types_id, current_approver_id, status, is_active, created_by
        )
        VALUES (
            @request_no, @agreement_sno, @com_sno, @div_sno, @brn_sno, @dept_sno, @service_sno, @vendor_sno,
            @billing_period_start, @billing_period_end, @invoice_no, @invoice_date, @invoice_amount, @invoice_doc_url,
            @remarks, @workflow_types_id, @first_approver, 'P', 'Y', @created_by
        );

        DECLARE @bill_request_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.service_bill_request_item_details (bill_request_sno, service_sno, qty, uom_sno, unit_price, amount, remarks, created_by)
        SELECT @bill_request_sno, service_sno, qty, uom_sno, unit_price, amount, remarks, @created_by
        FROM @lineItems;

        INSERT INTO dbo.service_bill_request_history (bill_request_sno, action_type, status_by, comment, is_active)
        VALUES (@bill_request_sno, 'SUBMITTED', @created_by, NULL, 'Y');

        COMMIT TRANSACTION;

        SELECT
            @bill_request_sno AS bill_request_sno,
            @request_no       AS request_no,
            @invoice_amount   AS invoice_amount,
            'SUCCESS'         AS result,
            N'Service bill request submitted for approval.' AS message;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==== sp_nt_CreateServiceMasterSupplierMapping ====
CREATE PROCEDURE dbo.sp_nt_CreateServiceMasterSupplierMapping
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
        THROW 60001, N'Invalid JSON payload provided.', 1;

    DECLARE @service_sno        INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT),
            @kyc_basic_info_sno INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno') AS INT),
            @created_by         VARCHAR(20) = JSON_VALUE(@jsonInput, '$.created_by');

    IF @service_sno IS NULL OR @kyc_basic_info_sno IS NULL
        THROW 60002, N'service_sno and kyc_basic_info_sno are required.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.service_master WHERE service_sno = @service_sno AND is_active = 'Y')
        THROW 60003, N'service_sno does not reference an active service.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = @kyc_basic_info_sno AND status = 'A' AND is_active = 'Y')
        THROW 60004, N'kyc_basic_info_sno does not reference an approved, active vendor.', 1;

    IF EXISTS (SELECT 1 FROM dbo.service_master_supplier WHERE service_sno = @service_sno AND kyc_basic_info_sno = @kyc_basic_info_sno AND is_active = 'Y')
        THROW 60005, N'This supplier is already mapped to this service.', 1;

    INSERT INTO dbo.service_master_supplier (service_sno, kyc_basic_info_sno, is_active, created_by)
    VALUES (@service_sno, @kyc_basic_info_sno, 'Y', @created_by);

    SELECT SCOPE_IDENTITY() AS mapping_sno, N'SUCCESS' AS status, N'Supplier mapped to service.' AS message;
END;
GO

-- ==== sp_nt_CreateServicePO ====
CREATE PROCEDURE dbo.sp_nt_CreateServicePO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @pr_basic_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT);
        DECLARE @vendor_sno             INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @service_type_code      VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.service_type_code');
        DECLARE @po_type                VARCHAR(20)   = ISNULL(JSON_VALUE(@jsonInput, '$.po_type'), 'ONE_TIME');
        DECLARE @validity_from          DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.validity_from') AS DATE);
        DECLARE @validity_to            DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.validity_to') AS DATE);
        DECLARE @ceiling_amount         DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @variance_tolerance_pct DECIMAL(5,2)  = TRY_CAST(JSON_VALUE(@jsonInput, '$.variance_tolerance_pct') AS DECIMAL(5,2));
        DECLARE @is_retrospective       BIT           = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.is_retrospective') AS BIT), 0);
        DECLARE @parent_blanket_po_sno  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.parent_blanket_po_sno') AS INT);
        DECLARE @delivery_address       VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.delivery_address');
        DECLARE @terms_conditions       VARCHAR(MAX)  = JSON_VALUE(@jsonInput, '$.terms_conditions');
        DECLARE @purpose                VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.purpose');
        DECLARE @com_sno                INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno                INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno                INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno               INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @budget_sno             INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.budget_sno') AS INT);
        DECLARE @budget_code            VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.budget_code');
        DECLARE @created_by             VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
        DECLARE @items                  NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');

        IF @vendor_sno IS NULL OR @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @created_by IS NULL
            THROW 52001, 'vendor_sno, com_sno, div_sno, brn_sno, dept_sno and created_by are required.', 1;

        IF @pr_basic_sno IS NULL AND @is_retrospective = 0
            THROW 52002, 'pr_basic_sno is required unless is_retrospective is set (Type 3 call-off).', 1;

        IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
            THROW 52003, 'At least one item is required.', 1;

        DECLARE @service_type_sno INT, @requires_ceiling BIT, @requires_tolerance BIT;
        SELECT @service_type_sno = service_type_sno, @requires_ceiling = requires_ceiling_amount,
               @requires_tolerance = requires_variance_tolerance
        FROM dbo.service_type_master
        WHERE service_type_code = @service_type_code AND is_active = 'Y';

        IF @service_type_sno IS NULL
            THROW 52004, 'Unknown or inactive service_type_code.', 1;

        -- ── PO grouping: same PR + same vendor always shares one PO ────────
        DECLARE @po_basic_sno INT = NULL;
        IF @pr_basic_sno IS NOT NULL
            SELECT @po_basic_sno = po_basic_sno
            FROM dbo.po_request_info
            WHERE pr_basic_sno = @pr_basic_sno AND vendor_sno = @vendor_sno AND is_active = 'Y';

        DECLARE @po_no VARCHAR(50);
        DECLARE @is_new_po BIT = 0;
        DECLARE @is_direct_issue BIT = 0;

        IF @po_basic_sno IS NULL
        BEGIN
            SET @is_new_po = 1;

            -- VARIABLE_RECURRING authorization gate — only for a genuinely
            -- new, non-retrospective PO (a call-off against an already
            -- authorized STANDING PO goes through sp_nt_CreateCallOffPO
            -- instead, and never reaches this branch). Requires an Approved,
            -- in-period service_agreement covering this org scope and at
            -- least one of the PO's item service_sno values; sources
            -- ceiling/tolerance from it rather than the client payload —
            -- same "server is the authority" pattern usp_InsertPurchaseRequest
            -- v3 already uses for FIXED_RECURRING rate.
            IF @service_type_code = 'VARIABLE_RECURRING' AND @is_retrospective = 0
            BEGIN
                DECLARE @authorizing_agreement_sno INT;
                SELECT TOP 1 @authorizing_agreement_sno = sa.agreement_sno,
                       @ceiling_amount = sa.ceiling_amount,
                       @variance_tolerance_pct = sa.variance_tolerance_pct
                FROM OPENJSON(@items) j
                CROSS APPLY (SELECT TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT) AS item_service_sno) parsed
                JOIN dbo.service_agreement sa
                    ON sa.service_sno = parsed.item_service_sno
                   AND sa.com_sno = @com_sno AND sa.div_sno = @div_sno
                   AND sa.brn_sno = @brn_sno AND sa.dept_sno = @dept_sno
                   AND sa.status  = 'A'
                   AND CAST(GETDATE() AS DATE) BETWEEN sa.period_start_date AND sa.period_end_date
                ORDER BY sa.agreement_sno DESC;

                IF @authorizing_agreement_sno IS NULL
                    THROW 52009, 'No approved, in-period Variable Recurring Service Agreement found authorizing this org scope + service. Create and approve one before raising this Service PO.', 1;
            END

            IF @requires_ceiling = 1 AND @ceiling_amount IS NULL
                THROW 52005, 'ceiling_amount is required for this service type.', 1;

            IF @requires_tolerance = 1 AND @variance_tolerance_pct IS NULL
                THROW 52010, 'variance_tolerance_pct is required for this service type.', 1;

            DECLARE @workflow_types_id INT, @first_approver VARCHAR(20), @po_status CHAR(1);

            SELECT @workflow_types_id = wt.workflow_types_id
            FROM dbo.workflow_types wt
            INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
            WHERE wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno AND wt.com_sno = @com_sno AND wt.div_sno = @div_sno
              AND awm.entity_type = 'ServicePO';

            IF @workflow_types_id IS NULL
            BEGIN
                -- No ServicePO workflow configured for this org scope: issue
                -- directly rather than throwing (spec §7). @first_approver
                -- and @workflow_types_id both stay NULL — same shape
                -- sp_nt_CreateCallOffPO uses for an auto-approved call-off.
                SET @first_approver  = NULL;
                SET @po_status       = 'A';
                SET @is_direct_issue = 1;
            END
            ELSE
            BEGIN
                SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
                FROM dbo.vw_workflow_stages AS ws
                CROSS APPLY OPENJSON(ws.stages_json) AS s
                CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
                WHERE ws.workflow_types_id = @workflow_types_id
                  AND s.[key] = '0' AND s2.[key] = '0';

                IF @first_approver IS NULL
                    THROW 52007, 'No approver found for the first stage of the ServicePO workflow.', 1;

                SET @po_status = 'P';
            END

            DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
            DECLARE @seq  INT;
            SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
            FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
            WHERE po_df_no LIKE 'SVO-' + @year + '-%';
            SET @po_no = 'SVO-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

            INSERT INTO dbo.po_request_info (
                vendor_sno, brn_sno, dept_sno, com_sno, div_sno,
                budget_sno, budget_code, pr_basic_sno,
                po_date, required_date, purpose, terms_conditions, delivery_address,
                is_active, workflow_types_id, current_approver_id, status, po_df_no,
                po_type, validity_from, validity_to, ceiling_amount, variance_tolerance_pct,
                consumed_amount, service_type_sno, is_retrospective, parent_blanket_po_sno
            )
            VALUES (
                @vendor_sno, @brn_sno, @dept_sno, @com_sno, @div_sno,
                @budget_sno, @budget_code, @pr_basic_sno,
                CAST(GETDATE() AS DATE), @validity_to, @purpose, @terms_conditions, @delivery_address,
                'Y', @workflow_types_id, @first_approver, @po_status, @po_no,
                @po_type, @validity_from, @validity_to, @ceiling_amount, @variance_tolerance_pct,
                0, @service_type_sno, @is_retrospective, @parent_blanket_po_sno
            );

            SET @po_basic_sno = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            SELECT @po_no = po_df_no FROM dbo.po_request_info WHERE po_basic_sno = @po_basic_sno;
        END

        INSERT INTO dbo.po_item_details (
            po_basic_sno, pr_item_sno, service_sno, prod_name, specification,
            qty, unit, unit_name, agreed_unit_price, total_cost, discount_pct, tax_pct, net_cost,
            remarks, po_section, created_by, created_date, is_active
        )
        SELECT
            @po_basic_sno,
            TRY_CAST(JSON_VALUE(j.value, '$.pr_item_sno') AS INT),
            TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT),
            sm.service_name,
            ISNULL(JSON_VALUE(j.value, '$.specification'), ''),
            TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)),
            TRY_CAST(JSON_VALUE(j.value, '$.unit') AS INT),
            um.uom_name,
            TRY_CAST(JSON_VALUE(j.value, '$.agreed_unit_price') AS DECIMAL(18,4)),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.total_cost') AS DECIMAL(18,4)),
                   ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 0) * ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.agreed_unit_price') AS DECIMAL(18,4)), 0)),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.discount_pct') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.tax_pct') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.net_cost') AS DECIMAL(18,4)),
                   ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 0) * ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.agreed_unit_price') AS DECIMAL(18,4)), 0)),
            JSON_VALUE(j.value, '$.remarks'),
            'SERVICE',
            -- po_item_details.is_active uses '1'/'0' in this DB (unlike
            -- po_request_info's 'Y'/'N') — see 07_po_service_extensions.sql's
            -- note on this same line.
            @created_by, GETDATE(), '1'
        FROM OPENJSON(@items) j
        LEFT JOIN dbo.service_master sm ON sm.service_sno = TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT)
        LEFT JOIN dbo.uom_master um     ON um.uom_sno = TRY_CAST(JSON_VALUE(j.value, '$.unit') AS INT);

        DECLARE @items_inserted INT = @@ROWCOUNT;
        IF @items_inserted = 0
            THROW 52008, 'No items were inserted. Check that items array is valid and non-empty.', 1;

        COMMIT TRANSACTION;

        SELECT
            @po_basic_sno     AS po_basic_sno,
            @po_no            AS po_no,
            @is_new_po        AS is_new_po,
            @is_direct_issue  AS is_direct_issue,
            @items_inserted   AS items_inserted,
            'SUCCESS'         AS result;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==== sp_nt_CreateServiceRecords ====
CREATE PROCEDURE dbo.sp_nt_CreateServiceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @service_name             NVARCHAR(150) = JSON_VALUE(@jsonInput, '$.service_name'),
            @service_code             VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.service_code'),
            @service_type_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_type_sno') AS INT),
            @default_uom_sno          INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.default_uom_sno') AS INT),
            @default_product_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.default_product_sno') AS INT),
            @sac_code                 VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.sac_code'),
            @is_recurring             BIT           = ISNULL(JSON_VALUE(@jsonInput, '$.is_recurring'), 0),
            @recurrence_cadence       VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.recurrence_cadence'),
            @recurrence_interval_days INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_interval_days') AS INT),
            @description              NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.description'),
            @created_by               VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @service_name IS NULL OR @service_code IS NULL OR @service_type_sno IS NULL
    BEGIN
        THROW 50002, N'service_name, service_code and service_type_sno are required.', 1;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.service_type_master WHERE service_type_sno = @service_type_sno AND is_active = 'Y')
    BEGIN
        THROW 50003, N'service_type_sno does not reference an active service type.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.service_master WHERE service_code = @service_code)
    BEGIN
        THROW 50004, N'A service with this code already exists.', 1;
        RETURN;
    END;

    IF @is_recurring = 1 AND @recurrence_cadence IS NULL
    BEGIN
        THROW 50005, N'recurrence_cadence is required when is_recurring is set.', 1;
        RETURN;
    END;

    IF @default_product_sno IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.product_master WHERE prod_sno = @default_product_sno AND prod_active = 'Y')
    BEGIN
        THROW 50006, N'default_product_sno does not reference an active product.', 1;
        RETURN;
    END;

    INSERT INTO dbo.service_master (
        service_name, service_code, service_type_sno, default_uom_sno, sac_code,
        is_recurring, recurrence_cadence, recurrence_interval_days, description,
        default_product_sno, is_active, created_by
    )
    VALUES (
        @service_name, @service_code, @service_type_sno, @default_uom_sno, @sac_code,
        @is_recurring, @recurrence_cadence, @recurrence_interval_days, @description,
        @default_product_sno, 'Y', @created_by
    );

    SELECT SCOPE_IDENTITY() AS service_sno,
           @service_code    AS service_code,
           N'SUCCESS'       AS status,
           N'Service created successfully.' AS message;
END;
GO

-- ==== sp_nt_CreateServiceTypeRecords ====
CREATE PROCEDURE dbo.sp_nt_CreateServiceTypeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @service_type_code           VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.service_type_code'),
            @service_type_name           NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.service_type_name'),
            @requires_ceiling_amount     BIT           = ISNULL(JSON_VALUE(@jsonInput, '$.requires_ceiling_amount'), 0),
            @requires_variance_tolerance BIT           = ISNULL(JSON_VALUE(@jsonInput, '$.requires_variance_tolerance'), 0),
            @created_by                  VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @service_type_code IS NULL OR @service_type_name IS NULL
    BEGIN
        THROW 50002, N'service_type_code and service_type_name are required.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.service_type_master WHERE service_type_code = @service_type_code)
    BEGIN
        THROW 50003, N'A service type with this code already exists.', 1;
        RETURN;
    END;

    INSERT INTO dbo.service_type_master (
        service_type_code, service_type_name, requires_ceiling_amount, requires_variance_tolerance, is_active, created_by
    )
    VALUES (
        @service_type_code, @service_type_name, @requires_ceiling_amount, @requires_variance_tolerance, 'Y', @created_by
    );

    SELECT SCOPE_IDENTITY()   AS service_type_sno,
           @service_type_code AS service_type_code,
           N'SUCCESS'         AS status,
           N'Service type created successfully.' AS message;
END;
GO

-- ==== sp_nt_CreateServiceVendorDailyEntry ====
CREATE PROCEDURE dbo.sp_nt_CreateServiceVendorDailyEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
    DECLARE @div_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
    DECLARE @brn_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
    DECLARE @dept_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
    DECLARE @vendor_sno     INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    DECLARE @service_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
    DECLARE @entry_date     DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.entry_date') AS DATE);
    DECLARE @qty            DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4));
    DECLARE @unit           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.unit') AS INT);
    DECLARE @unit_price     DECIMAL(18,4) = TRY_CAST(JSON_VALUE(@jsonInput, '$.unit_price') AS DECIMAL(18,4));
    DECLARE @specification  NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.specification');
    DECLARE @remarks        NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
    DECLARE @receipt_doc_url NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.receipt_doc_url');
    DECLARE @created_by     VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
       OR @vendor_sno IS NULL OR @service_sno IS NULL OR @entry_date IS NULL OR @created_by IS NULL
        THROW 54100, 'com_sno, div_sno, brn_sno, dept_sno, vendor_sno, service_sno, entry_date and created_by are required.', 1;

    IF @qty IS NULL OR @qty <= 0
        THROW 54102, 'qty must be greater than 0.', 1;

    IF @unit_price IS NULL OR @unit_price < 0
        THROW 54103, 'unit_price is required and cannot be negative.', 1;

    IF @receipt_doc_url IS NULL OR LTRIM(RTRIM(@receipt_doc_url)) = ''
        THROW 54104, 'receipt_doc_url is required — upload today''s receipt/bill before submitting.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND st.service_type_code = 'VENDOR_BILL' AND sm.is_active = 'Y'
    )
        THROW 54101, 'service_sno must reference an active Vendor-Bill-Driven service.', 1;

    -- Mandatory per-entry approval workflow lookup (mirrors
    -- sp_nt_CreateServicePO's entity_type join; unlike ServicePO's "no
    -- config -> direct issue" fallback, this hard-throws when unconfigured
    -- — approval on every purchase is the explicit requirement here).
    DECLARE @workflow_types_id   INT;
    DECLARE @first_approver_id   VARCHAR(20);

    SELECT @workflow_types_id = wt.workflow_types_id
    FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
      AND awm.entity_type = 'ServiceVendorEntry' AND awm.is_active = 'Y' AND wt.is_active = 'Y';

    IF @workflow_types_id IS NULL
        THROW 54105, 'No ServiceVendorEntry approval workflow configured for this company/division/branch/department. Configure it in Approval Workflow Manager before logging purchases.', 1;

    SELECT @first_approver_id = JSON_VALUE(s2.value, '$.approver_ecno')
    FROM dbo.vw_workflow_stages AS ws
    CROSS APPLY OPENJSON(ws.stages_json) AS s
    CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
    WHERE ws.workflow_types_id = @workflow_types_id AND s.[key] = '0' AND s2.[key] = '0';

    IF @first_approver_id IS NULL
        THROW 54106, 'No approver found for the first stage of the ServiceVendorEntry workflow.', 1;

    DECLARE @total_amount DECIMAL(18,4) = @qty * @unit_price;

    INSERT INTO dbo.service_vendor_daily_entry (
        com_sno, div_sno, brn_sno, dept_sno, vendor_sno, service_sno,
        entry_date, qty, unit, unit_price, total_amount,
        specification, remarks, receipt_doc_url, status,
        workflow_types_id, current_approver_id,
        created_by, created_date, is_active
    )
    VALUES (
        @com_sno, @div_sno, @brn_sno, @dept_sno, @vendor_sno, @service_sno,
        @entry_date, @qty, @unit, @unit_price, @total_amount,
        @specification, @remarks, @receipt_doc_url, 'PENDING_APPROVAL',
        @workflow_types_id, @first_approver_id,
        @created_by, GETDATE(), 'Y'
    );

    DECLARE @entry_sno INT = SCOPE_IDENTITY();

    SELECT
        e.entry_sno, e.com_sno, e.div_sno, e.brn_sno, e.dept_sno,
        e.vendor_sno, k.company_name AS vendor_name,
        e.service_sno, sm.service_name,
        e.entry_date, e.qty, e.unit, um.uom_name AS unit_name, e.unit_price, e.total_amount,
        e.specification, e.remarks, e.receipt_doc_url, e.status,
        e.workflow_types_id, e.current_approver_id,
        e.created_by, e.created_date
    FROM dbo.service_vendor_daily_entry e
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = e.vendor_sno
    LEFT JOIN dbo.service_master sm ON sm.service_sno = e.service_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = e.unit
    WHERE e.entry_sno = @entry_sno;
END;
GO

-- ==== sp_nt_CreateServiceVendorKyc ====
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
        DECLARE @document           NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.document');
        DECLARE @remarks            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @created_by         VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

        -- GST-fetch-derived (optional — only present when the caller applied
        -- an auto-fetched result before submitting)
        DECLARE @legal_name       NVARCHAR(200) = JSON_VALUE(@jsonInput, '$.legal_name');
        DECLARE @trade_name       NVARCHAR(200) = JSON_VALUE(@jsonInput, '$.trade_name');
        DECLARE @gst_status       VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.gst_status');
        DECLARE @gst_blk_status   VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.gst_blk_status');
        DECLARE @date_of_reg      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.date_of_reg');

        -- Bank details (required, mirrors goods-KYC's BANK_REQUIRED set)
        DECLARE @ac_holder_name   NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.ac_holder_name');
        DECLARE @ac_number        VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.ac_number');
        DECLARE @ac_type          VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.ac_type');
        DECLARE @ifsc             VARCHAR(15)   = JSON_VALUE(@jsonInput, '$.ifsc');
        DECLARE @bank_name        NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.bank_name');
        DECLARE @bank_branch_name NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.bank_branch_name');
        DECLARE @bank_address     NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.bank_address');

        DECLARE @preferred_payment_mode VARCHAR(30) = JSON_VALUE(@jsonInput, '$.preferred_payment_mode');

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @created_by IS NULL
            THROW 58001, 'com_sno, div_sno, brn_sno, dept_sno and created_by are required.', 1;

        IF @company_name IS NULL OR LTRIM(RTRIM(@company_name)) = ''
            THROW 58002, 'company_name is required.', 1;

        IF @contact_person IS NULL OR LTRIM(RTRIM(@contact_person)) = ''
            THROW 58003, 'contact_person is required.', 1;

        IF @mobile_number IS NULL OR LTRIM(RTRIM(@mobile_number)) = ''
            THROW 58004, 'mobile_number is required.', 1;

        IF @email IS NULL OR LTRIM(RTRIM(@email)) = ''
            THROW 58005, 'email is required.', 1;

        IF @business_type IS NULL OR LTRIM(RTRIM(@business_type)) = ''
            THROW 58006, 'business_type is required.', 1;

        IF @pan_no IS NULL OR LTRIM(RTRIM(@pan_no)) = ''
            THROW 58007, 'pan_no is required.', 1;

        IF @ac_holder_name IS NULL OR LTRIM(RTRIM(@ac_holder_name)) = ''
           OR @ac_number IS NULL OR LTRIM(RTRIM(@ac_number)) = ''
           OR @ac_type IS NULL OR LTRIM(RTRIM(@ac_type)) = ''
           OR @ifsc IS NULL OR LTRIM(RTRIM(@ifsc)) = ''
           OR @bank_name IS NULL OR LTRIM(RTRIM(@bank_name)) = ''
           OR @bank_branch_name IS NULL OR LTRIM(RTRIM(@bank_branch_name)) = ''
           OR @bank_address IS NULL OR LTRIM(RTRIM(@bank_address)) = ''
            THROW 58010, 'Bank account details (holder name, account number, account type, IFSC, bank name, branch, address) are required.', 1;

        -- ── Resolve the ServiceVendorKYC workflow for this org scope ───────
        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);

        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceVendorKYC';

        IF @workflow_types_id IS NULL
            THROW 58008, 'No ServiceVendorKYC workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key] = '0' AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 58009, 'No approver found for the first stage of the ServiceVendorKYC workflow.', 1;

        INSERT INTO dbo.service_vendor_kyc (
            com_sno, div_sno, brn_sno, dept_sno, company_name, contact_person, email, mobile_number,
            business_type, is_gst_avail, gst_no, is_msme_avail, msme_no, pan_no, supplier_cat_code,
            document, remarks, workflow_types_id, current_approver_id, status, is_active, created_by,
            legal_name, trade_name, gst_status, gst_blk_status, date_of_reg,
            ac_holder_name, ac_number, ac_type, ifsc, bank_name, bank_branch_name, bank_address,
            preferred_payment_mode
        )
        VALUES (
            @com_sno, @div_sno, @brn_sno, @dept_sno, @company_name, @contact_person, @email, @mobile_number,
            @business_type, @is_gst_avail, @gst_no, @is_msme_avail, @msme_no, @pan_no, @supplier_cat_code,
            @document, @remarks, @workflow_types_id, @first_approver, 'P', 'Y', @created_by,
            @legal_name, @trade_name, @gst_status, @gst_blk_status, @date_of_reg,
            @ac_holder_name, @ac_number, @ac_type, @ifsc, @bank_name, @bank_branch_name, @bank_address,
            @preferred_payment_mode
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
GO

-- ==== sp_nt_DirectIssueServicePO ====
CREATE PROCEDURE dbo.sp_nt_DirectIssueServicePO
    @jsonInput NVARCHAR(MAX),
    @silent BIT = 0,
    @out_result VARCHAR(30) = NULL OUTPUT,
    @out_po_basic_sno INT = NULL OUTPUT,
    @out_po_no VARCHAR(50) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @com_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno          INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @vendor_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @pr_basic_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT);
        DECLARE @pr_item_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_item_sno') AS INT);
        DECLARE @is_retrospective  BIT           = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.is_retrospective') AS BIT), 0);
        DECLARE @service_sno       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @qty               DECIMAL(18,4) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,4)), 1);
        DECLARE @uom_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.uom_sno') AS INT);
        DECLARE @unit_price        DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.unit_price') AS DECIMAL(18,2));
        DECLARE @po_type           VARCHAR(20)   = ISNULL(JSON_VALUE(@jsonInput, '$.po_type'), 'RECURRING');
        DECLARE @validity_from     DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.validity_from') AS DATE);
        DECLARE @validity_to       DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.validity_to') AS DATE);
        DECLARE @ceiling_amount    DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @variance_tolerance_pct DECIMAL(5,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.variance_tolerance_pct') AS DECIMAL(5,2));
        DECLARE @purpose           VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.purpose');
        DECLARE @source_note       NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.source_note');
        DECLARE @issued_by         VARCHAR(20)   = ISNULL(JSON_VALUE(@jsonInput, '$.issued_by'), 'SYSTEM');
        DECLARE @items             NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');
        DECLARE @has_items         BIT           = CASE WHEN @items IS NOT NULL AND EXISTS (SELECT 1 FROM OPENJSON(@items)) THEN 1 ELSE 0 END;

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @vendor_sno IS NULL
            THROW 57001, 'com_sno, div_sno, brn_sno, dept_sno and vendor_sno are required.', 1;

        -- Single-item shape (unchanged callers, e.g. sp_nt_IssueRecurringServicePOCycle)
        -- still needs service_sno/unit_price when no items array is given.
        IF @has_items = 0 AND (@service_sno IS NULL OR @unit_price IS NULL)
            THROW 57001, 'service_sno and unit_price are required when no items array is supplied.', 1;

        IF @pr_basic_sno IS NULL AND @is_retrospective = 0
            THROW 57002, 'pr_basic_sno is required unless is_retrospective is set.', 1;

        BEGIN TRANSACTION;

        DECLARE @po_year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @po_seq  INT;
        SELECT @po_seq = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
        FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
        WHERE po_df_no LIKE 'SVO-' + @po_year + '-%';
        DECLARE @po_no VARCHAR(50) = 'SVO-' + @po_year + '-' + RIGHT('0000' + CAST(@po_seq AS VARCHAR(4)), 4);

        -- service_type_sno: resolved from the first item's service_sno when
        -- an items array is given, else from the single @service_sno —
        -- same "service_type_sno on the PO header" convention as
        -- sp_nt_CreateServicePO already uses.
        DECLARE @header_service_sno INT = @service_sno;
        IF @has_items = 1 AND @header_service_sno IS NULL
            SELECT TOP 1 @header_service_sno = TRY_CAST(JSON_VALUE(value, '$.service_sno') AS INT)
            FROM OPENJSON(@items) ORDER BY [key];

        DECLARE @service_type_sno INT;
        SELECT @service_type_sno = service_type_sno FROM dbo.service_master WHERE service_sno = @header_service_sno AND is_active = 'Y';

        IF @service_type_sno IS NULL
            THROW 57003, 'Unknown or inactive service_sno.', 1;

        INSERT INTO dbo.po_request_info (
            vendor_sno, brn_sno, dept_sno, com_sno, div_sno, budget_sno, budget_code, pr_basic_sno,
            po_date, required_date, purpose, terms_conditions, delivery_address,
            is_active, workflow_types_id, current_approver_id, status, po_df_no,
            po_type, validity_from, validity_to, ceiling_amount, variance_tolerance_pct,
            consumed_amount, service_type_sno, is_retrospective, parent_blanket_po_sno
        )
        VALUES (
            @vendor_sno, @brn_sno, @dept_sno, @com_sno, @div_sno, NULL, NULL, @pr_basic_sno,
            CAST(GETDATE() AS DATE), ISNULL(@validity_to, CAST(GETDATE() AS DATE)), @purpose, NULL, NULL,
            'Y', NULL, NULL, 'A', @po_no,
            @po_type, @validity_from, @validity_to, @ceiling_amount, @variance_tolerance_pct,
            0, @service_type_sno, @is_retrospective, NULL
        );
        DECLARE @po_basic_sno INT = SCOPE_IDENTITY();

        IF @has_items = 1
        BEGIN
            INSERT INTO dbo.po_item_details (
                po_basic_sno, pr_item_sno, service_sno, prod_name, specification,
                qty, unit, unit_name, agreed_unit_price, total_cost, discount_pct, tax_pct, net_cost,
                remarks, po_section, created_by, created_date, is_active
            )
            SELECT
                @po_basic_sno,
                TRY_CAST(JSON_VALUE(j.value, '$.pr_item_sno') AS INT),
                TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT),
                sm.service_name,
                ISNULL(JSON_VALUE(j.value, '$.specification'), ''),
                ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 1),
                TRY_CAST(JSON_VALUE(j.value, '$.uom_sno') AS INT),
                um.uom_name,
                TRY_CAST(JSON_VALUE(j.value, '$.unit_price') AS DECIMAL(18,4)),
                ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 1) * ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.unit_price') AS DECIMAL(18,4)), 0),
                0, 0,
                ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 1) * ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.unit_price') AS DECIMAL(18,4)), 0),
                JSON_VALUE(j.value, '$.remarks'), 'SERVICE',
                @issued_by, GETDATE(), '1'
            FROM OPENJSON(@items) j
            LEFT JOIN dbo.service_master sm ON sm.service_sno = TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT)
            LEFT JOIN dbo.uom_master um     ON um.uom_sno = TRY_CAST(JSON_VALUE(j.value, '$.uom_sno') AS INT);
        END
        ELSE
        BEGIN
            DECLARE @net_cost DECIMAL(18,4) = @qty * @unit_price;
            INSERT INTO dbo.po_item_details (
                po_basic_sno, pr_item_sno, service_sno, prod_name, specification,
                qty, unit, unit_name, agreed_unit_price, total_cost, discount_pct, tax_pct, net_cost,
                remarks, po_section, created_by, created_date, is_active
            )
            SELECT
                @po_basic_sno, @pr_item_sno, @service_sno, sm.service_name, '',
                @qty, @uom_sno, um.uom_name, @unit_price, @net_cost, 0, 0, @net_cost,
                @source_note, 'SERVICE', @issued_by, GETDATE(), '1'
            FROM dbo.service_master sm
            LEFT JOIN dbo.uom_master um ON um.uom_sno = @uom_sno
            WHERE sm.service_sno = @service_sno;
        END

        INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
        VALUES (@po_basic_sno, 'AUTO_ISSUED', @issued_by, ISNULL(@source_note, N'Direct-issued, no separate PO approval required.'), 'Y');

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

-- ==== sp_nt_ExpireServiceAgreements ====
CREATE PROCEDURE dbo.sp_nt_ExpireServiceAgreements
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.service_agreement
    SET status = 'X'
    WHERE status = 'A' AND period_end_date < CAST(GETDATE() AS DATE);

    SELECT @@ROWCOUNT AS expired_count;
END;
GO

-- ==== sp_nt_FinalizeServiceVendorEntriesConsolidation ====
CREATE PROCEDURE dbo.sp_nt_FinalizeServiceVendorEntriesConsolidation
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @entry_snos    NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.entry_snos');
    DECLARE @po_basic_sno  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT);
    DECLARE @consolidated_by VARCHAR(20) = JSON_VALUE(@jsonInput, '$.consolidated_by');

    IF @entry_snos IS NULL OR @po_basic_sno IS NULL OR @consolidated_by IS NULL
        THROW 54130, 'entry_snos, po_basic_sno and consolidated_by are required.', 1;

    UPDATE dbo.service_vendor_daily_entry
    SET status = 'CONSOLIDATED', po_basic_sno = @po_basic_sno,
        consolidated_by = @consolidated_by, consolidated_date = GETDATE()
    WHERE entry_sno IN (SELECT TRY_CAST(value AS INT) FROM OPENJSON(@entry_snos))
      AND status = 'PROCESSING';

    SELECT @@ROWCOUNT AS updated_count;
END;
GO

-- ==== sp_nt_GetActiveCeilingAgreementsForBilling ====
CREATE PROCEDURE dbo.sp_nt_GetActiveCeilingAgreementsForBilling
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno     INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
    DECLARE @div_sno     INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
    DECLARE @brn_sno     INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
    DECLARE @dept_sno    INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
    DECLARE @service_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);

    IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
        THROW 56001, 'com_sno, div_sno, brn_sno and dept_sno are required.', 1;

    SELECT
        sa.agreement_sno, sa.agreement_no, sa.service_sno, sm.service_name,
        sa.vendor_sno, k.company_name AS vendor_name,
        sa.ceiling_amount, sa.variance_tolerance_pct,
        sa.recurrence_cadence, sa.recurrence_cadence_sno, rc.cadence_name,
        sa.period_start_date, sa.period_end_date
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    WHERE sa.com_sno = @com_sno AND sa.div_sno = @div_sno
      AND sa.brn_sno = @brn_sno AND sa.dept_sno = @dept_sno
      AND sa.status = 'A' AND sa.is_active = 'Y'
      AND CAST(GETDATE() AS DATE) BETWEEN sa.period_start_date AND sa.period_end_date
      AND (@service_sno IS NULL OR sa.service_sno = @service_sno)
    ORDER BY sa.agreement_sno DESC;
END;
GO

-- ==== sp_nt_GetActiveServiceAgreement ====
CREATE PROCEDURE dbo.sp_nt_GetActiveServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno     INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
    DECLARE @div_sno     INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
    DECLARE @brn_sno     INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
    DECLARE @dept_sno    INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
    DECLARE @service_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);

    IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL OR @service_sno IS NULL
        THROW 53009, 'com_sno, div_sno, brn_sno, dept_sno and service_sno are required.', 1;

    SELECT TOP 1
        sa.agreement_sno,
        sa.agreement_no,
        sa.rate_amount,
        sa.rate_uom_sno,
        um.uom_name AS rate_uom_name,
        sa.recurrence_cadence,
        sa.period_start_date,
        sa.period_end_date,
        sa.vendor_sno
    FROM dbo.service_agreement sa
    LEFT JOIN dbo.uom_master um ON um.uom_sno = sa.rate_uom_sno
    WHERE sa.com_sno = @com_sno AND sa.div_sno = @div_sno
      AND sa.brn_sno = @brn_sno AND sa.dept_sno = @dept_sno
      AND sa.service_sno = @service_sno
      AND sa.status = 'A' AND sa.is_active = 'Y'
      AND CAST(GETDATE() AS DATE) BETWEEN sa.period_start_date AND sa.period_end_date
    ORDER BY sa.agreement_sno DESC;
END;
GO

-- ==== sp_nt_GetAgreementsDueForNotification ====
CREATE PROCEDURE dbo.sp_nt_GetAgreementsDueForNotification
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @today DATE = CAST(GETDATE() AS DATE);

    DECLARE @due TABLE (
        agreement_sno INT, agreement_no VARCHAR(30), notify_ecno VARCHAR(20),
        service_name NVARCHAR(200), rate_amount DECIMAL(18,2),
        po_generation_day SMALLINT, notify_days_before SMALLINT, due_date DATE
    );

    INSERT INTO @due (agreement_sno, agreement_no, notify_ecno, service_name, rate_amount, po_generation_day, notify_days_before, due_date)
    SELECT sa.agreement_sno, sa.agreement_no, sa.created_by, sm.service_name, sa.rate_amount,
           sa.po_generation_day, sa.notify_days_before, t.target_date
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    CROSS APPLY (SELECT DATEADD(DAY, sa.notify_days_before, @today) AS target_date) t
    WHERE sa.status = 'A' AND sa.is_active = 'Y'
      AND st.service_type_code IN ('FIXED_RECURRING', 'VARIABLE_RECURRING')
      AND ISNULL(sa.notify_days_before, 0) > 0
      AND t.target_date BETWEEN sa.period_start_date AND sa.period_end_date
      AND (
            (st.service_type_code = 'FIXED_RECURRING' AND (
                  (rc.interval_unit = 'DAY' AND DATEDIFF(DAY, sa.period_start_date, t.target_date) % rc.interval_value = 0)
               OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NOT NULL
                   AND DATEDIFF(MONTH, sa.period_start_date, t.target_date) % rc.interval_value = 0
                   AND (DAY(t.target_date) = sa.po_generation_day
                        OR (sa.po_generation_day > DAY(EOMONTH(t.target_date)) AND t.target_date = EOMONTH(t.target_date))))
               OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NULL
                   AND DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, t.target_date) / rc.interval_value) * rc.interval_value, sa.period_start_date) = t.target_date)
            ))
            OR
            (st.service_type_code = 'VARIABLE_RECURRING' AND (
                  (rc.interval_unit = 'DAY' AND DATEDIFF(DAY, sa.period_start_date, t.target_date) % rc.interval_value = 0)
               OR (rc.interval_unit = 'MONTH' AND DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, t.target_date) / rc.interval_value) * rc.interval_value, sa.period_start_date) = t.target_date)
            ))
          )
      AND NOT EXISTS (
          SELECT 1 FROM dbo.service_agreement_notification_log l
          WHERE l.agreement_sno = sa.agreement_sno AND l.billing_period_start = t.target_date
      );

    DECLARE @agreement_sno INT, @due_date DATE;
    DECLARE @claimed TABLE (
        agreement_sno INT, agreement_no VARCHAR(30), notify_ecno VARCHAR(20),
        service_name NVARCHAR(200), rate_amount DECIMAL(18,2),
        po_generation_day SMALLINT, notify_days_before SMALLINT, due_date DATE
    );

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT agreement_sno, due_date FROM @due;
    OPEN cur;
    FETCH NEXT FROM cur INTO @agreement_sno, @due_date;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.service_agreement_notification_log (agreement_sno, billing_period_start, status)
            VALUES (@agreement_sno, @due_date, 'PENDING');

            INSERT INTO @claimed
            SELECT agreement_sno, agreement_no, notify_ecno, service_name, rate_amount, po_generation_day, notify_days_before, due_date
            FROM @due
            WHERE agreement_sno = @agreement_sno AND due_date = @due_date;
        END TRY
        BEGIN CATCH
            -- UNIQUE violation: another sweep already claimed this slot this
            -- run — skip silently, same as the PR log's claim pattern.
        END CATCH

        FETCH NEXT FROM cur INTO @agreement_sno, @due_date;
    END
    CLOSE cur;
    DEALLOCATE cur;

    SELECT agreement_sno, agreement_no, notify_ecno, service_name, rate_amount,
           po_generation_day, notify_days_before, due_date
    FROM @claimed;
END;
GO

-- ==== sp_nt_GetAgreementsDueForRecurringPR ====
CREATE PROCEDURE dbo.sp_nt_GetAgreementsDueForRecurringPR
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @today DATE = CAST(GETDATE() AS DATE);

    SELECT
        sa.agreement_sno,
        sa.agreement_no,
        sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
        sa.service_sno,
        sm.service_name,
        sa.recurrence_cadence,
        sa.period_start_date,
        sa.period_end_date,
        @today AS billing_period_start
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    CROSS APPLY (
        SELECT
            CASE sa.recurrence_cadence
                WHEN 'DAILY' THEN 1
                WHEN 'EVERY_N_DAYS' THEN
                    CASE WHEN ISNULL(sm.recurrence_interval_days, 0) > 0
                              AND DATEDIFF(DAY, sa.period_start_date, @today) % sm.recurrence_interval_days = 0
                         THEN 1 ELSE 0 END
                WHEN 'MONTHLY' THEN
                    CASE WHEN DATEADD(MONTH, DATEDIFF(MONTH, sa.period_start_date, @today), sa.period_start_date) = @today
                         THEN 1 ELSE 0 END
                WHEN 'QUARTERLY' THEN
                    CASE WHEN DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, @today) / 3) * 3, sa.period_start_date) = @today
                         THEN 1 ELSE 0 END
                WHEN 'HALF_YEARLY' THEN
                    CASE WHEN DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, @today) / 6) * 6, sa.period_start_date) = @today
                         THEN 1 ELSE 0 END
                WHEN 'YEARLY_FIXED_DATE' THEN
                    CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, sa.period_start_date, @today), sa.period_start_date) = @today
                         THEN 1 ELSE 0 END
                ELSE 0
            END AS is_boundary,
            -- the previous boundary date for this cadence, used only to scope
            -- the "already billed by a manual PR" check below
            CASE sa.recurrence_cadence
                WHEN 'DAILY'              THEN DATEADD(DAY,   -1, @today)
                WHEN 'EVERY_N_DAYS'       THEN DATEADD(DAY,   -ISNULL(sm.recurrence_interval_days, 1), @today)
                WHEN 'MONTHLY'            THEN DATEADD(MONTH, -1, @today)
                WHEN 'QUARTERLY'          THEN DATEADD(MONTH, -3, @today)
                WHEN 'HALF_YEARLY'        THEN DATEADD(MONTH, -6, @today)
                WHEN 'YEARLY_FIXED_DATE'  THEN DATEADD(YEAR,  -1, @today)
                ELSE sa.period_start_date
            END AS previous_boundary
    ) b
    WHERE sa.status = 'A' AND sa.is_active = 'Y'
      AND @today BETWEEN sa.period_start_date AND sa.period_end_date
      AND b.is_boundary = 1
      -- not already claimed/created by a previous run of this job
      AND NOT EXISTS (
          SELECT 1 FROM dbo.service_agreement_recurring_pr_log log
          WHERE log.agreement_sno = sa.agreement_sno AND log.billing_period_start = @today
      )
      -- not already billed this period by a manually-submitted PR (§4's
      -- auto-fill flow) — see file header
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.pr_item_details pid
          JOIN dbo.pr_basic_info pb ON pb.pr_basic_sno = pid.pr_basic_sno
          WHERE pid.agreement_sno = sa.agreement_sno
            AND pid.is_active = 'Y'
            AND pb.is_active = 'Y'
            AND pb.created_date > b.previous_boundary
      );
END;
GO

-- ==== sp_nt_GetAllServicePOs ====
CREATE PROCEDURE dbo.sp_nt_GetAllServicePOs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = NULL, @vendor_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @status = JSON_VALUE(@jsonInput, '$.status');
        SET @vendor_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    END

    SELECT
        p.po_basic_sno,
        p.po_df_no        AS po_no,
        p.pr_basic_sno,
        pr.pr_no,
        p.vendor_sno,
        k.company_name    AS vendor_name,
        p.po_type,
        st.service_type_code,
        st.service_type_name,
        p.validity_from,
        p.validity_to,
        p.ceiling_amount,
        p.consumed_amount,
        p.status,
        p.po_pdf_url,
        (
            SELECT
                pid.po_item_sno, pid.service_sno, sm.service_name,
                pid.qty, pid.unit_name, pid.agreed_unit_price, pid.net_cost, pid.po_section
            FROM dbo.po_item_details pid
            LEFT JOIN dbo.service_master sm ON sm.service_sno = pid.service_sno
            WHERE pid.po_basic_sno = p.po_basic_sno AND pid.is_active = '1'
            FOR JSON PATH
        ) AS items
    FROM dbo.po_request_info p
    LEFT JOIN dbo.service_type_master st ON st.service_type_sno = p.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k        ON k.kyc_basic_info_sno = p.vendor_sno
    LEFT JOIN dbo.pr_basic_info pr        ON pr.pr_basic_sno = p.pr_basic_sno
    WHERE p.service_type_sno IS NOT NULL
      AND (@status IS NULL OR p.status = @status)
      AND (@vendor_sno IS NULL OR p.vendor_sno = @vendor_sno)
    ORDER BY p.po_basic_sno DESC;
END;
GO

-- ==== sp_nt_GetApprovedServiceVendorKycs ====
CREATE PROCEDURE dbo.sp_nt_GetApprovedServiceVendorKycs
AS
BEGIN
    SET NOCOUNT ON;

    SELECT service_vendor_kyc_sno, service_vendor_code, company_name, contact_person,
           email, mobile_number, kyc_basic_info_sno
    FROM dbo.service_vendor_kyc
    WHERE status = 'A' AND is_active = 'Y'
    ORDER BY company_name;
END;
GO

-- ==== sp_nt_GetApprovedSuppliersForService ====
CREATE PROCEDURE dbo.sp_nt_GetApprovedSuppliersForService
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @service_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);

    IF @service_sno IS NULL
        THROW 60010, N'service_sno is required.', 1;

    SELECT k.kyc_basic_info_sno, k.company_name, k.supp_code, k.email, k.mobile_number
    FROM dbo.service_master_supplier msm
    JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = msm.kyc_basic_info_sno
    WHERE msm.service_sno = @service_sno AND msm.is_active = 'Y'
      AND k.status = 'A' AND k.is_active = 'Y'
    ORDER BY k.company_name;
END;
GO

-- ==== sp_nt_GetApprovedVendorsForServicePicker ====
CREATE PROCEDURE dbo.sp_nt_GetApprovedVendorsForServicePicker
AS
BEGIN
    SET NOCOUNT ON;

    SELECT kyc_basic_info_sno, company_name, supp_code, email, mobile_number
    FROM dbo.kyc_basic_info
    WHERE status = 'A' AND is_active = 'Y'
    ORDER BY company_name;
END;
GO

-- ==== sp_nt_GetEligiblePrLinesForServicePO ====
CREATE PROCEDURE dbo.sp_nt_GetEligiblePrLinesForServicePO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @pr_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT);

    IF @pr_basic_sno IS NULL
    BEGIN
        RAISERROR('pr_basic_sno is required.', 16, 1);
        RETURN;
    END

    SELECT
        pid.pr_item_sno,
        pid.pr_basic_sno,
        pb.pr_no,
        pid.service_sno,
        sm.service_name,
        sm.service_type_sno,
        st.service_type_code,
        st.service_type_name,
        sm.default_uom_sno,
        pid.specification,
        pid.qty,
        pid.unit,
        pid.est_cost,
        pid.total_cost,
        pid.remarks
    FROM dbo.pr_item_details pid
    JOIN dbo.pr_basic_info pb    ON pb.pr_basic_sno = pid.pr_basic_sno
    JOIN dbo.service_master sm   ON sm.service_sno = pid.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    WHERE pid.pr_basic_sno = @pr_basic_sno
      AND pid.item_type = 'service'
      AND pid.is_active = 'Y'
      AND pb.status = 'A'
      AND NOT EXISTS (
          -- po_item_details uses '1'/'0', unlike pr_item_details' 'Y'/'N' above
          SELECT 1 FROM dbo.po_item_details poi
          WHERE poi.pr_item_sno = pid.pr_item_sno AND poi.is_active = '1'
      )
    ORDER BY pid.pr_item_sno;
END;
GO

-- ==== sp_nt_GetRecurrenceCadenceRecords ====
CREATE PROCEDURE dbo.sp_nt_GetRecurrenceCadenceRecords
AS
BEGIN
    SET NOCOUNT ON;

    SELECT recurrence_cadence_sno, cadence_code, cadence_name, interval_unit, interval_value, description, is_active
    FROM dbo.recurrence_cadence_master
    WHERE is_active = 'Y'
    ORDER BY recurrence_cadence_sno;
END;
GO

-- ==== sp_nt_GetServiceAgreements ====
CREATE PROCEDURE dbo.sp_nt_GetServiceAgreements
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL,
            @service_sno INT = NULL, @status VARCHAR(1) = NULL, @vendor_sno INT = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @com_sno     = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno     = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno     = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno    = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        SET @service_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        SET @status      = JSON_VALUE(@jsonInput, '$.status');
        SET @vendor_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    END

    SELECT
        sa.agreement_sno,
        sa.agreement_no,
        sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
        sa.service_sno,
        sm.service_name,
        st.service_type_code,
        sa.vendor_sno,
        k.company_name        AS vendor_name,
        sa.rate_amount,
        sa.rate_uom_sno,
        um.uom_name            AS rate_uom_name,
        sa.ceiling_amount,
        sa.variance_tolerance_pct,
        sa.recurrence_cadence,
        sa.po_generation_day,
        sa.notify_days_before,
        sa.period_start_date,
        sa.period_end_date,
        sa.agreement_doc_url,
        sa.remarks,
        sa.workflow_types_id,
        sa.current_approver_id,
        sa.status,
        sa.created_by,
        sa.created_at
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm      ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.uom_master um      ON um.uom_sno = sa.rate_uom_sno
    LEFT JOIN dbo.kyc_basic_info k   ON k.kyc_basic_info_sno = sa.vendor_sno
    WHERE sa.is_active = 'Y'
      AND (@com_sno IS NULL OR sa.com_sno = @com_sno)
      AND (@div_sno IS NULL OR sa.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR sa.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR sa.dept_sno = @dept_sno)
      AND (@service_sno IS NULL OR sa.service_sno = @service_sno)
      AND (@status IS NULL OR sa.status = @status)
      AND (@vendor_sno IS NULL OR sa.vendor_sno = @vendor_sno)
    ORDER BY sa.agreement_sno DESC;
END;
GO

-- ==== sp_nt_GetServiceAgreementsForApproval ====
CREATE PROCEDURE dbo.sp_nt_GetServiceAgreementsForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        sa.agreement_sno,
        sa.agreement_no,
        sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
        sa.service_sno,
        sm.service_name,
        sa.vendor_sno,
        k.company_name     AS vendor_name,
        sa.rate_amount,
        sa.rate_uom_sno,
        um.uom_name          AS rate_uom_name,
        sa.ceiling_amount,
        sa.variance_tolerance_pct,
        sa.recurrence_cadence,
        sa.po_generation_day,
        sa.notify_days_before,
        sa.period_start_date,
        sa.period_end_date,
        sa.agreement_doc_url,
        sa.remarks,
        sa.workflow_types_id,
        sa.current_approver_id,
        sa.status,
        (
            SELECT ws.stage_order_json
            FROM dbo.workflow_stage ws
            WHERE ws.workflow_types_id = sa.workflow_types_id AND ws.is_active = 'Y'
        ) AS stage_order_json
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm     ON sm.service_sno = sa.service_sno
    LEFT JOIN dbo.uom_master um     ON um.uom_sno = sa.rate_uom_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = sa.vendor_sno
    WHERE sa.current_approver_id = @Ecno
      AND sa.status = 'P'
      AND sa.is_active = 'Y'
    ORDER BY sa.agreement_sno DESC;
END;
GO

-- ==== sp_nt_GetServiceBillRequests ====
CREATE PROCEDURE dbo.sp_nt_GetServiceBillRequests
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL,
            @agreement_sno INT = NULL, @status VARCHAR(1) = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @com_sno       = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno       = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno       = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno      = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        SET @agreement_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
        SET @status        = JSON_VALUE(@jsonInput, '$.status');
    END

    SELECT
        sbr.bill_request_sno, sbr.request_no, sbr.agreement_sno, sa.agreement_no,
        sbr.com_sno, sbr.div_sno, sbr.brn_sno, sbr.dept_sno,
        sbr.service_sno, sm.service_name,
        sbr.vendor_sno, k.company_name AS vendor_name,
        sbr.billing_period_start, sbr.billing_period_end,
        sbr.invoice_no, sbr.invoice_date, sbr.invoice_amount, sbr.invoice_doc_url,
        sbr.remarks, sbr.workflow_types_id, sbr.current_approver_id, sbr.status,
        sbr.po_basic_sno, po.po_df_no AS po_no, po.po_pdf_url,
        sbr.created_by, sbr.created_at,
        (
            SELECT h.status_by AS approved_by, h.created_date AS approved_at
            FROM dbo.service_bill_request_history h
            WHERE h.bill_request_sno = sbr.bill_request_sno AND h.action_type = 'APPROVED' AND h.is_active = 'Y'
            ORDER BY h.history_sno DESC
            FOR JSON PATH
        ) AS approval_history,
        (
            SELECT bri.bill_request_item_sno, bri.service_sno, sm2.service_name, bri.qty, bri.uom_sno, um.uom_name,
                   bri.unit_price, bri.amount, bri.remarks
            FROM dbo.service_bill_request_item_details bri
            LEFT JOIN dbo.service_master sm2 ON sm2.service_sno = bri.service_sno
            LEFT JOIN dbo.uom_master um       ON um.uom_sno = bri.uom_sno
            WHERE bri.bill_request_sno = sbr.bill_request_sno AND bri.is_active = 'Y'
            FOR JSON PATH
        ) AS items
    FROM dbo.service_bill_request sbr
    JOIN dbo.service_agreement sa   ON sa.agreement_sno = sbr.agreement_sno
    JOIN dbo.service_master sm      ON sm.service_sno = sbr.service_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = sbr.vendor_sno
    LEFT JOIN dbo.po_request_info po ON po.po_basic_sno = sbr.po_basic_sno
    WHERE sbr.is_active = 'Y'
      AND (@com_sno IS NULL OR sbr.com_sno = @com_sno)
      AND (@div_sno IS NULL OR sbr.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR sbr.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR sbr.dept_sno = @dept_sno)
      AND (@agreement_sno IS NULL OR sbr.agreement_sno = @agreement_sno)
      AND (@status IS NULL OR sbr.status = @status)
    ORDER BY sbr.bill_request_sno DESC;
END;
GO

-- ==== sp_nt_GetServiceBillRequestsForApproval ====
CREATE PROCEDURE dbo.sp_nt_GetServiceBillRequestsForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        sbr.bill_request_sno, sbr.request_no, sbr.agreement_sno, sa.agreement_no,
        sbr.com_sno, sbr.div_sno, sbr.brn_sno, sbr.dept_sno,
        sbr.service_sno, sm.service_name,
        sbr.vendor_sno, k.company_name AS vendor_name,
        sbr.billing_period_start, sbr.billing_period_end,
        sbr.invoice_no, sbr.invoice_date, sbr.invoice_amount, sbr.invoice_doc_url,
        sa.ceiling_amount, sa.variance_tolerance_pct,
        sbr.remarks, sbr.workflow_types_id, sbr.current_approver_id, sbr.status,
        sbr.created_by, sbr.created_at,
        (
            SELECT ws.stage_order_json
            FROM dbo.workflow_stage ws
            WHERE ws.workflow_types_id = sbr.workflow_types_id AND ws.is_active = 'Y'
        ) AS stage_order_json,
        (
            SELECT bri.bill_request_item_sno, bri.service_sno, sm2.service_name, bri.qty, bri.uom_sno, um.uom_name,
                   bri.unit_price, bri.amount, bri.remarks
            FROM dbo.service_bill_request_item_details bri
            LEFT JOIN dbo.service_master sm2 ON sm2.service_sno = bri.service_sno
            LEFT JOIN dbo.uom_master um       ON um.uom_sno = bri.uom_sno
            WHERE bri.bill_request_sno = sbr.bill_request_sno AND bri.is_active = 'Y'
            FOR JSON PATH
        ) AS items
    FROM dbo.service_bill_request sbr
    JOIN dbo.service_agreement sa   ON sa.agreement_sno = sbr.agreement_sno
    JOIN dbo.service_master sm      ON sm.service_sno = sbr.service_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = sbr.vendor_sno
    WHERE sbr.current_approver_id = @Ecno
      AND sbr.status = 'P'
      AND sbr.is_active = 'Y'
    ORDER BY sbr.bill_request_sno DESC;
END;
GO

-- ==== sp_nt_GetServiceMasterSupplierMappings ====
CREATE PROCEDURE dbo.sp_nt_GetServiceMasterSupplierMappings
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        msm.mapping_sno, msm.service_sno, sm.service_name,
        msm.kyc_basic_info_sno, k.company_name, k.supp_code,
        msm.is_active
    FROM dbo.service_master_supplier msm
    JOIN dbo.service_master sm ON sm.service_sno = msm.service_sno
    JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = msm.kyc_basic_info_sno
    WHERE msm.is_active = 'Y'
    ORDER BY sm.service_name, k.company_name;
END;
GO

-- ==== sp_nt_GetServicePOsForApproval ====
CREATE PROCEDURE dbo.sp_nt_GetServicePOsForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.po_basic_sno,
        p.po_df_no                                  AS po_no,
        p.pr_basic_sno,
        pr.pr_no,
        p.vendor_sno,
        k.company_name                               AS vendor_name,
        p.po_type,
        p.service_type_sno,
        st.service_type_code,
        st.service_type_name,
        p.validity_from,
        p.validity_to,
        p.ceiling_amount,
        p.variance_tolerance_pct,
        p.consumed_amount,
        p.is_retrospective,
        p.parent_blanket_po_sno,
        p.purpose,
        p.terms_conditions,
        p.delivery_address,
        p.com_sno, p.div_sno, p.brn_sno, p.dept_sno,
        p.workflow_types_id,
        p.current_approver_id,
        p.status,
        (
            SELECT ws.stage_order_json
            FROM dbo.workflow_stage ws
            WHERE ws.workflow_types_id = p.workflow_types_id AND ws.is_active = 'Y'
        ) AS stage_order_json,
        (
            SELECT
                pid.po_item_sno, pid.pr_item_sno, pid.service_sno, sm.service_name,
                pid.specification, pid.qty, pid.unit_name, pid.agreed_unit_price,
                pid.total_cost, pid.discount_pct, pid.tax_pct, pid.net_cost,
                pid.remarks, pid.po_section
            FROM dbo.po_item_details pid
            LEFT JOIN dbo.service_master sm ON sm.service_sno = pid.service_sno
            WHERE pid.po_basic_sno = p.po_basic_sno AND pid.is_active = '1'
            FOR JSON PATH
        ) AS items
    FROM dbo.po_request_info p
    LEFT JOIN dbo.service_type_master st ON st.service_type_sno = p.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k        ON k.kyc_basic_info_sno = p.vendor_sno
    LEFT JOIN dbo.pr_basic_info pr        ON pr.pr_basic_sno = p.pr_basic_sno
    WHERE p.current_approver_id = @Ecno
      AND p.status = 'P'
      AND p.service_type_sno IS NOT NULL
    ORDER BY p.po_basic_sno DESC;
END;
GO

-- ==== sp_nt_GetServiceRecords ====
CREATE PROCEDURE dbo.sp_nt_GetServiceRecords
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @service_type_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @service_type_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_type_sno') AS INT);

    SELECT
        sm.service_sno,
        sm.service_name,
        sm.service_code,
        sm.service_type_sno,
        st.service_type_code,
        st.service_type_name,
        sm.default_uom_sno,
        um.uom_name           AS default_uom_name,
        sm.sac_code,
        sm.is_recurring,
        sm.recurrence_cadence,
        sm.recurrence_interval_days,
        sm.description,
        sm.is_active,
        sm.default_product_sno,
        pm.prod_name           AS product_name,
        pm.prod_description    AS product_description,
        pm.prod_hsn_code       AS product_hsn_code,
        pum.uom_name           AS product_uom_name
    FROM dbo.service_master sm
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.uom_master um     ON um.uom_sno = sm.default_uom_sno
    LEFT JOIN dbo.product_master pm ON pm.prod_sno = sm.default_product_sno
    LEFT JOIN dbo.uom_master pum    ON pum.uom_sno = pm.uom_sno
    WHERE sm.is_active = 'Y'
      AND (@service_type_sno IS NULL OR sm.service_type_sno = @service_type_sno)
    ORDER BY sm.service_name;
END;
GO

-- ==== sp_nt_GetServiceTypeRecords ====
CREATE PROCEDURE dbo.sp_nt_GetServiceTypeRecords
AS
BEGIN
    SET NOCOUNT ON;

    SELECT service_type_sno,
           service_type_code,
           service_type_name,
           requires_ceiling_amount,
           requires_variance_tolerance,
           is_active
    FROM dbo.service_type_master
    WHERE is_active = 'Y'
    ORDER BY service_type_sno;
END;
GO

-- ==== sp_nt_GetServiceVendorDailyEntries ====
CREATE PROCEDURE dbo.sp_nt_GetServiceVendorDailyEntries
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @vendor_sno    INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    DECLARE @service_sno   INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
    DECLARE @com_sno       INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
    DECLARE @div_sno       INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
    DECLARE @brn_sno       INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
    DECLARE @dept_sno      INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
    DECLARE @status        VARCHAR(20) = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @date_from     DATE        = TRY_CAST(JSON_VALUE(@jsonInput, '$.date_from') AS DATE);
    DECLARE @date_to       DATE        = TRY_CAST(JSON_VALUE(@jsonInput, '$.date_to') AS DATE);
    DECLARE @approver_ecno VARCHAR(20) = JSON_VALUE(@jsonInput, '$.approver_ecno');

    SELECT
        e.entry_sno, e.com_sno, e.div_sno, e.brn_sno, e.dept_sno,
        e.vendor_sno, k.company_name AS vendor_name,
        e.service_sno, sm.service_name,
        e.entry_date, e.qty, e.unit, um.uom_name AS unit_name, e.unit_price, e.total_amount,
        e.specification, e.remarks, e.receipt_doc_url, e.status, e.po_basic_sno, p.po_df_no AS po_no,
        e.workflow_types_id, e.current_approver_id, e.approved_by, e.approved_at, e.approval_comments,
        e.created_by, e.created_date, e.consolidated_by, e.consolidated_date
    FROM dbo.service_vendor_daily_entry e
    LEFT JOIN dbo.kyc_basic_info k    ON k.kyc_basic_info_sno = e.vendor_sno
    LEFT JOIN dbo.service_master sm   ON sm.service_sno = e.service_sno
    LEFT JOIN dbo.uom_master um       ON um.uom_sno = e.unit
    LEFT JOIN dbo.po_request_info p   ON p.po_basic_sno = e.po_basic_sno
    WHERE e.is_active = 'Y'
      AND (@vendor_sno IS NULL OR e.vendor_sno = @vendor_sno)
      AND (@service_sno IS NULL OR e.service_sno = @service_sno)
      AND (@com_sno IS NULL OR e.com_sno = @com_sno)
      AND (@div_sno IS NULL OR e.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR e.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR e.dept_sno = @dept_sno)
      AND (@date_from IS NULL OR e.entry_date >= @date_from)
      AND (@date_to IS NULL OR e.entry_date <= @date_to)
      AND (@approver_ecno IS NULL OR e.current_approver_id = @approver_ecno)
      AND (
            (@status IS NULL AND e.status <> 'CANCELLED')
            OR e.status = @status
          )
    ORDER BY e.entry_date DESC, e.entry_sno DESC;
END;
GO

-- ==== sp_nt_GetServiceVendorKycs ====
CREATE PROCEDURE dbo.sp_nt_GetServiceVendorKycs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL, @status VARCHAR(1) = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @com_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        SET @status   = JSON_VALUE(@jsonInput, '$.status');
    END

    SELECT
        svk.service_vendor_kyc_sno, svk.service_vendor_code,
        svk.com_sno, svk.div_sno, svk.brn_sno, svk.dept_sno,
        svk.company_name, svk.contact_person, svk.email, svk.mobile_number, svk.business_type,
        svk.is_gst_avail, svk.gst_no, svk.is_msme_avail, svk.msme_no, svk.pan_no, svk.supplier_cat_code,
        svk.document, svk.remarks, svk.workflow_types_id, svk.current_approver_id, svk.status,
        svk.kyc_basic_info_sno, svk.created_by, svk.created_at
    FROM dbo.service_vendor_kyc svk
    WHERE svk.is_active = 'Y'
      AND (@com_sno IS NULL OR svk.com_sno = @com_sno)
      AND (@div_sno IS NULL OR svk.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR svk.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR svk.dept_sno = @dept_sno)
      AND (@status IS NULL OR svk.status = @status)
    ORDER BY svk.service_vendor_kyc_sno DESC;
END;
GO

-- ==== sp_nt_GetServiceVendorKycsForApproval ====
CREATE PROCEDURE dbo.sp_nt_GetServiceVendorKycsForApproval
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        svk.service_vendor_kyc_sno, svk.service_vendor_code,
        svk.com_sno, svk.div_sno, svk.brn_sno, svk.dept_sno,
        svk.company_name, svk.contact_person, svk.email, svk.mobile_number, svk.business_type,
        svk.is_gst_avail, svk.gst_no, svk.is_msme_avail, svk.msme_no, svk.pan_no, svk.supplier_cat_code,
        svk.document, svk.remarks, svk.workflow_types_id, svk.current_approver_id, svk.status,
        (
            SELECT ws.stage_order_json
            FROM dbo.workflow_stage ws
            WHERE ws.workflow_types_id = svk.workflow_types_id AND ws.is_active = 'Y'
        ) AS stage_order_json
    FROM dbo.service_vendor_kyc svk
    WHERE svk.current_approver_id = @Ecno
      AND svk.status = 'P'
      AND svk.is_active = 'Y'
    ORDER BY svk.service_vendor_kyc_sno DESC;
END;
GO

-- ==== sp_nt_IssueRecurringServicePOCycle ====
CREATE PROCEDURE dbo.sp_nt_IssueRecurringServicePOCycle
    @jsonInput NVARCHAR(MAX),
    @silent BIT = 0,
    @out_result VARCHAR(30) = NULL OUTPUT,
    @out_po_basic_sno INT = NULL OUTPUT,
    @out_po_no VARCHAR(50) = NULL OUTPUT,
    @out_pr_basic_sno INT = NULL OUTPUT,
    @out_pr_no VARCHAR(20) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @agreement_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
    DECLARE @billing_period_start DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.billing_period_start') AS DATE);
    DECLARE @issued_by VARCHAR(20) = ISNULL(JSON_VALUE(@jsonInput, '$.issued_by'), 'SYSTEM');

    BEGIN TRY
        IF @agreement_sno IS NULL OR @billing_period_start IS NULL
            THROW 55001, 'agreement_sno and billing_period_start are required.', 1;

        IF EXISTS (SELECT 1 FROM dbo.service_agreement_recurring_pr_log WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start)
        BEGIN
            SET @out_result = 'SKIPPED_ALREADY_CLAIMED';
            IF @silent = 0
                SELECT @out_result AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start;
            RETURN;
        END

        DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @service_sno INT, @vendor_sno INT,
                @rate_amount DECIMAL(18,2), @rate_uom_sno INT, @service_type_code VARCHAR(30),
                @agr_status CHAR(1), @period_end DATE;

        SELECT @com_sno = sa.com_sno, @div_sno = sa.div_sno, @brn_sno = sa.brn_sno, @dept_sno = sa.dept_sno,
               @service_sno = sa.service_sno, @vendor_sno = sa.vendor_sno, @rate_amount = sa.rate_amount,
               @rate_uom_sno = sa.rate_uom_sno, @agr_status = sa.status, @period_end = sa.period_end_date,
               @service_type_code = st.service_type_code
        FROM dbo.service_agreement sa
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sa.agreement_sno = @agreement_sno;

        IF @agr_status IS NULL
            THROW 55002, 'Agreement not found.', 1;
        IF @agr_status <> 'A'
            THROW 55003, 'Agreement is not Approved.', 1;
        IF @service_type_code <> 'FIXED_RECURRING'
            THROW 55004, 'Recurring PO auto-issue only applies to Fixed Recurring agreements.', 1;
        IF @billing_period_start > @period_end
            THROW 55005, 'billing_period_start is past the agreement period_end_date.', 1;
        IF @vendor_sno IS NULL
            THROW 55006, 'Agreement has no vendor_sno — cannot auto-issue a PO.', 1;

        -- Guard against double-booking a period someone already billed by
        -- hand via the PR-line auto-fill screen (usp_InsertPurchaseRequest §4)
        IF EXISTS (
            SELECT 1 FROM dbo.pr_item_details pid
            JOIN dbo.pr_basic_info pb ON pb.pr_basic_sno = pid.pr_basic_sno
            WHERE pid.agreement_sno = @agreement_sno AND pid.is_active = 'Y' AND pb.is_active = 'Y'
              AND pb.created_date >= @billing_period_start
        )
        BEGIN
            INSERT INTO dbo.service_agreement_recurring_pr_log (agreement_sno, billing_period_start, status, error_message)
            VALUES (@agreement_sno, @billing_period_start, 'SKIPPED_MANUAL', 'A PR already exists for this billing period, created manually.');

            SET @out_result = 'SKIPPED_MANUAL_PR_EXISTS';
            IF @silent = 0
                SELECT @out_result AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start;
            RETURN;
        END

        -- Claim the slot before doing any real work (see file header —
        -- committed outside the transaction below so it survives a rollback).
        INSERT INTO dbo.service_agreement_recurring_pr_log (agreement_sno, billing_period_start, status)
        VALUES (@agreement_sno, @billing_period_start, 'PENDING');

        BEGIN TRANSACTION;

        DECLARE @current_year VARCHAR(10) = dbo.fn_GetFinancialYear(GETDATE());
        DECLARE @pr_prefix VARCHAR(20) = 'PR' + @current_year;
        DECLARE @pr_seq INT;
        SELECT @pr_seq = ISNULL(MAX(CASE WHEN pr_no LIKE @pr_prefix + '%' THEN TRY_CAST(SUBSTRING(pr_no, LEN(@pr_prefix) + 1, LEN(pr_no)) AS INT) ELSE 0 END), 0) + 1
        FROM dbo.pr_basic_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE @pr_prefix + '%';
        DECLARE @pr_no VARCHAR(20) = @pr_prefix + RIGHT('0000' + CAST(@pr_seq AS VARCHAR(4)), 4);

        -- pr_basic_info.priority_sno is NOT NULL — resolve a sensible
        -- default for a system-generated PR (prefers 'Medium', falls back
        -- to any active priority so this doesn't break if that row is ever
        -- renamed/removed).
        DECLARE @default_priority_sno INT;
        SELECT TOP 1 @default_priority_sno = priority_sno
        FROM dbo.priority_master
        WHERE is_active = 'Y'
        ORDER BY CASE WHEN priority_name = 'Medium' THEN 0 ELSE 1 END, priority_sno;

        IF @default_priority_sno IS NULL
            THROW 55007, 'No active priority_master row found to assign to the auto-generated PR.', 1;

        -- Auto-approved PR: status='A', no workflow — the human decision
        -- already happened at agreement-approval time (see file header).
        INSERT INTO dbo.pr_basic_info (
            pr_no, com_sno, div_sno, brn_sno, dept_sno, reg_date, required_date, priority_sno, purpose,
            is_active, created_by, created_date, workflow_types_id, current_approver_id, status
        )
        VALUES (
            @pr_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @billing_period_start, @billing_period_start, @default_priority_sno,
            N'Auto-generated recurring PR — Service Agreement ' + CAST(@agreement_sno AS VARCHAR(10)),
            'Y', @issued_by, GETDATE(), NULL, NULL, 'A'
        );
        DECLARE @pr_basic_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.pr_item_details (
            pr_no, pr_basic_sno, prod_sno, qty, unit, est_cost, total_cost, remarks, specification,
            pr_prod_file, item_type, service_sno, agreement_sno, is_active, created_by, created_date
        )
        VALUES (
            @pr_no, @pr_basic_sno, NULL, 1, @rate_uom_sno, @rate_amount, @rate_amount, '', '',
            NULL, 'service', @service_sno, @agreement_sno, 'Y', @issued_by, GETDATE()
        );
        DECLARE @pr_item_sno INT = SCOPE_IDENTITY();

        DECLARE @poJson NVARCHAR(MAX) = (
            SELECT @com_sno AS com_sno, @div_sno AS div_sno, @brn_sno AS brn_sno, @dept_sno AS dept_sno,
                   @vendor_sno AS vendor_sno, @pr_basic_sno AS pr_basic_sno, 0 AS is_retrospective,
                   @pr_item_sno AS pr_item_sno, @service_sno AS service_sno, 1 AS qty, @rate_uom_sno AS uom_sno,
                   @rate_amount AS unit_price, 'RECURRING' AS po_type,
                   @billing_period_start AS validity_from, @period_end AS validity_to,
                   @issued_by AS issued_by,
                   (N'Auto-issued recurring Service PO — Service Agreement ' + CAST(@agreement_sno AS VARCHAR(10))
                    + N', period starting ' + CONVERT(VARCHAR(10), @billing_period_start, 120)) AS source_note,
                   (N'Recurring service PO — Service Agreement ' + CAST(@agreement_sno AS VARCHAR(10))) AS purpose
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        DECLARE @po_result VARCHAR(30), @po_basic_sno INT, @po_no VARCHAR(50);
        EXEC dbo.sp_nt_DirectIssueServicePO
            @jsonInput = @poJson, @silent = 1,
            @out_result = @po_result OUTPUT, @out_po_basic_sno = @po_basic_sno OUTPUT, @out_po_no = @po_no OUTPUT;

        UPDATE dbo.service_agreement_recurring_pr_log
        SET status = 'CREATED', pr_basic_sno = @pr_basic_sno, pr_no = @pr_no,
            po_basic_sno = @po_basic_sno, po_no = @po_no, modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start;

        COMMIT TRANSACTION;

        SET @out_result = 'SUCCESS';
        SET @out_po_basic_sno = @po_basic_sno;
        SET @out_po_no = @po_no;
        SET @out_pr_basic_sno = @pr_basic_sno;
        SET @out_pr_no = @pr_no;

        IF @silent = 0
            SELECT 'SUCCESS' AS result, @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start,
                   @pr_basic_sno AS pr_basic_sno, @pr_no AS pr_no, @po_basic_sno AS po_basic_sno, @po_no AS po_no;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        UPDATE dbo.service_agreement_recurring_pr_log
        SET status = 'FAILED', error_message = ERROR_MESSAGE(), modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start AND status = 'PENDING';

        SET @out_result = 'ERROR';
        IF @silent = 0
            THROW;
    END CATCH
END;
GO

-- ==== sp_nt_LockServiceVendorEntriesForConsolidation ====
CREATE PROCEDURE dbo.sp_nt_LockServiceVendorEntriesForConsolidation
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @entry_snos NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.entry_snos');
    DECLARE @locked_by  VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.locked_by');

    IF @entry_snos IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@entry_snos))
        THROW 54120, 'entry_snos must be a non-empty array.', 1;
    IF @locked_by IS NULL
        THROW 54121, 'locked_by is required.', 1;

    DECLARE @requestedCount INT = (SELECT COUNT(*) FROM OPENJSON(@entry_snos));

    DECLARE @locked TABLE (
        entry_sno INT, com_sno INT, div_sno INT, brn_sno INT, dept_sno INT,
        vendor_sno INT, service_sno INT, entry_date DATE, qty DECIMAL(18,4),
        unit INT, unit_price DECIMAL(18,4), total_amount DECIMAL(18,4),
        specification NVARCHAR(500), remarks NVARCHAR(500)
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE e
        SET status = 'PROCESSING'
        OUTPUT inserted.entry_sno, inserted.com_sno, inserted.div_sno, inserted.brn_sno, inserted.dept_sno,
               inserted.vendor_sno, inserted.service_sno, inserted.entry_date, inserted.qty,
               inserted.unit, inserted.unit_price, inserted.total_amount,
               inserted.specification, inserted.remarks
        INTO @locked
        FROM dbo.service_vendor_daily_entry e WITH (UPDLOCK, HOLDLOCK)
        WHERE e.entry_sno IN (SELECT TRY_CAST(value AS INT) FROM OPENJSON(@entry_snos))
          AND e.status = 'PENDING' AND e.is_active = 'Y';

        IF (SELECT COUNT(*) FROM @locked) <> @requestedCount
            THROW 54122, 'One or more selected entries are no longer available (already consolidated, cancelled, or claimed by another request). Reload and try again.', 1;

        IF (SELECT COUNT(DISTINCT vendor_sno) FROM @locked) > 1
            THROW 54123, 'All selected entries must belong to the same vendor.', 1;

        IF (SELECT COUNT(DISTINCT CAST(com_sno AS VARCHAR(20)) + '-' + CAST(div_sno AS VARCHAR(20)) + '-' + CAST(brn_sno AS VARCHAR(20)) + '-' + CAST(dept_sno AS VARCHAR(20))) FROM @locked) > 1
            THROW 54124, 'All selected entries must belong to the same company/division/branch/department.', 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT * FROM @locked ORDER BY entry_date, entry_sno;
END;
GO

-- ==== sp_nt_MarkAgreementNotificationSent ====
CREATE PROCEDURE dbo.sp_nt_MarkAgreementNotificationSent
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @agreement_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
    DECLARE @billing_period_start DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.billing_period_start') AS DATE);
    DECLARE @status               VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @notif_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.notif_sno') AS INT);
    DECLARE @error_message        NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.error_message');

    IF @agreement_sno IS NULL OR @billing_period_start IS NULL OR @status NOT IN ('SENT', 'FAILED')
        THROW 53024, 'agreement_sno, billing_period_start and a status of SENT or FAILED are required.', 1;

    UPDATE dbo.service_agreement_notification_log
    SET status = @status, notif_sno = @notif_sno, error_message = @error_message, modified_at = GETDATE()
    WHERE agreement_sno = @agreement_sno AND billing_period_start = @billing_period_start AND status = 'PENDING';

    SELECT @@ROWCOUNT AS rows_updated;
END;
GO

-- ==== sp_nt_ProcessDueRecurringServiceAgreements ====
CREATE PROCEDURE dbo.sp_nt_ProcessDueRecurringServiceAgreements
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @today DATE = CAST(GETDATE() AS DATE);

    DECLARE @due TABLE (agreement_sno INT, billing_period_start DATE);

    INSERT INTO @due (agreement_sno, billing_period_start)
    SELECT sa.agreement_sno, @today
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    WHERE sa.status = 'A' AND sa.is_active = 'Y' AND st.service_type_code = 'FIXED_RECURRING'
      AND @today BETWEEN sa.period_start_date AND sa.period_end_date
      AND (
            -- DAY-unit cadences (e.g. FIFTEEN_DAYS): unchanged.
            (rc.interval_unit = 'DAY' AND DATEDIFF(DAY, sa.period_start_date, @today) % rc.interval_value = 0)

            -- MONTH-unit, explicit po_generation_day set: NEW branch.
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NOT NULL
             AND DATEDIFF(MONTH, sa.period_start_date, @today) % rc.interval_value = 0
             AND (DAY(@today) = sa.po_generation_day
                  OR (sa.po_generation_day > DAY(EOMONTH(@today)) AND @today = EOMONTH(@today))))

            -- MONTH-unit, no po_generation_day (pre-existing agreements from
            -- before this file, or any future one that leaves it unset on a
            -- DAY-unit cadence's sibling path): original anniversary predicate, unchanged.
         OR (rc.interval_unit = 'MONTH' AND sa.po_generation_day IS NULL
             AND DATEADD(MONTH, (DATEDIFF(MONTH, sa.period_start_date, @today) / rc.interval_value) * rc.interval_value, sa.period_start_date) = @today)
          )
      AND NOT EXISTS (
          SELECT 1 FROM dbo.service_agreement_recurring_pr_log l
          WHERE l.agreement_sno = sa.agreement_sno AND l.billing_period_start = @today
      );

    DECLARE @agreement_sno INT, @billing_period_start DATE;
    DECLARE @success_count INT = 0, @skipped_count INT = 0, @failed_count INT = 0;
    DECLARE @row_result VARCHAR(30), @row_po INT, @row_po_no VARCHAR(50), @row_pr INT, @row_pr_no VARCHAR(20), @rowJson NVARCHAR(MAX);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT agreement_sno, billing_period_start FROM @due;
    OPEN cur;
    FETCH NEXT FROM cur INTO @agreement_sno, @billing_period_start;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @rowJson = (
            SELECT @agreement_sno AS agreement_sno, @billing_period_start AS billing_period_start, 'SYSTEM' AS issued_by
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC dbo.sp_nt_IssueRecurringServicePOCycle
            @jsonInput = @rowJson, @silent = 1,
            @out_result = @row_result OUTPUT, @out_po_basic_sno = @row_po OUTPUT, @out_po_no = @row_po_no OUTPUT,
            @out_pr_basic_sno = @row_pr OUTPUT, @out_pr_no = @row_pr_no OUTPUT;

        IF @row_result = 'SUCCESS'
            SET @success_count = @success_count + 1;
        ELSE IF @row_result LIKE 'SKIPPED%'
            SET @skipped_count = @skipped_count + 1;
        ELSE
            SET @failed_count = @failed_count + 1;

        FETCH NEXT FROM cur INTO @agreement_sno, @billing_period_start;
    END
    CLOSE cur;
    DEALLOCATE cur;

    SELECT
        (SELECT COUNT(*) FROM @due) AS due_count,
        @success_count AS success_count,
        @skipped_count AS skipped_count,
        @failed_count  AS failed_count;
END;
GO

-- ==== sp_nt_ReleaseServiceVendorEntriesLock ====
CREATE PROCEDURE dbo.sp_nt_ReleaseServiceVendorEntriesLock
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @entry_snos NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.entry_snos');
    IF @entry_snos IS NULL
        THROW 54140, 'entry_snos is required.', 1;

    UPDATE dbo.service_vendor_daily_entry
    SET status = 'PENDING'
    WHERE entry_sno IN (SELECT TRY_CAST(value AS INT) FROM OPENJSON(@entry_snos))
      AND status = 'PROCESSING';

    SELECT @@ROWCOUNT AS updated_count;
END;
GO

-- ==== sp_nt_RetryServiceBillRequestPOIssue ====
CREATE PROCEDURE dbo.sp_nt_RetryServiceBillRequestPOIssue
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @bill_request_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.bill_request_sno') AS INT);
    DECLARE @issued_by VARCHAR(20) = ISNULL(JSON_VALUE(@jsonInput, '$.issued_by'), 'SYSTEM');

    IF @bill_request_sno IS NULL
        THROW 56030, 'bill_request_sno is required.', 1;

    DECLARE @status CHAR(1), @po_basic_sno INT;
    SELECT @status = status, @po_basic_sno = po_basic_sno FROM dbo.service_bill_request WHERE bill_request_sno = @bill_request_sno;

    IF @status IS NULL
        THROW 56031, 'Service bill request not found.', 1;
    IF @status <> 'A'
        THROW 56032, 'Only an Approved Service bill request can have its PO (re)issued.', 1;
    IF @po_basic_sno IS NOT NULL
    BEGIN
        SELECT 'ALREADY_ISSUED' AS result, @bill_request_sno AS bill_request_sno, @po_basic_sno AS po_basic_sno;
        RETURN;
    END

    DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @service_sno INT, @vendor_sno INT,
            @billing_period_start DATE, @billing_period_end DATE,
            @ceiling_amount DECIMAL(18,2), @variance_tolerance_pct DECIMAL(5,2), @agreement_sno INT;

    SELECT @com_sno = sbr.com_sno, @div_sno = sbr.div_sno, @brn_sno = sbr.brn_sno, @dept_sno = sbr.dept_sno,
           @service_sno = sbr.service_sno, @vendor_sno = sbr.vendor_sno,
           @billing_period_start = sbr.billing_period_start, @billing_period_end = sbr.billing_period_end,
           @agreement_sno = sbr.agreement_sno, @ceiling_amount = sa.ceiling_amount,
           @variance_tolerance_pct = sa.variance_tolerance_pct
    FROM dbo.service_bill_request sbr
    JOIN dbo.service_agreement sa ON sa.agreement_sno = sbr.agreement_sno
    WHERE sbr.bill_request_sno = @bill_request_sno;

    DECLARE @itemsJson NVARCHAR(MAX) = (
        SELECT service_sno, qty, uom_sno, unit_price, remarks
        FROM dbo.service_bill_request_item_details
        WHERE bill_request_sno = @bill_request_sno AND is_active = 'Y'
        FOR JSON PATH
    );

    DECLARE @poJson NVARCHAR(MAX) = (
        SELECT @com_sno AS com_sno, @div_sno AS div_sno, @brn_sno AS brn_sno, @dept_sno AS dept_sno,
               @vendor_sno AS vendor_sno, 1 AS is_retrospective,
               JSON_QUERY(@itemsJson) AS items, 'RECURRING' AS po_type,
               @billing_period_start AS validity_from, @billing_period_end AS validity_to,
               @ceiling_amount AS ceiling_amount, @variance_tolerance_pct AS variance_tolerance_pct,
               @issued_by AS issued_by,
               (N'Auto-issued Service PO (retry) — Service Bill Request ' + CAST(@bill_request_sno AS VARCHAR(10))) AS source_note,
               (N'Variable Recurring service PO — Bill Request ' + CAST(@bill_request_sno AS VARCHAR(10))) AS purpose
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    DECLARE @out_result VARCHAR(30), @out_po_basic_sno INT, @out_po_no VARCHAR(50);
    EXEC dbo.sp_nt_DirectIssueServicePO
        @jsonInput = @poJson, @silent = 1,
        @out_result = @out_result OUTPUT, @out_po_basic_sno = @out_po_basic_sno OUTPUT, @out_po_no = @out_po_no OUTPUT;

    IF @out_po_basic_sno IS NOT NULL
        UPDATE dbo.service_bill_request SET po_basic_sno = @out_po_basic_sno WHERE bill_request_sno = @bill_request_sno;

    SELECT @out_result AS result, @bill_request_sno AS bill_request_sno, @out_po_basic_sno AS po_basic_sno, @out_po_no AS po_no, @vendor_sno AS vendor_sno;
END;
GO

-- ==== sp_nt_ReviseServicePOCeiling ====
CREATE PROCEDURE dbo.sp_nt_ReviseServicePOCeiling
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @po_basic_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT);
        DECLARE @new_ceiling_amount     DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @new_variance_tolerance DECIMAL(5,2)  = TRY_CAST(JSON_VALUE(@jsonInput, '$.variance_tolerance_pct') AS DECIMAL(5,2));
        DECLARE @revised_by             VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.revised_by');
        DECLARE @comments               VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.comments');

        IF @po_basic_sno IS NULL OR @revised_by IS NULL
            THROW 52020, 'po_basic_sno and revised_by are required.', 1;

        IF @new_ceiling_amount IS NULL AND @new_variance_tolerance IS NULL
            THROW 52021, 'At least one of ceiling_amount or variance_tolerance_pct must be supplied.', 1;

        DECLARE @old_ceiling DECIMAL(18,2), @old_tolerance DECIMAL(5,2), @status CHAR(1), @service_type_code VARCHAR(30);
        SELECT @old_ceiling = po.ceiling_amount, @old_tolerance = po.variance_tolerance_pct, @status = po.status,
               @service_type_code = st.service_type_code
        FROM dbo.po_request_info po
        JOIN dbo.service_type_master st ON st.service_type_sno = po.service_type_sno
        WHERE po.po_basic_sno = @po_basic_sno AND po.is_active = 'Y';

        IF @status IS NULL
            THROW 52022, 'Service PO not found or inactive.', 1;

        IF @status <> 'A'
            THROW 52023, 'Only an Approved Service PO can have its ceiling/tolerance revised.', 1;

        IF @service_type_code <> 'VARIABLE_RECURRING'
            THROW 52024, 'Ceiling/tolerance revision only applies to Variable Recurring Service POs.', 1;

        UPDATE dbo.po_request_info
        SET ceiling_amount         = ISNULL(@new_ceiling_amount, ceiling_amount),
            variance_tolerance_pct = ISNULL(@new_variance_tolerance, variance_tolerance_pct)
        WHERE po_basic_sno = @po_basic_sno;

        -- Column list matches sp_nt_ApproveServicePO's own proven INSERT
        -- shape into this table (07_po_service_extensions.sql) — status/
        -- status_date are left to their column defaults, not supplied here.
        INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
        VALUES (
            @po_basic_sno, 'CEILING_REVISED', @revised_by,
            CONCAT(
                'Ceiling ', FORMAT(ISNULL(@old_ceiling, 0), 'N2'), ' -> ', FORMAT(ISNULL(@new_ceiling_amount, @old_ceiling), 'N2'),
                '; Tolerance% ', FORMAT(ISNULL(@old_tolerance, 0), 'N2'), ' -> ', FORMAT(ISNULL(@new_variance_tolerance, @old_tolerance), 'N2'),
                ISNULL(N'; ' + @comments, N'')
            ),
            'Y'
        );

        COMMIT TRANSACTION;

        SELECT
            @po_basic_sno AS po_basic_sno,
            ISNULL(@new_ceiling_amount, @old_ceiling)         AS ceiling_amount,
            ISNULL(@new_variance_tolerance, @old_tolerance)   AS variance_tolerance_pct,
            'SUCCESS' AS result;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==== sp_nt_UpdateServiceAgreement ====
CREATE PROCEDURE dbo.sp_nt_UpdateServiceAgreement
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @agreement_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.agreement_sno') AS INT);
        DECLARE @com_sno              INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno              INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno              INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno             INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @service_sno          INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);
        DECLARE @vendor_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @rate_amount          DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_amount') AS DECIMAL(18,2));
        DECLARE @rate_uom_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_uom_sno') AS INT);
        DECLARE @ceiling_amount       DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.ceiling_amount') AS DECIMAL(18,2));
        DECLARE @variance_tolerance_pct DECIMAL(5,2)= TRY_CAST(JSON_VALUE(@jsonInput, '$.variance_tolerance_pct') AS DECIMAL(5,2));
        DECLARE @recurrence_cadence   VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.recurrence_cadence');
        DECLARE @recurrence_cadence_sno INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_cadence_sno') AS INT);
        DECLARE @po_generation_day    SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_generation_day') AS SMALLINT);
        DECLARE @notify_days_before   SMALLINT      = TRY_CAST(JSON_VALUE(@jsonInput, '$.notify_days_before') AS SMALLINT);
        DECLARE @period_start_date    DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_start_date') AS DATE);
        DECLARE @period_end_date      DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_end_date') AS DATE);
        DECLARE @agreement_doc_url    NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.agreement_doc_url');
        DECLARE @remarks              NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @edited_by            VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.edited_by');

        IF @agreement_sno IS NULL
            THROW 53030, 'agreement_sno is required.', 1;

        IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
            OR @service_sno IS NULL OR @edited_by IS NULL
            THROW 53001, 'com_sno, div_sno, brn_sno, dept_sno, service_sno and edited_by are required.', 1;

        IF @period_start_date IS NULL OR @period_end_date IS NULL OR @period_end_date <= @period_start_date
            THROW 53003, 'period_start_date and period_end_date are required, and the period must end after it starts.', 1;

        IF @agreement_doc_url IS NULL OR LTRIM(RTRIM(@agreement_doc_url)) = ''
            THROW 53004, 'agreement_doc_url is required — upload the agreement document before submitting.', 1;

        DECLARE @current_status VARCHAR(1);
        SELECT @current_status = status
        FROM dbo.service_agreement WITH (UPDLOCK, HOLDLOCK)
        WHERE agreement_sno = @agreement_sno AND is_active = 'Y';

        IF @current_status IS NULL
            THROW 53031, 'Service agreement not found or inactive.', 1;

        IF @current_status NOT IN ('A', 'R')
            THROW 53032, 'Only an Approved or Rejected agreement can be edited (it is currently Pending approval).', 1;

        -- ── Resolve recurrence cadence against the master (mandatory) ──────
        IF @recurrence_cadence_sno IS NULL AND @recurrence_cadence IS NOT NULL
            SELECT @recurrence_cadence_sno = recurrence_cadence_sno
            FROM dbo.recurrence_cadence_master
            WHERE cadence_code = @recurrence_cadence AND is_active = 'Y';

        IF @recurrence_cadence_sno IS NULL
            THROW 53020, 'recurrence_cadence_sno (or a matching recurrence_cadence code) is required — see sp_nt_GetRecurrenceCadenceRecords for valid options.', 1;

        DECLARE @interval_unit VARCHAR(10);
        SELECT @recurrence_cadence = cadence_code, @interval_unit = interval_unit
        FROM dbo.recurrence_cadence_master
        WHERE recurrence_cadence_sno = @recurrence_cadence_sno AND is_active = 'Y';

        IF @recurrence_cadence IS NULL
            THROW 53021, 'recurrence_cadence_sno does not reference an active recurrence cadence.', 1;

        DECLARE @service_type_code VARCHAR(30), @is_recurring BIT;
        SELECT @service_type_code = st.service_type_code,
               @is_recurring      = sm.is_recurring
        FROM dbo.service_master sm
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        WHERE sm.service_sno = @service_sno AND sm.is_active = 'Y';

        IF @service_type_code IS NULL
            THROW 53005, 'Unknown or inactive service_sno.', 1;

        IF ISNULL(@is_recurring, 0) = 0 OR @service_type_code NOT IN ('FIXED_RECURRING', 'VARIABLE_RECURRING')
            THROW 53006, 'service_sno must reference an active Fixed Recurring or Variable Recurring, recurring service.', 1;

        IF @service_type_code = 'FIXED_RECURRING'
        BEGIN
            IF @rate_amount IS NULL OR @rate_amount <= 0
                THROW 53002, 'rate_amount must be a positive amount.', 1;

            IF @interval_unit = 'MONTH'
            BEGIN
                IF @po_generation_day IS NULL OR @po_generation_day NOT BETWEEN 1 AND 31
                    THROW 53022, 'po_generation_day (1-31) is required for a Fixed Recurring agreement on a monthly-family cadence.', 1;
            END
            ELSE
                SET @po_generation_day = NULL;

            IF @notify_days_before IS NOT NULL AND @notify_days_before < 0
                THROW 53023, 'notify_days_before must not be negative.', 1;
        END
        ELSE -- VARIABLE_RECURRING
        BEGIN
            IF @ceiling_amount IS NULL OR @ceiling_amount <= 0
                THROW 53010, 'ceiling_amount must be a positive amount for a Variable Recurring agreement.', 1;
            IF @variance_tolerance_pct IS NULL
                THROW 53011, 'variance_tolerance_pct is required for a Variable Recurring agreement.', 1;

            SET @po_generation_day = NULL;

            IF @notify_days_before IS NOT NULL AND @notify_days_before < 0
                THROW 53023, 'notify_days_before must not be negative.', 1;
        END

        -- ── Re-resolve the ServiceAgreement workflow for this org scope ────
        DECLARE @workflow_types_id INT, @first_approver VARCHAR(30);

        SELECT @workflow_types_id = wt.workflow_types_id
        FROM dbo.workflow_types wt
        INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
        WHERE wt.com_sno = @com_sno AND wt.div_sno = @div_sno
          AND wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno
          AND awm.entity_type = 'ServiceAgreement';

        IF @workflow_types_id IS NULL
            THROW 53007, 'No ServiceAgreement workflow configuration found for this company/division/branch/department.', 1;

        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM dbo.vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key] = '0' AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 53008, 'No approver found for the first stage of the ServiceAgreement workflow.', 1;

        UPDATE dbo.service_agreement
        SET com_sno = @com_sno, div_sno = @div_sno, brn_sno = @brn_sno, dept_sno = @dept_sno,
            service_sno = @service_sno, vendor_sno = @vendor_sno,
            rate_amount = @rate_amount, rate_uom_sno = @rate_uom_sno,
            ceiling_amount = @ceiling_amount, variance_tolerance_pct = @variance_tolerance_pct,
            recurrence_cadence = @recurrence_cadence, recurrence_cadence_sno = @recurrence_cadence_sno,
            po_generation_day = @po_generation_day, notify_days_before = @notify_days_before,
            period_start_date = @period_start_date, period_end_date = @period_end_date,
            agreement_doc_url = @agreement_doc_url, remarks = @remarks,
            workflow_types_id = @workflow_types_id, current_approver_id = @first_approver,
            status = 'P',
            modified_by = @edited_by, modified_at = GETDATE()
        WHERE agreement_sno = @agreement_sno;

        INSERT INTO dbo.service_agreement_history (agreement_sno, action_type, status_by, comment, is_active)
        VALUES (@agreement_sno, 'RESUBMITTED', @edited_by, @remarks, 'Y');

        COMMIT TRANSACTION;

        SELECT
            @agreement_sno AS agreement_sno,
            'SUCCESS'      AS result,
            N'Service agreement updated and resubmitted for approval.' AS message;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==== sp_nt_CreateCallOffPO ====
CREATE PROCEDURE dbo.sp_nt_CreateCallOffPO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @parent_blanket_po_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.parent_blanket_po_sno') AS INT);
        DECLARE @invoice_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_sno') AS INT);
        DECLARE @delivery_address      VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.delivery_address');
        DECLARE @terms_conditions      VARCHAR(MAX)  = JSON_VALUE(@jsonInput, '$.terms_conditions');
        DECLARE @purpose               VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.purpose');
        DECLARE @created_by            VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
        DECLARE @items                 NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');

        IF @parent_blanket_po_sno IS NULL OR @created_by IS NULL
            THROW 56001, 'parent_blanket_po_sno and created_by are required.', 1;

        IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
            THROW 56002, 'At least one item is required.', 1;

        DECLARE @vendor_sno INT, @service_type_sno INT, @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @parentStatus VARCHAR(10), @parentPoType VARCHAR(20);
        SELECT
            @vendor_sno = vendor_sno, @service_type_sno = service_type_sno,
            @com_sno = com_sno, @div_sno = div_sno, @brn_sno = brn_sno, @dept_sno = dept_sno,
            @parentStatus = status, @parentPoType = po_type
        FROM dbo.po_request_info
        WHERE po_basic_sno = @parent_blanket_po_sno;

        IF @vendor_sno IS NULL
            THROW 56003, 'parent_blanket_po_sno not found.', 1;

        IF @parentStatus <> 'A' OR @parentPoType <> 'STANDING'
            THROW 56004, 'The parent PO must be an approved Standing PO to accept call-offs.', 1;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
        FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
        WHERE po_df_no LIKE 'CO-' + @year + '-%';
        DECLARE @po_no VARCHAR(50) = 'CO-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.po_request_info (
            vendor_sno, brn_sno, dept_sno, com_sno, div_sno, po_date, purpose, terms_conditions, delivery_address,
            is_active, workflow_types_id, current_approver_id, status, po_df_no,
            po_type, service_type_sno, is_retrospective, parent_blanket_po_sno, consumed_amount
        )
        VALUES (
            @vendor_sno, @brn_sno, @dept_sno, @com_sno, @div_sno, CAST(GETDATE() AS DATE), @purpose, @terms_conditions, @delivery_address,
            'Y', NULL, NULL, 'A', @po_no,
            'ONE_TIME', @service_type_sno, 1, @parent_blanket_po_sno, 0
        );

        DECLARE @po_basic_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.po_item_details (
            po_basic_sno, service_sno, prod_name, specification, qty, unit, unit_name,
            agreed_unit_price, total_cost, net_cost, remarks, po_section, created_by, created_date, is_active
        )
        SELECT
            @po_basic_sno,
            TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT),
            sm.service_name,
            JSON_VALUE(j.value, '$.specification'),
            TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)),
            TRY_CAST(JSON_VALUE(j.value, '$.unit') AS INT),
            um.uom_name,
            TRY_CAST(JSON_VALUE(j.value, '$.agreed_unit_price') AS DECIMAL(18,4)),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 0) * ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.agreed_unit_price') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.net_cost') AS DECIMAL(18,4)),
                   ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 0) * ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.agreed_unit_price') AS DECIMAL(18,4)), 0)),
            JSON_VALUE(j.value, '$.remarks'),
            'SERVICE',
            -- po_item_details.is_active uses '1'/'0' (see 07_po_service_extensions.sql's note)
            @created_by, GETDATE(), '1'
        FROM OPENJSON(@items) j
        LEFT JOIN dbo.service_master sm ON sm.service_sno = TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT)
        LEFT JOIN dbo.uom_master um     ON um.uom_sno = TRY_CAST(JSON_VALUE(j.value, '$.unit') AS INT);

        IF @@ROWCOUNT = 0
            THROW 56005, 'No items were inserted.', 1;

        -- Optionally link the already-captured pre-PO invoice to this call-off PO
        IF @invoice_sno IS NOT NULL
        BEGIN
            UPDATE dbo.invoice_info SET po_basic_sno = @po_basic_sno, modified_date = GETDATE()
            WHERE invoice_sno = @invoice_sno;
        END

        COMMIT TRANSACTION;

        SELECT @po_basic_sno AS po_basic_sno, @po_no AS po_no, @parent_blanket_po_sno AS parent_blanket_po_sno, 'SUCCESS' AS result;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==== sp_nt_CreateServiceEntry ====
CREATE PROCEDURE dbo.sp_nt_CreateServiceEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @po_basic_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT);
        DECLARE @vendor_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @period_from     DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_from') AS DATE);
        DECLARE @period_to       DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_to') AS DATE);
        DECLARE @usage_reference VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.usage_reference');
        DECLARE @created_by      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
        DECLARE @com_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @items           NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');

        IF @po_basic_sno IS NULL OR @created_by IS NULL
            THROW 53001, 'po_basic_sno and created_by are required.', 1;

        IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
            THROW 53002, 'At least one item is required.', 1;

        DECLARE @variance_tolerance_pct DECIMAL(5,2), @service_type_sno INT, @po_status VARCHAR(10);
        SELECT @variance_tolerance_pct = variance_tolerance_pct,
               @service_type_sno = service_type_sno,
               @po_status = status
        FROM dbo.po_request_info
        WHERE po_basic_sno = @po_basic_sno;

        IF @service_type_sno IS NULL
            THROW 53003, 'po_basic_sno does not reference a Service PO.', 1;

        IF @po_status <> 'A'
            THROW 53004, 'Service PO must be approved before a Service Entry can be raised against it.', 1;

        -- Snapshot each item's budgeted amount (po_item_details.net_cost) so
        -- variance is measured against what the PO actually agreed, not a
        -- moving target.
        DECLARE @lineItems TABLE (
            po_item_sno    INT,
            service_sno    INT,
            uom_sno        INT,
            billed_qty     DECIMAL(10,3),
            unit_price     DECIMAL(18,2),
            po_amount      DECIMAL(18,2),
            confirmed_amount DECIMAL(18,2),
            remarks        VARCHAR(500)
        );

        INSERT INTO @lineItems (po_item_sno, service_sno, uom_sno, billed_qty, unit_price, po_amount, confirmed_amount, remarks)
        SELECT
            TRY_CAST(JSON_VALUE(j.value, '$.po_item_sno') AS INT),
            TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT),
            TRY_CAST(JSON_VALUE(j.value, '$.uom_sno') AS INT),
            TRY_CAST(JSON_VALUE(j.value, '$.billed_qty') AS DECIMAL(10,3)),
            TRY_CAST(JSON_VALUE(j.value, '$.unit_price') AS DECIMAL(18,2)),
            ISNULL(pid.net_cost, 0),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.confirmed_amount') AS DECIMAL(18,2)), 0),
            JSON_VALUE(j.value, '$.remarks')
        FROM OPENJSON(@items) j
        JOIN dbo.po_item_details pid ON pid.po_item_sno = TRY_CAST(JSON_VALUE(j.value, '$.po_item_sno') AS INT);

        DECLARE @totalConfirmed DECIMAL(18,2), @totalBudgeted DECIMAL(18,2);
        SELECT @totalConfirmed = SUM(confirmed_amount), @totalBudgeted = SUM(po_amount) FROM @lineItems;

        DECLARE @variance_pct DECIMAL(9,4) = NULL, @variance_status VARCHAR(20) = 'N/A';
        DECLARE @status VARCHAR(20) = 'Approved';
        DECLARE @workflow_types_id INT = NULL, @current_approver_id VARCHAR(20) = NULL;

        IF @variance_tolerance_pct IS NOT NULL AND ISNULL(@totalBudgeted, 0) > 0
        BEGIN
            SET @variance_pct = (@totalConfirmed - @totalBudgeted) / @totalBudgeted * 100.0;

            IF ABS(@variance_pct) > @variance_tolerance_pct
            BEGIN
                SET @variance_status = 'EXCEEDED';
                SET @status = 'Pending';

                DECLARE @workflow_id INT;
                SELECT @workflow_id = wt.workflow_id, @workflow_types_id = wt.workflow_types_id
                FROM dbo.workflow_types wt
                INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
                WHERE wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno AND wt.com_sno = @com_sno AND wt.div_sno = @div_sno
                  AND awm.entity_type = 'ServiceEntry';

                IF @workflow_types_id IS NULL
                    THROW 53005, 'No ServiceEntry workflow configuration found for this branch and department (variance exceeded tolerance).', 1;

                SELECT @current_approver_id = JSON_VALUE(s2.value, '$.approver_ecno')
                FROM dbo.vw_workflow_stages AS ws
                CROSS APPLY OPENJSON(ws.stages_json) AS s
                CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
                WHERE ws.workflow_types_id = @workflow_types_id
                  AND s.[key] = '0' AND s2.[key] = '0';

                IF @current_approver_id IS NULL
                    THROW 53006, 'No approver found for the first stage of the ServiceEntry workflow.', 1;
            END
            ELSE
            BEGIN
                SET @variance_status = 'WITHIN_TOLERANCE';
            END
        END

        DECLARE @service_entry_no INT;
        SELECT @service_entry_no = ISNULL(MAX(service_entry_no), 0) + 1 FROM dbo.service_entry_info;

        INSERT INTO dbo.service_entry_info (
            service_entry_no, com_sno, div_sno, brn_sno, dept_sno, po_basic_sno, vendor_sno,
            period_from, period_to, usage_reference, confirmed_amount, variance_pct, variance_status,
            accept_reject_flag, is_active, workflow_types_id, current_approver_id, status,
            created_by, created_date
        )
        VALUES (
            @service_entry_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @po_basic_sno, @vendor_sno,
            @period_from, @period_to, @usage_reference, ISNULL(@totalConfirmed, 0), @variance_pct, @variance_status,
            'Accepted', 'Y', @workflow_types_id, @current_approver_id, @status,
            @created_by, GETDATE()
        );

        DECLARE @service_entry_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.service_entry_item_details (
            service_entry_sno, po_item_sno, service_sno, uom_sno, billed_qty, unit_price,
            po_amount, confirmed_amount, diff_amount, accept_reject_flag, remarks, created_by, created_date, is_active
        )
        SELECT
            @service_entry_sno, po_item_sno, service_sno, uom_sno, billed_qty, unit_price,
            po_amount, confirmed_amount, (confirmed_amount - po_amount), 'Accepted', remarks, @created_by, GETDATE(), 'Y'
        FROM @lineItems;

        -- Track ceiling consumption
        UPDATE dbo.po_request_info
        SET consumed_amount = ISNULL(consumed_amount, 0) + ISNULL(@totalConfirmed, 0)
        WHERE po_basic_sno = @po_basic_sno;

        COMMIT TRANSACTION;

        SELECT
            @service_entry_sno   AS service_entry_sno,
            @service_entry_no    AS service_entry_no,
            @status               AS status,
            @variance_pct         AS variance_pct,
            @variance_status      AS variance_status,
            'SUCCESS'             AS result;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==== sp_nt_ApproveServiceEntry ====
CREATE PROCEDURE dbo.sp_nt_ApproveServiceEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @service_entry_sno INT          = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_entry_sno') AS INT);
        DECLARE @approved_by       VARCHAR(20)  = JSON_VALUE(@jsonInput, '$.approved_by');
        DECLARE @comments          VARCHAR(500) = JSON_VALUE(@jsonInput, '$.comments');
        DECLARE @action            VARCHAR(20)  = LOWER(ISNULL(JSON_VALUE(@jsonInput, '$.action'), ''));

        IF @service_entry_sno IS NULL OR @approved_by IS NULL
            THROW 53010, 'service_entry_sno and approved_by are required.', 1;

        IF @action NOT IN ('approve', 'reject')
            THROW 53011, 'action must be ''approve'' or ''reject''.', 1;

        IF NOT EXISTS (SELECT 1 FROM dbo.service_entry_info WHERE service_entry_sno = @service_entry_sno AND status = 'Pending')
            THROW 53012, 'Service Entry not found or not pending approval.', 1;

        UPDATE dbo.service_entry_info
        SET status = CASE WHEN @action = 'approve' THEN 'Approved' ELSE 'Rejected' END,
            current_approver_id = NULL,
            approved_by = @approved_by,
            approved_at = GETDATE(),
            approval_comments = @comments
        WHERE service_entry_sno = @service_entry_sno;

        -- A rejected entry's confirmed amount should not count against the
        -- ceiling any more.
        IF @action = 'reject'
        BEGIN
            UPDATE p
            SET p.consumed_amount = p.consumed_amount - se.confirmed_amount
            FROM dbo.po_request_info p
            JOIN dbo.service_entry_info se ON se.po_basic_sno = p.po_basic_sno
            WHERE se.service_entry_sno = @service_entry_sno;
        END

        SELECT
            @service_entry_sno AS service_entry_sno,
            CASE WHEN @action = 'approve' THEN 'Approved' ELSE 'Rejected' END AS status,
            @approved_by AS approved_by,
            GETDATE() AS approved_at,
            'SUCCESS' AS result;
    END TRY
    BEGIN CATCH
        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO

-- ==== sp_nt_GetPendingServicePOsForServiceEntry ====
CREATE PROCEDURE dbo.sp_nt_GetPendingServicePOsForServiceEntry
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @vendor_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @vendor_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);

    SELECT
        p.po_basic_sno,
        p.po_df_no AS po_no,
        p.vendor_sno,
        k.company_name AS vendor_name,
        p.po_type,
        p.service_type_sno,
        st.service_type_code,
        st.service_type_name,
        p.validity_from,
        p.validity_to,
        p.ceiling_amount,
        p.consumed_amount,
        p.variance_tolerance_pct,
        p.com_sno, p.div_sno, p.brn_sno, p.dept_sno,
        (
            SELECT pid.po_item_sno, pid.service_sno, sm.service_name, pid.unit_name, pid.net_cost
            FROM dbo.po_item_details pid
            LEFT JOIN dbo.service_master sm ON sm.service_sno = pid.service_sno
            -- po_item_details.is_active uses '1'/'0' (see 07_po_service_extensions.sql's note)
            WHERE pid.po_basic_sno = p.po_basic_sno AND pid.is_active = '1' AND pid.po_section = 'SERVICE'
            FOR JSON PATH
        ) AS items
    FROM dbo.po_request_info p
    LEFT JOIN dbo.service_type_master st ON st.service_type_sno = p.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k        ON k.kyc_basic_info_sno = p.vendor_sno
    WHERE p.service_type_sno IS NOT NULL
      AND p.status = 'A'
      AND p.is_active = 'Y'
      AND (@vendor_sno IS NULL OR p.vendor_sno = @vendor_sno)
    ORDER BY p.po_basic_sno DESC;
END;
GO

-- ==== sp_nt_GetServiceEntriesByPO ====
CREATE PROCEDURE dbo.sp_nt_GetServiceEntriesByPO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT);

    SELECT
        se.service_entry_sno, se.service_entry_no, se.po_basic_sno, p.po_df_no AS po_no,
        se.vendor_sno, k.company_name AS vendor_name,
        se.period_from, se.period_to, se.usage_reference,
        se.confirmed_amount, se.variance_pct, se.variance_status,
        se.status, se.current_approver_id, se.approved_by, se.approved_at,
        se.created_by, se.created_date,
        (
            SELECT sei.service_entry_item_sno, sei.po_item_sno, sei.service_sno, sm.service_name,
                   sei.billed_qty, sei.unit_price, sei.po_amount, sei.confirmed_amount, sei.diff_amount
            FROM dbo.service_entry_item_details sei
            LEFT JOIN dbo.service_master sm ON sm.service_sno = sei.service_sno
            WHERE sei.service_entry_sno = se.service_entry_sno AND sei.is_active = 'Y'
            FOR JSON PATH
        ) AS items
    FROM dbo.service_entry_info se
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = se.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = se.vendor_sno
    WHERE se.po_basic_sno = @po_basic_sno AND se.is_active = 'Y'
    ORDER BY se.service_entry_sno DESC;
END;
GO

-- ==== sp_nt_GetAllServiceEntries ====
CREATE PROCEDURE dbo.sp_nt_GetAllServiceEntries
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = NULL, @Ecno VARCHAR(50) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @status = JSON_VALUE(@jsonInput, '$.status');
        SET @Ecno = JSON_VALUE(@jsonInput, '$.Ecno');
    END

    SELECT
        se.service_entry_sno, se.service_entry_no, se.po_basic_sno, p.po_df_no AS po_no,
        se.vendor_sno, k.company_name AS vendor_name,
        se.period_from, se.period_to, se.usage_reference,
        se.confirmed_amount, se.variance_pct, se.variance_status,
        se.status, se.current_approver_id, se.approved_by, se.approved_at,
        se.created_by, se.created_date,
        (
            SELECT sei.service_entry_item_sno, sei.po_item_sno, sei.service_sno, sm.service_name,
                   sei.billed_qty, sei.unit_price, sei.po_amount, sei.confirmed_amount, sei.diff_amount
            FROM dbo.service_entry_item_details sei
            LEFT JOIN dbo.service_master sm ON sm.service_sno = sei.service_sno
            WHERE sei.service_entry_sno = se.service_entry_sno AND sei.is_active = 'Y'
            FOR JSON PATH
        ) AS items
    FROM dbo.service_entry_info se
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = se.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = se.vendor_sno
    WHERE se.is_active = 'Y'
      AND (@status IS NULL OR se.status = @status)
      AND (@Ecno IS NULL OR se.current_approver_id = @Ecno)
    ORDER BY se.service_entry_sno DESC;
END;
GO
