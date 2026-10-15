-- ── sp_nt_CreateServiceAgreement: route by agreement type ─────────────────
CREATE   PROCEDURE dbo.sp_nt_CreateServiceAgreement
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
          AND awm.entity_type = dbo.fn_resolve_approval_entity('ServiceAgreement', @service_type_code);

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