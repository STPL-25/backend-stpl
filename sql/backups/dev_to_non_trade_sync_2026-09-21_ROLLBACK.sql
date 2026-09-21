-- ROLLBACK for the Dev -> Non_Trade sync (2026-09-21T09-56-17-288Z). Run top to bottom. Restores previous procedure text and removes what the sync added.

-- undo [F2. procedures] dbo.usp_ProcessApprovalAction
-- restore previous definition
CREATE OR ALTER PROCEDURE [dbo].[usp_ProcessApprovalAction]
  @bud_dta_sno INT,
  @nt_app_flow_sno INT,
  @ecno NVARCHAR(50),
  @action NVARCHAR(20),          -- 'Approve', 'Reject', 'Hold'
  @comments NVARCHAR(MAX) = NULL,
  @value_change DECIMAL(18,4) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  BEGIN TRY
    BEGIN TRAN;

    -- basic validation: is ecno the current approver?
    DECLARE @current_step_no INT;
    ;WITH FlowSteps AS (
      SELECT fs.step_no, fs.step_ecno
      FROM Non_Trade.dbo.nt_approval_flow af
      CROSS APPLY ( VALUES
         (1, af.nt_app_flow_step1_ecno),
         (2, af.nt_app_flow_step2_ecno),
         (3, af.nt_app_flow_step3_ecno),
         (4, af.nt_app_flow_step4_ecno),
         (5, af.nt_app_flow_step5_ecno),
         (6, af.nt_app_flow_step6_ecno),
         (7, af.nt_app_flow_step7_ecno),
         (8, af.nt_app_flow_step8_ecno),
         (9, af.nt_app_flow_step9_ecno),
         (10, af.nt_app_flow_step10_ecno),
         (11, af.nt_app_flow_step11_ecno),
         (12, af.nt_app_flow_step12_ecno),
         (13, af.nt_app_flow_step13_ecno)
      ) fs(step_no, step_ecno)
      WHERE af.nt_app_flow_sno = @nt_app_flow_sno
    ),
    Approved AS (
      SELECT TRY_CAST(nh.nt_app_his_auth_selection AS INT) AS step_no
      FROM Non_Trade.dbo.nt_approval_history nh
      WHERE nh.nt_app_flow_sno = @nt_app_flow_sno
        AND nh.nt_app_his_status = 'A'
        AND nh.is_active = 1
    )
    SELECT @current_step_no = MIN(fs.step_no)
    FROM FlowSteps fs
    WHERE fs.step_ecno IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM Approved a WHERE a.step_no = fs.step_no)
      AND NOT EXISTS (  -- ensure earlier steps are approved or absent
         SELECT 1 FROM FlowSteps prev
         WHERE prev.step_no < fs.step_no
           AND prev.step_ecno IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM Approved a2 WHERE a2.step_no = prev.step_no)
      );

    IF @current_step_no IS NULL
    BEGIN
      RAISERROR('No pending step found for this flow/item - cannot process approval.', 16, 1);
      ROLLBACK TRAN;
      RETURN;
    END

    -- confirm @ecno matches current step ecno
    DECLARE @expected_ecno NVARCHAR(50);
    SELECT @expected_ecno = fs.step_ecno
    FROM (
      SELECT af.*, fs.step_no, fs.step_ecno
      FROM Non_Trade.dbo.nt_approval_flow af
      CROSS APPLY ( VALUES
         (1, af.nt_app_flow_step1_ecno),
         (2, af.nt_app_flow_step2_ecno),
         (3, af.nt_app_flow_step3_ecno),
         (4, af.nt_app_flow_step4_ecno),
         (5, af.nt_app_flow_step5_ecno),
         (6, af.nt_app_flow_step6_ecno),
         (7, af.nt_app_flow_step7_ecno),
         (8, af.nt_app_flow_step8_ecno),
         (9, af.nt_app_flow_step9_ecno),
         (10, af.nt_app_flow_step10_ecno),
         (11, af.nt_app_flow_step11_ecno),
         (12, af.nt_app_flow_step12_ecno),
         (13, af.nt_app_flow_step13_ecno)
      ) fs(step_no, step_ecno)
      WHERE af.nt_app_flow_sno = @nt_app_flow_sno
    ) AS fs
    WHERE fs.step_no = @current_step_no;

    IF ISNULL(@expected_ecno,'') <> @ecno
    BEGIN
      RAISERROR('User [%s] is not the current approver (expected %s).', 16, 1, @ecno, @expected_ecno);
      ROLLBACK TRAN;
      RETURN;
    END

    -- Insert into history
    INSERT INTO Non_Trade.dbo.nt_approval_history
    (
	--nt_app_flow_sno,
      nt_app_li_sno,
      brn_sno,
      dept_sno,
      com_sno,
      div_sno,
      reference_no,
      nt_app_his_auths,          -- store approver ecno
      nt_app_his_auth_selection, -- store step no
      nt_app_his_status,
      nt_app_his_comments,
      nt_app_his_status_date,
      is_active,
      created_date
    )
    SELECT
      --af.nt_app_flow_sno,
      af.nt_app_li_sno,
      af.brn_sno,
      af.dept_sno,
      af.com_sno,
      af.div_sno,
      NULL, -- reference_no: fill if you have a meaningful ref (e.g. bud_dta_sno)
      @ecno,
      CAST(@current_step_no AS NVARCHAR(10)),
      CASE WHEN @action = 'A' THEN 'A'
           WHEN @action = 'R' THEN 'R'
           WHEN @action = 'P' THEN 'P'
           ELSE @action END,
      @comments,
      GETDATE(),
      1,
      GETDATE()
    FROM Non_Trade.dbo.nt_approval_flow af
    WHERE af.nt_app_flow_sno = @nt_app_flow_sno;

    -- Apply any value change to budget_data_entries if provided (example)
    IF @value_change IS NOT NULL
    BEGIN
      UPDATE Non_Trade.dbo.budget_data_entries
      SET bud_dta_act_unt_cst = @value_change,
          -- track updated date if you have such column, else ignore
          created_date = created_date
      WHERE bud_dta_sno = @bud_dta_sno;
    END

    -- If action = Reject => potentially mark item as rejected (business rule dependent)
    IF @action = 'R'
    BEGIN
      -- mark item inactive or set a status column if exists (example: is_active = 0)
      UPDATE Non_Trade.dbo.budget_data_entries
      SET is_active = 0
      WHERE bud_dta_sno = @bud_dta_sno;
      -- leave transaction and return no next approver
      COMMIT TRAN;
      SELECT NULL AS next_approver_ecno, NULL AS next_step_no, 'R' AS final_status;
      RETURN;
    END

    -- If action was Approve: find next step
    DECLARE @next_step_no INT;
    DECLARE @next_approver_ecno NVARCHAR(50);

    SELECT TOP(1) @next_step_no = fs.step_no, @next_approver_ecno = fs.step_ecno
    FROM (
      SELECT fs.step_no, fs.step_ecno
      FROM Non_Trade.dbo.nt_approval_flow af
      CROSS APPLY ( VALUES
         (1, af.nt_app_flow_step1_ecno),
         (2, af.nt_app_flow_step2_ecno),
         (3, af.nt_app_flow_step3_ecno),
         (4, af.nt_app_flow_step4_ecno),
         (5, af.nt_app_flow_step5_ecno),
         (6, af.nt_app_flow_step6_ecno),
         (7, af.nt_app_flow_step7_ecno),
         (8, af.nt_app_flow_step8_ecno),
         (9, af.nt_app_flow_step9_ecno),
         (10, af.nt_app_flow_step10_ecno),
         (11, af.nt_app_flow_step11_ecno),
         (12, af.nt_app_flow_step12_ecno),
         (13, af.nt_app_flow_step13_ecno)
      ) fs(step_no, step_ecno)
      WHERE af.nt_app_flow_sno = @nt_app_flow_sno
    ) AS fs
    WHERE fs.step_no > @current_step_no
      AND fs.step_ecno IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM Non_Trade.dbo.nt_approval_history nh
        WHERE nh.nt_app_flow_sno = @nt_app_flow_sno
          AND TRY_CAST(nh.nt_app_his_auth_selection AS INT) = fs.step_no
          AND nh.nt_app_his_status = 'A'
          AND nh.is_active = 1
      )
    ORDER BY fs.step_no;

    IF @next_approver_ecno IS NULL
    BEGIN
      -- No more approvers -> mark final state on master if needed (example: update budget_master)
      UPDATE Non_Trade.dbo.budget_master
      SET is_bud_value_approved = 1,
          bud_value_approved_by = @ecno,
          bud_value_approved_date = GETDATE()
      FROM Non_Trade.dbo.budget_master bm
      INNER JOIN Non_Trade.dbo.budget_data_entries bde ON bde.bud_sno = bm.bud_sno
      WHERE bde.bud_dta_sno = @bud_dta_sno;

      COMMIT TRAN;
      SELECT NULL AS next_approver_ecno, NULL AS next_step_no, 'FullyApproved' AS final_status;
      RETURN;
    END

    COMMIT TRAN;
    SELECT @next_approver_ecno AS next_approver_ecno, @next_step_no AS next_step_no, 'InProgress' AS final_status;
    RETURN;

  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRAN;
    DECLARE @errMsg NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR('Error in usp_ProcessApprovalAction: %s',16,1,@errMsg);
    RETURN;
  END CATCH
END

GO
-- undo [F2. procedures] dbo.usp_InsertVendorDrivenPurchaseRequest  (new)
DROP PROCEDURE IF EXISTS [dbo].[usp_InsertVendorDrivenPurchaseRequest];
GO
-- undo [F2. procedures] dbo.usp_InsertPurchaseRequest
-- restore previous definition
-- source_invoice_sno already exists (06_usp_InsertPurchaseRequest_v2.sql) —
-- nothing to add here, this file only starts writing to it.

-- ── usp_InsertPurchaseRequest v4 ────────────────────────────────────────────

CREATE OR ALTER PROCEDURE usp_InsertPurchaseRequest
    @jsonInput NVARCHAR(MAX),
    @pr_no     VARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @com_sno            INT,
                @div_sno            INT,
                @brn_sno            INT,
                @dept_sno           INT,
                @reg_date           DATE,
                @required_date      DATE,
                @priority_sno       INT,
                @purpose            NVARCHAR(500),
                @current_year       VARCHAR(10),   -- FIX 1: was INT, fn returns '26-27'
                @pr_prefix          VARCHAR(20),
                @sequence_number    INT,
                @pr_basic_sno       INT,
                @created_by         VARCHAR(20),
                @workflow_types_id  INT,
                @first_approver     VARCHAR(20),
                @workflow_id        INT,
                @items_inserted     INT,
                @requisition_type   VARCHAR(30),
                @category           VARCHAR(20),
                @source_invoice_sno INT;

        -- FIX 1: @current_year is VARCHAR e.g. '26-27'
        SET @current_year = dbo.fn_GetFinancialYear(GETDATE());
        SET @pr_prefix    = 'PR' + @current_year ;  -- 'PR-26-27-'

        -- FIX 2: Use SUBSTRING+LEN for safe sequence extraction (no CAST truncation)
        SELECT @sequence_number = ISNULL(MAX(
            CASE
                WHEN pr_no LIKE @pr_prefix + '%'
                THEN TRY_CAST(
                         SUBSTRING(pr_no, LEN(@pr_prefix) + 1, LEN(pr_no))
                     AS INT)
                ELSE 0
            END
        ), 0) + 1
        FROM [Non_Trade].[dbo].[pr_basic_info] WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE @pr_prefix + '%';

        -- e.g. PR-26-27-0001
        SET @pr_no = @pr_prefix + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);

        -- FIX 3: Parse com_sno and div_sno from JSON (were missing before)
        SELECT
            @com_sno            = JSON_VALUE(@jsonInput, '$.basicInfo.com_sno'),
            @div_sno            = JSON_VALUE(@jsonInput, '$.basicInfo.div_sno'),
            @brn_sno            = JSON_VALUE(@jsonInput, '$.basicInfo.brn_sno'),
            @dept_sno           = JSON_VALUE(@jsonInput, '$.basicInfo.dept_sno'),  -- FIX 4: no hardcoded fallback
            @reg_date           = JSON_VALUE(@jsonInput, '$.basicInfo.req_date'),
            @required_date      = JSON_VALUE(@jsonInput, '$.basicInfo.required_date'),
            @priority_sno       = JSON_VALUE(@jsonInput, '$.basicInfo.priority_sno'),
            @purpose            = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.purpose'), ''),
            @requisition_type   = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.requisition_type'), ''),
            @source_invoice_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.source_invoice_sno') AS INT),
            @created_by         = 'KTM1148'; -- replace with JSON_VALUE when auth is ready

        SET @category = CASE @requisition_type
            WHEN 'civil_works'     THEN 'CIVIL'
            WHEN 'electrical_works' THEN 'ELECTRICAL'
            WHEN 'transportation'  THEN 'TRANSPORTATION'
            WHEN 'routine'         THEN 'ROUTINE'
            ELSE NULL
        END;

        -- ── Field Validations ──────────────────────────────────────────────
        IF @com_sno IS NULL
            THROW 50010, 'Company (com_sno) is required.', 1;

        IF @div_sno IS NULL
            THROW 50011, 'Division (div_sno) is required.', 1;

        IF @brn_sno IS NULL
            THROW 50001, 'Branch (brn_sno) is required.', 1;

        IF @reg_date IS NULL
            THROW 50002, 'Request date (req_date) is required.', 1;

        IF @required_date IS NULL
            THROW 50003, 'Required date is required.', 1;

        IF @created_by IS NULL
            THROW 50004, 'Created by is required.', 1;

        -- Validate items array has at least one valid entry — a PRODUCT line
        -- (prod_sno + unit_sno) OR a SERVICE line (service_sno).
        IF NOT EXISTS (
            SELECT 1
            FROM OPENJSON(@jsonInput, '$.items')
            WHERE (
                JSON_VALUE(value, '$.prod_sno') IS NOT NULL
                AND JSON_VALUE(value, '$.prod_sno') != ''
                AND JSON_VALUE(value, '$.unit_sno')  IS NOT NULL
                AND JSON_VALUE(value, '$.unit_sno')  != ''
            )
            OR (
                JSON_VALUE(value, '$.service_sno') IS NOT NULL
                AND JSON_VALUE(value, '$.service_sno') != ''
            )
        )
            THROW 50005, 'At least one valid item (product with prod_sno+unit_sno, or service with service_sno) is required.', 1;

        -- Every Fixed Recurring service line must reference an approved,
        -- in-period Service Agreement for THIS PR's org scope + that service
        -- (spec §4) — never a free-typed rate. Checked before any insert so
        -- a bad line aborts the whole PR, same as the other item validation
        -- above, rather than silently dropping the line.
        IF EXISTS (
            SELECT 1
            FROM OPENJSON(@jsonInput, '$.items') AS item
            CROSS APPLY (
                SELECT TRY_CAST(JSON_VALUE(item.value, '$.service_sno')   AS INT) AS parsed_service_sno,
                       TRY_CAST(JSON_VALUE(item.value, '$.agreement_sno') AS INT) AS parsed_agreement_sno
            ) parsed
            JOIN dbo.service_master sm      ON sm.service_sno = parsed.parsed_service_sno
            JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
            WHERE st.service_type_code = 'FIXED_RECURRING'
              AND NOT EXISTS (
                  SELECT 1 FROM dbo.service_agreement sa
                  WHERE sa.agreement_sno = parsed.parsed_agreement_sno
                    AND sa.service_sno   = parsed.parsed_service_sno
                    AND sa.com_sno = @com_sno AND sa.div_sno = @div_sno
                    AND sa.brn_sno = @brn_sno AND sa.dept_sno = @dept_sno
                    AND sa.status  = 'A'
                    AND CAST(GETDATE() AS DATE) BETWEEN sa.period_start_date AND sa.period_end_date
              )
        )
            THROW 50012, 'One or more Fixed Recurring service lines are missing a valid, approved, in-period Service Agreement (agreement_sno) for this company/division/branch/department.', 1;

      SELECT
    @workflow_id       = wt.workflow_id,
    @workflow_types_id = wt.workflow_types_id
FROM workflow_types wt
INNER JOIN approval_workflow_master awm
    ON awm.workflow_id = wt.workflow_id
WHERE wt.brn_sno  = @brn_sno
  AND wt.dept_sno = @dept_sno
  AND wt.com_sno  = @com_sno
  AND wt.div_sno  = @div_sno
  AND awm.entity_type  = 'PurchaseRequisition';
        -- ── Resolve Workflow ───────────────────────────────────────────────
        SELECT @workflow_types_id = workflow_types_id
        FROM workflow_types
       WHERE brn_sno  = @brn_sno
          AND dept_sno = @dept_sno
          AND com_sno=@com_sno
          AND div_sno=@div_sno
          AND workflow_id=@workflow_id;



        IF @workflow_types_id IS NULL
            THROW 50006, 'No workflow configuration found for this branch and department.', 1;

        -- Resolve first approver from workflow stages
        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key]  = '0'
          AND s2.[key] = '0';

        IF @first_approver IS NULL
            THROW 50007, 'No approver found for the first stage of the workflow.', 1;

        -- ── Insert PR Basic Info ───────────────────────────────────────────
        -- v4: category + source_invoice_sno added, both parsed above.
        INSERT INTO [Non_Trade].[dbo].[pr_basic_info]
        (
            [pr_no],               [com_sno],            [div_sno],
            [brn_sno],             [dept_sno],           [reg_date],
            [required_date],       [priority_sno],       [purpose],
            [is_active],           [created_by],         [created_date],
            [workflow_types_id],   [current_approver_id],[status],
            [category],            [source_invoice_sno]
        )
        VALUES
        (
            @pr_no,                @com_sno,             @div_sno,
            @brn_sno,              @dept_sno,            @reg_date,
            @required_date,        @priority_sno,        @purpose,
            'Y',                   @created_by,          GETDATE(),
            @workflow_types_id,    @first_approver,      'P',
            @category,             @source_invoice_sno
        );

        SET @pr_basic_sno = SCOPE_IDENTITY();

        -- ── Insert PR Item Details ─────────────────────────────────────────
        -- Unchanged from v3 — service_sno/agreement_sno logic preserved
        -- byte-for-byte.
        INSERT INTO [Non_Trade].[dbo].[pr_item_details]
        (
            [pr_no],        [pr_basic_sno],  [prod_sno],
            [qty],          [unit],          [est_cost],
            [total_cost],   [remarks],       [specification],
            [pr_prod_file], [item_type],     [service_sno],
            [agreement_sno],
            [is_active],
            [created_by],   [created_date]
        )
        SELECT
            @pr_no,
            @pr_basic_sno,
            NULLIF(JSON_VALUE(value, '$.prod_sno'), ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.qty'), ''),
                   CASE WHEN sa.agreement_sno IS NOT NULL THEN '1' ELSE '0' END),
            ISNULL(sa.rate_uom_sno, NULLIF(JSON_VALUE(value, '$.unit_sno'), '')),
            ISNULL(sa.rate_amount, ISNULL(NULLIF(JSON_VALUE(value, '$.est_cost'), ''), 0)),
            ISNULL(
                sa.rate_amount * TRY_CAST(
                    ISNULL(NULLIF(JSON_VALUE(value, '$.qty'), ''),
                           CASE WHEN sa.agreement_sno IS NOT NULL THEN '1' ELSE '0' END)
                    AS DECIMAL(18,4)),
                ISNULL(NULLIF(JSON_VALUE(value, '$.total_cost'), ''), 0)
            ),
            ISNULL(NULLIF(JSON_VALUE(value, '$.remarks'),        ''), ''),
            ISNULL(NULLIF(JSON_VALUE(value, '$.service_desc'),   ''), ''),
            NULLIF(JSON_VALUE(value, '$.item_attachment'),       ''),  -- FIX 5: NULL not ''
            ISNULL(NULLIF(JSON_VALUE(value, '$.item_type'),      ''), 'product'),
            NULLIF(JSON_VALUE(value, '$.service_sno'), ''),
            sa.agreement_sno,
            'Y',
            @created_by,
            GETDATE()
        FROM OPENJSON(@jsonInput, '$.items')
        OUTER APPLY (
            SELECT TRY_CAST(JSON_VALUE(value, '$.service_sno')   AS INT) AS parsed_service_sno,
                   TRY_CAST(JSON_VALUE(value, '$.agreement_sno') AS INT) AS parsed_agreement_sno
        ) parsed
        LEFT JOIN dbo.service_agreement sa
            ON sa.agreement_sno = parsed.parsed_agreement_sno
           AND sa.service_sno   = parsed.parsed_service_sno
           AND sa.com_sno = @com_sno AND sa.div_sno = @div_sno
           AND sa.brn_sno = @brn_sno AND sa.dept_sno = @dept_sno
           AND sa.status  = 'A'
           AND CAST(GETDATE() AS DATE) BETWEEN sa.period_start_date AND sa.period_end_date
        WHERE (
            JSON_VALUE(value, '$.prod_sno') IS NOT NULL
            AND JSON_VALUE(value, '$.prod_sno') != ''
            AND JSON_VALUE(value, '$.unit_sno')  IS NOT NULL
            AND JSON_VALUE(value, '$.unit_sno')  != ''
        )
        OR (
            JSON_VALUE(value, '$.service_sno') IS NOT NULL
            AND JSON_VALUE(value, '$.service_sno') != ''
        );

        SET @items_inserted = @@ROWCOUNT;

        IF @items_inserted = 0
            THROW 50008, 'No items were inserted. Check that items array is valid and non-empty.', 1;

        COMMIT TRANSACTION;

        SELECT
            'PR Data Saved Successfully. PR No: ' + @pr_no AS Message,
            'Success'                                       AS Status,
            @items_inserted                                 AS ItemsInserted;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT    = ERROR_SEVERITY();
        DECLARE @ErrorState    INT            = ERROR_STATE();

        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END;
GO
-- undo [F2. procedures] dbo.usp_GetPendingForEcno
-- restore previous definition
CREATE OR ALTER PROCEDURE [dbo].[usp_GetPendingForEcno]
  @ecno NVARCHAR(50)
AS
BEGIN
  SET NOCOUNT ON;

  ;WITH FlowSteps AS (
    SELECT af.nt_app_flow_sno, s.step_no, s.step_ecno
    FROM Non_Trade.dbo.nt_approval_flow af
    CROSS APPLY ( VALUES
       (1, af.nt_app_flow_step1_ecno),
       (2, af.nt_app_flow_step2_ecno),
       (3, af.nt_app_flow_step3_ecno),
       (4, af.nt_app_flow_step4_ecno),
       (5, af.nt_app_flow_step5_ecno),
       (6, af.nt_app_flow_step6_ecno),
       (7, af.nt_app_flow_step7_ecno),
       (8, af.nt_app_flow_step8_ecno),
       (9, af.nt_app_flow_step9_ecno),
       (10, af.nt_app_flow_step10_ecno),
       (11, af.nt_app_flow_step11_ecno),
       (12, af.nt_app_flow_step12_ecno),
       (13, af.nt_app_flow_step13_ecno)
    ) s(step_no, step_ecno)
  ),
ApprovedHistory AS (
    SELECT nh.nt_app_flow_sno,
           TRY_CAST(nh.nt_app_his_auth_selection AS INT) AS step_no
    FROM Non_Trade.dbo.nt_approval_history nh
    WHERE nh.nt_app_his_status = 'A'
      AND nh.is_active = 'Y'
),
RejectedHistory AS (
    SELECT nh.nt_app_flow_sno,
           TRY_CAST(nh.nt_app_his_auth_selection AS INT) AS step_no
    FROM Non_Trade.dbo.nt_approval_history nh
    WHERE nh.nt_app_his_status = 'R'
      AND nh.is_active = 'Y'
),
CurrentStep AS (
    SELECT
      bde.bud_dta_sno,
      bde.bud_sno,
      bde.nt_app_flow_sno,
      (SELECT MIN(fs.step_no)
       FROM FlowSteps fs
       WHERE fs.nt_app_flow_sno = bde.nt_app_flow_sno
         AND fs.step_ecno IS NOT NULL
         AND NOT EXISTS (
             SELECT 1 FROM ApprovedHistory ah
             WHERE ah.nt_app_flow_sno = fs.nt_app_flow_sno
               AND ah.step_no = fs.step_no
         )
         AND NOT EXISTS (
           SELECT 1 FROM FlowSteps prev
           WHERE prev.nt_app_flow_sno = fs.nt_app_flow_sno
             AND prev.step_no < fs.step_no
             AND prev.step_ecno IS NOT NULL
             AND NOT EXISTS (
                 SELECT 1 FROM ApprovedHistory ah2
                 WHERE ah2.nt_app_flow_sno = prev.nt_app_flow_sno
                   AND ah2.step_no = prev.step_no
             )
         )
      ) AS current_step_no
    FROM Non_Trade.dbo.budget_data_entries bde
    WHERE bde.is_active = 'Y'
)
 
SELECT
    cs.bud_dta_sno,
    cs.bud_sno,
    cs.nt_app_flow_sno,
    cs.current_step_no,
    fs.step_ecno AS current_step_ecno,
    bm.bud_code,
    bm.dept_sno,
    bm.com_sno,
    bde.bud_dta_desc,
    bde.bud_dta_ctg,
    bde.bud_dta_req_qty,
    bde.uom_sno,
    bde.bud_dta_unt_cst,
    bde.created_date
FROM CurrentStep cs
INNER JOIN FlowSteps fs
    ON fs.nt_app_flow_sno = cs.nt_app_flow_sno
   AND fs.step_no = cs.current_step_no
   AND fs.step_ecno = @ecno   -- ✅ filter here only for actual current step approver
INNER JOIN Non_Trade.dbo.budget_data_entries bde
    ON bde.bud_dta_sno = cs.bud_dta_sno
LEFT JOIN Non_Trade.dbo.budget_master bm
    ON bm.bud_sno = bde.bud_sno
WHERE cs.current_step_no IS NOT NULL
ORDER BY bde.created_date DESC;

END
GO
-- undo [F2. procedures] dbo.sp_product_sub_catagory
-- restore previous definition
CREATE OR ALTER PROCEDURE [dbo].[sp_product_sub_catagory]
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SELECT sc.[subcat_sno]
              ,sc.[subcat_name]
              ,sc.[subcat_description]
              ,sc.[subcat_notes]
              ,sc.[subcat_stock_type]
              ,sc.[cat_sno]
              ,cm.[cat_name]
        FROM [Non_Trade].[dbo].[subcategory_master] sc
        INNER JOIN [Non_Trade].[dbo].[category_master] cm ON cm.cat_sno = sc.cat_sno
        WHERE sc.subcat_active = 'Y'
        ORDER BY sc.subcat_sno;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
-- undo [F2. procedures] dbo.sp_product_catagory
-- restore previous definition
  CREATE OR ALTER PROCEDURE [dbo].[sp_product_catagory] 
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        SELECT [cat_sno]
      ,[cat_name]
      ,[cat_description]
      ,[cat_notes]
       FROM [Non_Trade].[dbo].[category_master] 
WHERE cat_active='Y' 
ORDER BY cat_sno;
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        -- Re-throw the original error
        THROW;
    END CATCH
END
GO
-- undo [F2. procedures] dbo.sp_nt_UpsertInventoryItemByProduct
-- restore previous definition
-- =============================================================================
-- 25_inventory_location_default_and_display_fix.sql
--
-- Two independent fixes requested/found while investigating "warehouse location
-- not coming" on the Inventory page (2026-09-05):
--
-- 1) sp_nt_UpsertInventoryItemByProduct: when a GRN line doesn't specify a
--    warehouse location, a brand-new inventory item was left with location =
--    NULL. Per explicit instruction, new items now default to 'B3' when no
--    location was given. Scoped to the INSERT branch only — an EXISTING
--    item's location is still only touched when the caller actually supplies
--    one (unchanged), so a later receipt with no location picked can never
--    silently clobber a correctly-set location back to 'B3'.
--    Note: 'B3' (School Stock Room) is scoped to branches 13/14/15 in
--    warehouse_location_master — it is not the "right" bin for other
--    branches (e.g. branch 1/Coimbatore-HO, which maps to 'B1'). This was
--    flagged before applying; kept as a straight literal default per
--    explicit instruction, not because it's branch-correct.
--
-- 2) sp_nt_GetInventoryItems: the Inventory list only ever returned a single
--    `location` column (the location CODE, e.g. 'B3'), but
--    InventoryTable.tsx renders item.location_code / item.location_name —
--    fields nothing ever populated. So the "Bin" / "Stock location_name"
--    columns showed blank ('—') for every item regardless of whether a
--    location was actually set. Now returns location AS location_code plus
--    a join to warehouse_location_master for the descriptive location_name.
-- =============================================================================

CREATE OR ALTER PROCEDURE [dbo].[sp_nt_UpsertInventoryItemByProduct]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @prod_sno     INT          = JSON_VALUE(@jsonInput, '$.prod_sno');
    DECLARE @prod_name    VARCHAR(255) = JSON_VALUE(@jsonInput, '$.prod_name');
    DECLARE @uom_name     VARCHAR(20)  = JSON_VALUE(@jsonInput, '$.uom_name');
    DECLARE @com_sno      INT          = JSON_VALUE(@jsonInput, '$.com_sno');
    DECLARE @div_sno      INT          = JSON_VALUE(@jsonInput, '$.div_sno');
    DECLARE @brn_sno      INT          = JSON_VALUE(@jsonInput, '$.brn_sno');
    DECLARE @location_sno INT          = JSON_VALUE(@jsonInput, '$.location_sno');

    IF @prod_sno IS NULL
    BEGIN
        RAISERROR('prod_sno is required.', 16, 1);
        RETURN;
    END

    DECLARE @location VARCHAR(100);

    IF @location_sno IS NOT NULL
        SELECT @location = location_code
        FROM dbo.warehouse_location_master
        WHERE location_sno = @location_sno;

    DECLARE @item_sno INT;

    -- NULL-safe match: a receipt with no branch hits the no-branch row only,
    -- never some other branch's stock.
    SELECT @item_sno = item_sno
    FROM dbo.nt_inventory_items
    WHERE prod_sno = @prod_sno
      AND ((@com_sno IS NULL AND com_sno IS NULL) OR com_sno = @com_sno)
      AND ((@div_sno IS NULL AND div_sno IS NULL) OR div_sno = @div_sno)
      AND ((@brn_sno IS NULL AND brn_sno IS NULL) OR brn_sno = @brn_sno);

    IF @item_sno IS NULL
    BEGIN
        DECLARE @item_code VARCHAR(50) =
            'AUTO-' + CAST(@prod_sno AS VARCHAR(20))
            + CASE WHEN @brn_sno IS NOT NULL
                   THEN '-B' + CAST(@brn_sno AS VARCHAR(20))
                   ELSE ''
              END;

        INSERT INTO dbo.nt_inventory_items (
            item_code, item_name, category, uom, current_stock, min_stock,
            max_stock, reorder_qty, warehouse, location, cost_price, selling_price,
            status, prod_sno, com_sno, div_sno, brn_sno, created_by, created_at
        )
        VALUES (
            @item_code,
            ISNULL(@prod_name, 'Product ' + CAST(@prod_sno AS VARCHAR(20))),
            'Raw Material', ISNULL(@uom_name, 'Nos'), 0, 0,
            0, 0, 'Main Warehouse', ISNULL(@location, 'B1'), 0, 0,
            'Active', @prod_sno, @com_sno, @div_sno, @brn_sno, 'system', GETDATE()
        );

        SET @item_sno = SCOPE_IDENTITY();
    END
    ELSE IF @location IS NOT NULL
    BEGIN
        UPDATE dbo.nt_inventory_items
        SET location   = @location,
            updated_at = GETDATE()
        WHERE item_sno = @item_sno;
    END

    SELECT item_sno, item_code, item_name, uom, current_stock, warehouse, location,
           com_sno, div_sno, brn_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_UpdateStockRequestStatus
SET QUOTED_IDENTIFIER OFF
GO
-- restore previous definition

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateStockRequestStatus
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @request_sno INT          = JSON_VALUE(@jsonInput, '$.request_sno');
    DECLARE @status      VARCHAR(30)  = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @reason      VARCHAR(500) = JSON_VALUE(@jsonInput, '$.reason');
    DECLARE @updated_by  VARCHAR(50)  = JSON_VALUE(@jsonInput, '$.updated_by');

    IF @request_sno IS NULL OR @status NOT IN ('Rejected', 'Cancelled')
    BEGIN
        RAISERROR('request_sno and a status of Rejected or Cancelled are required.', 16, 1);
        RETURN;
    END

    DECLARE @cur_status VARCHAR(30), @requested_by VARCHAR(50);
    SELECT @cur_status = status, @requested_by = requested_by
    FROM dbo.nt_stock_requests WHERE request_sno = @request_sno;

    IF @cur_status IS NULL
    BEGIN
        RAISERROR('Stock request not found.', 16, 1);
        RETURN;
    END

    IF @cur_status <> 'Pending'
    BEGIN
        RAISERROR('Only Pending requests can be rejected or cancelled (current status: %s).', 16, 1, @cur_status);
        RETURN;
    END

    IF @status = 'Cancelled' AND (@updated_by IS NULL OR @updated_by <> @requested_by)
    BEGIN
        RAISERROR('Only the requester can cancel a stock request.', 16, 1);
        RETURN;
    END

    UPDATE dbo.nt_stock_requests
    SET status        = @status,
        reject_reason = @reason,
        issued_by     = CASE WHEN @status = 'Rejected' THEN @updated_by ELSE issued_by END,
        updated_at    = GETDATE()
    WHERE request_sno = @request_sno;

    UPDATE dbo.nt_stock_request_items
    SET line_status = @status
    WHERE request_sno = @request_sno AND line_status = 'Pending';

    SELECT request_sno, request_no, requested_by, status, reject_reason,
           CONVERT(VARCHAR(30), updated_at, 120) AS updated_at
    FROM dbo.nt_stock_requests
    WHERE request_sno = @request_sno;
END;

GO
SET QUOTED_IDENTIFIER ON
GO
-- undo [F2. procedures] dbo.sp_nt_UpdateServiceAgreement
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateServiceAgreement
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
-- undo [F2. procedures] dbo.sp_nt_UpdateProductStockLevel  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_UpdateProductStockLevel];
GO
-- undo [F2. procedures] dbo.sp_nt_UpdateInventoryItem
SET QUOTED_IDENTIFIER OFF
GO
-- restore previous definition

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateInventoryItem
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_sno      INT           = JSON_VALUE(@jsonInput, '$.item_sno');
    DECLARE @item_name     VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.item_name');
    DECLARE @category      VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.category');
    DECLARE @sub_category  VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.sub_category');
    DECLARE @uom           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.uom');
    DECLARE @min_stock     DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.min_stock');
    DECLARE @max_stock     DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.max_stock');
    DECLARE @reorder_qty   DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.reorder_qty');
    DECLARE @warehouse     VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.warehouse');
    DECLARE @location      VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.location');
    DECLARE @cost_price    DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.cost_price');
    DECLARE @selling_price DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.selling_price');
    DECLARE @status        VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @hsn_code      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.hsn_code');
    DECLARE @description   VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.description');
    DECLARE @updated_by    VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.updated_by');

    IF @item_sno IS NULL
    BEGIN
        RAISERROR('item_sno is required.', 16, 1);
        RETURN;
    END

    UPDATE dbo.nt_inventory_items
    SET item_name     = ISNULL(@item_name, item_name),
        category      = ISNULL(@category, category),
        sub_category  = @sub_category,
        uom           = ISNULL(@uom, uom),
        min_stock     = ISNULL(@min_stock, min_stock),
        max_stock     = ISNULL(@max_stock, max_stock),
        reorder_qty   = ISNULL(@reorder_qty, reorder_qty),
        warehouse     = ISNULL(@warehouse, warehouse),
        location      = @location,
        cost_price    = ISNULL(@cost_price, cost_price),
        selling_price = ISNULL(@selling_price, selling_price),
        status        = ISNULL(@status, status),
        hsn_code      = @hsn_code,
        description   = @description,
        updated_by    = @updated_by,
        updated_at    = GETDATE()
    WHERE item_sno = @item_sno;

    SELECT item_sno, item_code, item_name, category, uom, current_stock, warehouse, status
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;

GO
SET QUOTED_IDENTIFIER ON
GO
-- undo [F2. procedures] dbo.sp_nt_SubmitServicePoEntry  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_SubmitServicePoEntry];
GO
-- undo [F2. procedures] dbo.sp_nt_SnapshotServiceAgreementVersion  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_SnapshotServiceAgreementVersion];
GO
-- undo [F2. procedures] dbo.sp_nt_sign_up
-- restore previous definition

CREATE OR ALTER PROCEDURE [dbo].[sp_nt_sign_up]  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
      
    BEGIN TRY  
        BEGIN TRANSACTION;  
       
        -- Validate JSON input  
        IF @jsonInput IS NULL OR @jsonInput = '' OR NOT ISJSON(@jsonInput) = 1  
        BEGIN  
            THROW 50001, 'Invalid or empty JSON input provided', 1;  
        END  
          
        -- Insert into nt_sign_up table with lookup from vw_verified_employees
        INSERT INTO nt_sign_up (  
            ecno, com_sno, div_sno, brn_sno, dept_sno, sign_up_cug,   
            sign_up_pass, sign_up_otp, nt_menu_sno, fingerprint_mantra_mfs, branch, dept ,is_active,workflow_id
        )  
        SELECT  
            CAST(j.ecno AS VARCHAR(10)),   
            CAST(j.com_sno AS INT),   
            CAST(j.div_sno AS INT),   
            CAST(j.brn_sno AS INT),   
            CAST(j.dept_sno AS INT),   
            CASE   
                WHEN j.sign_up_cug = '' OR j.sign_up_cug IS NULL THEN NULL   
                ELSE CAST(j.sign_up_cug AS BIGINT)   
            END,  
            CASE   
                WHEN LEN(j.sign_up_pass) > 15 THEN LEFT(CAST(j.sign_up_pass AS NVARCHAR(15)), 15)  
                ELSE CAST(j.sign_up_pass AS NVARCHAR(15))  
            END,  
            CASE   
                WHEN j.sign_up_otp = '' OR j.sign_up_otp IS NULL THEN NULL   
                ELSE CAST(j.sign_up_otp AS INT)   
            END,  
            CAST(j.nt_menu_sno AS NVARCHAR(MAX)),  
            CASE   
                WHEN LEN(j.fingerprint_mantra_mfs) > 100 THEN LEFT(CAST(j.fingerprint_mantra_mfs AS NVARCHAR(100)), 100)  
                ELSE CAST(j.fingerprint_mantra_mfs AS NVARCHAR(100))  
            END,
            v.branch,  -- Lookup from view
            v.dept,-- Lookup from view
            'Y',
            8
        FROM OPENJSON(@jsonInput)  
        WITH (  
            ecno NVARCHAR(50) '$.ecno',  
            com_sno NVARCHAR(50) '$.com_sno',  
            div_sno NVARCHAR(50) '$.div_sno',  
            brn_sno NVARCHAR(50) '$.brn_sno',  
            dept_sno NVARCHAR(50) '$.dept_sno',  
            sign_up_cug NVARCHAR(50) '$.sign_up_cug',  
            sign_up_pass NVARCHAR(MAX) '$.sign_up_pass',  
            sign_up_otp NVARCHAR(50) '$.sign_up_otp',  
            nt_menu_sno NVARCHAR(MAX) '$.nt_menu_sno',  
            fingerprint_mantra_mfs NVARCHAR(MAX) '$.fingerprint_mantra_mfs'  
        ) AS j
        LEFT JOIN [Non_Trade].[dbo].[vw_verified_employees] v ON v.ecno = j.ecno;
          
        -- Return success message with row count  
        SELECT 'SUCCESS' as Status, @@ROWCOUNT as RowsAffected;  
          
        COMMIT TRANSACTION;  
          
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
          
        -- Return detailed error information  
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();  
        DECLARE @ErrorNumber INT = ERROR_NUMBER();  
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();  
        DECLARE @ErrorState INT = ERROR_STATE();  
          
        SELECT   
            'ERROR' as Status,  
            @ErrorNumber as ErrorNumber,  
            @ErrorMessage as ErrorMessage,  
            @ErrorSeverity as ErrorSeverity,  
            @ErrorState as ErrorState;  
          
        -- Re-throw the error for upstream handling  
        THROW;  
    END CATCH  
END

GO
-- undo [F2. procedures] dbo.sp_nt_SaveServiceAgreementSuppliers  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_SaveServiceAgreementSuppliers];
GO
-- undo [F2. procedures] dbo.sp_nt_SaveServiceAgreementStatutory  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_SaveServiceAgreementStatutory];
GO
-- undo [F2. procedures] dbo.sp_nt_ResolveServicePoWorkflow  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_ResolveServicePoWorkflow];
GO
-- undo [F2. procedures] dbo.sp_nt_ResolveBankVoucherWorkflow  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_ResolveBankVoucherWorkflow];
GO
-- undo [F2. procedures] dbo.sp_nt_ProcessDueRecurringServiceAgreements
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_ProcessDueRecurringServiceAgreements
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
-- undo [F2. procedures] dbo.sp_nt_PreviewLoanInterest  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_PreviewLoanInterest];
GO
-- undo [F2. procedures] dbo.sp_nt_MatchInvoiceBucket
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_MatchInvoiceBucket
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @invoice_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_sno') AS INT);
        IF @invoice_sno IS NULL
            THROW 54010, 'invoice_sno is required.', 1;

        -- Per-bucket ratio: MATERIAL from GRN receipts, SERVICE from
        -- Service Entry (qty-based when the PO line carries a qty, else
        -- amount-based against the budgeted po_amount). Capped at 1.0.
        UPDATE iad
        SET matched_qty_ratio = ratios.ratio,
            hold_amount       = iad.allocated_amount * (1 - ratios.ratio),
            release_amount    = iad.allocated_amount * ratios.ratio,
            match_status      = CASE WHEN ratios.ratio >= 0.999999 THEN 'Matched' ELSE 'Partial' END
        FROM dbo.invoice_allocation_details iad
        JOIN dbo.po_item_details pid ON pid.po_item_sno = iad.po_item_sno
        CROSS APPLY (
            SELECT
                received_qty = (
                    SELECT ISNULL(SUM(gi.received_qty - ISNULL(gi.rejected_qty, 0)), 0)
                    FROM dbo.grn_item_details gi
                    WHERE gi.po_item_sno = pid.po_item_sno AND gi.is_active = 'Y'
                ),
                billed_qty_sum = (
                    SELECT ISNULL(SUM(sei.billed_qty), 0)
                    FROM dbo.service_entry_item_details sei
                    JOIN dbo.service_entry_info se ON se.service_entry_sno = sei.service_entry_sno
                    WHERE sei.po_item_sno = pid.po_item_sno AND sei.is_active = 'Y' AND se.status = 'Approved'
                ),
                confirmed_amt_sum = (
                    SELECT ISNULL(SUM(sei.confirmed_amount), 0)
                    FROM dbo.service_entry_item_details sei
                    JOIN dbo.service_entry_info se ON se.service_entry_sno = sei.service_entry_sno
                    WHERE sei.po_item_sno = pid.po_item_sno AND sei.is_active = 'Y' AND se.status = 'Approved'
                )
        ) raw
        CROSS APPLY (
            SELECT rawRatio = CASE
                WHEN iad.bucket_type = 'MATERIAL' THEN
                    CASE WHEN ISNULL(pid.qty, 0) = 0 THEN 0
                         ELSE CAST(raw.received_qty AS DECIMAL(18,6)) / pid.qty
                    END
                ELSE -- SERVICE
                    CASE
                        WHEN ISNULL(pid.qty, 0) > 0 THEN CAST(raw.billed_qty_sum AS DECIMAL(18,6)) / pid.qty
                        WHEN ISNULL(pid.net_cost, 0) > 0 THEN CAST(raw.confirmed_amt_sum AS DECIMAL(18,6)) / pid.net_cost
                        ELSE 0
                    END
                END
        ) computed
        CROSS APPLY (SELECT ratio = CASE WHEN computed.rawRatio > 1 THEN 1.0 ELSE computed.rawRatio END) ratios
        WHERE iad.invoice_sno = @invoice_sno AND iad.is_active = 'Y';

        DECLARE @totalRelease DECIMAL(18,2), @bucketCount INT, @matchedCount INT;
        SELECT
            @totalRelease = SUM(release_amount),
            @bucketCount  = COUNT(*),
            @matchedCount = SUM(CASE WHEN match_status = 'Matched' THEN 1 ELSE 0 END)
        FROM dbo.invoice_allocation_details WHERE invoice_sno = @invoice_sno AND is_active = 'Y';

        UPDATE dbo.invoice_info
        SET net_payable = ISNULL(@totalRelease, 0),
            match_status = CASE WHEN @matchedCount = @bucketCount THEN 'Matched' ELSE 'PartialRelease' END,
            modified_date = GETDATE()
        WHERE invoice_sno = @invoice_sno;

        COMMIT TRANSACTION;

        SELECT invoice_alloc_sno, po_item_sno, bucket_type, allocated_amount, matched_qty_ratio, hold_amount, release_amount, match_status
        FROM dbo.invoice_allocation_details WHERE invoice_sno = @invoice_sno AND is_active = 'Y';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
-- undo [F2. procedures] dbo.sp_nt_MarkBankPaymentVoucherPaid  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_MarkBankPaymentVoucherPaid];
GO
-- undo [F2. procedures] dbo.sp_nt_MarkAgreementNotificationSent
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_MarkAgreementNotificationSent
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
-- undo [F2. procedures] dbo.sp_nt_LogPOSentToSupplier
-- restore previous definition
-- ============================================================
-- PR Requester Tracking — read-only aggregation layer
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : new backend-stpl/src/PRTracking module (Node)
--
-- IMPORTANT — nothing existing is touched. UAT is currently exercising
-- usp_InsertPurchaseRequest / sp_approve_pr_datas / the quotation and PO
-- approval procedures live, so this file creates ONLY brand-new objects
-- (no CREATE OR ALTER, no DROP+CREATE on anything that already exists) and
-- reads from existing tables/views without writing to any of them except
-- one new additive INSERT-only procedure (#1 below). Nothing here can change
-- the behaviour of a procedure UAT is currently mid-flow on.
--
-- Discovery note: pr_history_data (pr_basic_sno, pr_edit_data, is_active,
-- workflow_types_id, approver_ecno, status, status_by, status_date, commends,
-- pr_no) already exists live and is already populated by sp_approve_pr_datas
-- on every approve/reject — it was simply never checked into this repo's sql/
-- folder before now (same situation usp_InsertPurchaseRequest was in until
-- 06_usp_InsertPurchaseRequest_v2.sql). No new PR audit table is needed —
-- this file only reads it, via the existing vw_PR_Basic_Info view which
-- already nests it as JSON.
--
-- Contents:
--   1. sp_nt_LogPOSentToSupplier   — new, additive INSERT into the existing
--      po_history_data table. Call this from PurchaseTeamService.sendPOEmail
--      right after a successful send; today nothing logs that transition.
--   2. sp_nt_GetPRTrackingTimeline — new, one PR's full journey (PR header +
--      history, Quotation, PO + history, Dispatch, Gate Entry, GRN + history,
--      Inventory movements) as multiple result sets, all joined via
--      pr_basic_sno -> po_request_info.pr_basic_sno -> po_basic_sno, the same
--      FK chain every existing downstream table already uses.
--   3. sp_nt_GetMyPRTracking       — new, the caller's own PRs with a
--      computed current_stage, for a "My Requests" list.
--   4. sp_nt_GetOrgPRTracking      — new, pending/active PRs within an org
--      scope (com/div/brn/dept), for the permission-gated "Team / Org View".
--   5. sp_nt_GetPrNoByPoBasicSno   — new, tiny lookup so grn-service/PurchaseTeam
--      touch points (which only carry po_basic_sno) can resolve which
--      pr:track:{pr_no} room to broadcast into.
--   6. sp_nt_HasScreenPermission   — new, server-side check of the existing
--      screens/permissions grant, gating the "Team / Org View" endpoint.
--   7. Screens row for the new PRTrackingPage, same pattern as every prior
--      screen registration in this series (e.g.
--      24_service_bill_request_screens_and_backfill.sql) — reuses the
--      existing sp_nt_GrantScreenToUser, no new grant mechanism.
--
-- Deliberately NOT done: no org columns added to nt_gate_entry /
-- nt_dispatch_slip / nt_dispatch_slip_delivery / nt_transport_master — every
-- query below reaches them through po_basic_sno, which is already resolved
-- from a com/div/brn/dept-scoped pr_basic_info/po_request_info row.
-- ============================================================

-- ── 1. sp_nt_LogPOSentToSupplier ────────────────────────────────────────────
-- Additive audit row only. Never called in a way that can fail the actual
-- PO-send response — see PurchaseTeamService.sendPOEmail wiring.
CREATE OR ALTER PROCEDURE dbo.sp_nt_LogPOSentToSupplier
    @po_basic_sno INT,
    @status_by    VARCHAR(20),
    @comment      VARCHAR(250) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
    VALUES (@po_basic_sno, 'SENT_TO_SUPPLIER', @status_by, @comment, 'Y');

    SELECT 'LOGGED' AS result, @po_basic_sno AS po_basic_sno, SCOPE_IDENTITY() AS po_history_sno;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_IssueStockRequest
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_IssueStockRequest
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @request_sno     INT         = JSON_VALUE(@jsonInput, '$.request_sno');
    DECLARE @issued_by       VARCHAR(50) = JSON_VALUE(@jsonInput, '$.issued_by');
    DECLARE @received_by_ecno VARCHAR(50) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.received_by_ecno'))), '');

    IF @request_sno IS NULL OR @issued_by IS NULL
    BEGIN
        RAISERROR('request_sno and issued_by are required.', 16, 1);
        RETURN;
    END

    IF @received_by_ecno IS NULL
    BEGIN
        RAISERROR('received_by_ecno (the receiving employee''s ECNO) is required.', 16, 1);
        RETURN;
    END

    DECLARE @received_by_name VARCHAR(255);
    SELECT @received_by_name = ename FROM dbo.vw_verified_employees WHERE ecno = @received_by_ecno;

    IF @received_by_name IS NULL
    BEGIN
        RAISERROR('Receiving employee not found or not verified.', 16, 1);
        RETURN;
    END

    DECLARE @request_no VARCHAR(30), @req_status VARCHAR(30);
    DECLARE @requested_by VARCHAR(50);
    SELECT @request_no = request_no, @req_status = status, @requested_by = requested_by
    FROM dbo.nt_stock_requests
    WHERE request_sno = @request_sno;

    IF @request_no IS NULL
    BEGIN
        RAISERROR('Stock request not found.', 16, 1);
        RETURN;
    END

    IF @req_status NOT IN ('Pending', 'Partially Issued')
    BEGIN
        RAISERROR('Only Pending or Partially Issued requests can be issued (current status: %s).', 16, 1, @req_status);
        RETURN;
    END

    DECLARE @issue TABLE (
        sr_item_sno INT,
        issue_qty   DECIMAL(18,2)
    );

    INSERT INTO @issue (sr_item_sno, issue_qty)
    SELECT sr_item_sno, issue_qty
    FROM OPENJSON(@jsonInput, '$.items')
    WITH (
        sr_item_sno INT           '$.sr_item_sno',
        issue_qty   DECIMAL(18,2) '$.issue_qty'
    )
    WHERE issue_qty IS NOT NULL AND issue_qty > 0;

    IF NOT EXISTS (SELECT 1 FROM @issue)
    BEGIN
        RAISERROR('No issue quantities supplied.', 16, 1);
        RETURN;
    END

    -- Lines must belong to this request
    IF EXISTS (
        SELECT 1 FROM @issue x
        LEFT JOIN dbo.nt_stock_request_items l
               ON l.sr_item_sno = x.sr_item_sno AND l.request_sno = @request_sno
        WHERE l.sr_item_sno IS NULL
    )
    BEGIN
        RAISERROR('One or more lines do not belong to this request.', 16, 1);
        RETURN;
    END

    BEGIN TRANSACTION;
    BEGIN TRY
        -- Over-issue guard against the line's remaining quantity
        IF EXISTS (
            SELECT 1 FROM @issue x
            JOIN dbo.nt_stock_request_items l WITH (UPDLOCK, HOLDLOCK)
              ON l.sr_item_sno = x.sr_item_sno
            WHERE x.issue_qty > (l.requested_qty - l.issued_qty)
        )
        BEGIN
            RAISERROR('Issue quantity exceeds the pending quantity on a line.', 16, 1);
            RETURN;
        END

        -- Stock availability guard
        IF EXISTS (
            SELECT 1 FROM @issue x
            JOIN dbo.nt_stock_request_items l ON l.sr_item_sno = x.sr_item_sno
            JOIN dbo.nt_inventory_items i WITH (UPDLOCK, HOLDLOCK)
              ON i.item_sno = l.item_sno
            WHERE x.issue_qty > i.current_stock
        )
        BEGIN
            RAISERROR('Insufficient stock for one or more items.', 16, 1);
            RETURN;
        END

        DECLARE @movements TABLE (movement_sno INT);

        -- Reduce stock item by item so each movement records its own
        -- balance_after (set-based UPDATE could not capture that).
        DECLARE @sr_item_sno INT, @issue_qty DECIMAL(18,2);
        DECLARE issue_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT sr_item_sno, issue_qty FROM @issue;

        OPEN issue_cur;
        FETCH NEXT FROM issue_cur INTO @sr_item_sno, @issue_qty;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @item_sno INT, @new_stock DECIMAL(18,2);

            SELECT @item_sno = item_sno
            FROM dbo.nt_stock_request_items
            WHERE sr_item_sno = @sr_item_sno;

            UPDATE dbo.nt_inventory_items
            SET current_stock = current_stock - @issue_qty,
                updated_by    = @issued_by,
                updated_at    = GETDATE(),
                @new_stock    = current_stock - @issue_qty
            WHERE item_sno = @item_sno;

            INSERT INTO dbo.nt_stock_movements (
                item_sno, item_code, item_name, movement_type, quantity,
                balance_after, uom, reference_no, warehouse, reason,
                com_sno, div_sno, brn_sno, dept_sno, created_by, created_at,
                received_by_ecno, received_by_name
            )
            SELECT
                i.item_sno, i.item_code, i.item_name, 'OUT', @issue_qty,
                @new_stock, i.uom, @request_no, i.warehouse,
                'Stock Request Issue (' + @requested_by + ')',
                i.com_sno, i.div_sno, i.brn_sno, i.dept_sno, @issued_by, GETDATE(),
                @received_by_ecno, @received_by_name
            FROM dbo.nt_inventory_items i
            WHERE i.item_sno = @item_sno;

            INSERT INTO @movements (movement_sno) VALUES (SCOPE_IDENTITY());

            UPDATE dbo.nt_stock_request_items
            SET issued_qty  = issued_qty + @issue_qty,
                line_status = CASE WHEN issued_qty + @issue_qty >= requested_qty
                                   THEN 'Issued' ELSE 'Partially Issued' END
            WHERE sr_item_sno = @sr_item_sno;

            FETCH NEXT FROM issue_cur INTO @sr_item_sno, @issue_qty;
        END
        CLOSE issue_cur;
        DEALLOCATE issue_cur;

        DECLARE @new_status VARCHAR(30) =
            CASE WHEN EXISTS (
                    SELECT 1 FROM dbo.nt_stock_request_items
                    WHERE request_sno = @request_sno AND issued_qty < requested_qty
                 )
                 THEN 'Partially Issued' ELSE 'Issued' END;

        UPDATE dbo.nt_stock_requests
        SET status           = @new_status,
            issued_by        = @issued_by,
            issued_at        = GETDATE(),
            received_by_ecno = @received_by_ecno,
            received_by_name = @received_by_name,
            updated_at       = GETDATE()
        WHERE request_sno = @request_sno;

        COMMIT TRANSACTION;

        -- Recordset 1: updated header
        SELECT
            r.request_sno, r.request_no, r.requested_by, r.requested_name, r.department,
            r.purpose, r.status, r.issued_by, r.received_by_ecno, r.received_by_name,
            (SELECT ISNULL(SUM(issued_qty), 0) FROM dbo.nt_stock_request_items WHERE request_sno = r.request_sno) AS total_issued_qty,
            CONVERT(VARCHAR(30), r.issued_at, 120) AS issued_at
        FROM dbo.nt_stock_requests r
        WHERE r.request_sno = @request_sno;

        -- Recordset 2: the movements this issue created
        SELECT
            m.movement_sno, m.item_sno, m.item_code, m.item_name, m.movement_type,
            m.quantity, m.balance_after, m.uom, m.reference_no, m.warehouse, m.reason,
            m.received_by_ecno, m.received_by_name,
            m.created_by, CONVERT(VARCHAR(30), m.created_at, 120) AS created_at
        FROM dbo.nt_stock_movements m
        JOIN @movements x ON x.movement_sno = m.movement_sno
        ORDER BY m.movement_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
-- undo [F2. procedures] dbo.sp_nt_IssueRecurringServicePOCycle
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_IssueRecurringServicePOCycle
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
-- undo [F2. procedures] dbo.sp_nt_GrantScreenToUser
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_GrantScreenToUser
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ecno            VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.ecno');
    DECLARE @screen_id       INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.screen_id') AS INT);
    DECLARE @permission_ids  NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.permission_ids');

    IF @ecno IS NULL OR @screen_id IS NULL OR @permission_ids IS NULL
        THROW 60001, 'ecno, screen_id and permission_ids are required.', 1;

    DECLARE @user_perm_json_sno INT, @screens_json NVARCHAR(MAX);
    SELECT TOP 1 @user_perm_json_sno = user_perm_json_sno, @screens_json = RTRIM(screens_json)
    FROM dbo.nt_user_permissions_json
    WHERE ecno = @ecno AND is_active = 'Y'
    ORDER BY user_perm_json_sno DESC;

    IF @user_perm_json_sno IS NULL
        THROW 60002, 'No active nt_user_permissions_json row for this ecno — use sp_nt_SaveUserPermissionsJson for a first-time grant instead.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@screens_json) WITH (screen_id INT '$.screen_id')
        WHERE screen_id = @screen_id
    )
    BEGIN
        SELECT 'ALREADY_GRANTED' AS result, @user_perm_json_sno AS user_perm_json_sno;
        RETURN;
    END

    DECLARE @newEntry NVARCHAR(MAX) = (
        SELECT @screen_id AS screen_id, JSON_QUERY(@permission_ids) AS permissions
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    -- screens_json is always a JSON array; '[]' needs its own branch or the
    -- LEFT()+',' below would produce a leading-comma '[,{...}]' (invalid JSON).
    DECLARE @updatedScreens NVARCHAR(MAX);
    IF @screens_json IS NULL OR @screens_json IN ('[]', '')
        SET @updatedScreens = '[' + @newEntry + ']';
    ELSE
        SET @updatedScreens = LEFT(@screens_json, LEN(@screens_json) - 1) + ',' + @newEntry + ']';

    UPDATE dbo.nt_user_permissions_json
    SET screens_json = @updatedScreens, updated_date = GETDATE()
    WHERE user_perm_json_sno = @user_perm_json_sno;

    SELECT 'GRANTED' AS result, @user_perm_json_sno AS user_perm_json_sno, @updatedScreens AS screens_json;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_GetWarehouseLocationRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetWarehouseLocationRecords
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        l.location_sno,
        l.location_code,
        l.location_name,
        l.description,
        l.com_snos,
        l.div_snos,
        l.brn_snos,
        cn.com_names,
        dn.div_names,
        bn.brn_names,
        l.is_active,
        l.created_by,
        CONVERT(VARCHAR(30), l.created_at, 120)  AS created_at,
        l.modified_by,
        CONVERT(VARCHAR(30), l.modified_at, 120) AS modified_at
    FROM dbo.warehouse_location_master l
    OUTER APPLY (
        SELECT STRING_AGG(c.com_name, ', ') AS com_names
        FROM OPENJSON(l.com_snos) j
        JOIN dbo.company_master c ON c.com_sno = TRY_CAST(j.value AS INT)
    ) cn
    OUTER APPLY (
        SELECT STRING_AGG(d.div_name, ', ') AS div_names
        FROM OPENJSON(l.div_snos) j
        JOIN dbo.division_master d ON d.div_sno = TRY_CAST(j.value AS INT)
    ) dn
    OUTER APPLY (
        SELECT STRING_AGG(b.brn_name, ', ') AS brn_names
        FROM OPENJSON(l.brn_snos) j
        JOIN dbo.branch_master b ON b.brn_sno = TRY_CAST(j.value AS INT)
    ) bn
    WHERE l.is_active = 'Y'
    ORDER BY l.location_sno;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_GetVendorDrivenBillableChildPOs  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_GetVendorDrivenBillableChildPOs];
GO
-- undo [F2. procedures] dbo.sp_nt_GetVendorDrivenApprovedPRs  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_GetVendorDrivenApprovedPRs];
GO
-- undo [F2. procedures] dbo.sp_nt_GetUserHierarchy
-- restore previous definition
-- ============================================================
-- Org-hierarchy scoping — company/division/branch enforcement
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend/src/Middleware/hierarchyScope.js, PR + PO list endpoints
--
-- Apply with: cd backend && node sql/run_sql.mjs sql/12_hierarchy_scoping.sql
--
-- sp_nt_GetUserHierarchy is new. The two ALTERed procs each get an
-- additive, optional @HierarchyJson param (NULL = unfiltered, matching
-- prior behavior exactly) so existing callers are unaffected until the
-- Node layer starts passing it. dept-level scoping is a follow-up —
-- nt_user_permissions_json.hierarchy_json only carries com/div/brn today.
-- ============================================================

-- ── sp_nt_GetUserHierarchy — lean read of a user's approved com/div/brn ────

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetUserHierarchy
    @Ecno VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX);
    SELECT TOP 1 @HierarchyJson = hierarchy_json
    FROM dbo.nt_user_permissions_json
    WHERE ecno = @Ecno AND is_active = 'Y'
    ORDER BY user_perm_json_sno DESC;

    SELECT com_sno, div_sno, brn_sno
    FROM OPENJSON(@HierarchyJson)
    WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno');
END;
GO
-- undo [F2. procedures] dbo.sp_nt_GetTermsConditionsRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetTermsConditionsRecords
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.tc_sno,
        t.tc_title,
        t.tc_text,
        t.com_sno,  c.com_name,
        t.div_sno,  d.div_name,
        t.brn_sno,  b.brn_name,
        t.dept_sno, dm.dept_name,
        t.is_default,
        t.is_active,
        t.created_by,
        CONVERT(VARCHAR(30), t.created_date, 120)  AS created_date,
        t.modified_by,
        CONVERT(VARCHAR(30), t.modified_date, 120) AS modified_date
    FROM dbo.terms_conditions_master t
    JOIN dbo.company_master  c  ON c.com_sno   = t.com_sno
    JOIN dbo.division_master d  ON d.div_sno   = t.div_sno
    JOIN dbo.branch_master   b  ON b.brn_sno   = t.brn_sno
    JOIN dbo.dept_master     dm ON dm.dept_sno = t.dept_sno
    WHERE t.is_active = 'Y'
    ORDER BY c.com_name, d.div_name, b.brn_name, dm.dept_name, t.is_default DESC, t.tc_title;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_GetSupplierQuotations
-- restore previous definition
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
                sqi.unit_price,  
                sqi.discount_pct,  
                sqi.tax_pct,  
                sqi.total_amount,  
                sqi.delivery_days,  
                sqi.remarks,  
                sqi.is_active  
            FROM supplier_quotation_items sqi  
            INNER JOIN product_master pm  
                ON sqi.prod_sno = pm.prod_sno  
            WHERE sqi.sq_basic_sno = sq.sq_basic_sno  
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
            FROM [Non_Trade].[dbo].[supplier_advance] sa
            WHERE sa.sq_basic_sno = sq.sq_basic_sno
            FOR JSON PATH
        ) AS supplier_advance
    FROM supplier_quotation_info sq  
    WHERE  
        sq.is_active   = 1  
        AND sq.pr_basic_sno = @pr_basic_sno  
        AND sq.pr_no        = @pr_no;  
END;

GO
-- undo [F2. procedures] dbo.sp_nt_GetStockRequests
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetStockRequests
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status       VARCHAR(30) = NULL;
    DECLARE @requested_by VARCHAR(50) = NULL;
    DECLARE @com_sno      INT         = NULL;
    DECLARE @div_sno      INT         = NULL;
    DECLARE @brn_sno      INT         = NULL;
    DECLARE @dept_sno     INT         = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @status       = JSON_VALUE(@jsonInput, '$.status');
        SET @requested_by = JSON_VALUE(@jsonInput, '$.requested_by');
        SET @com_sno      = JSON_VALUE(@jsonInput, '$.com_sno');
        SET @div_sno      = JSON_VALUE(@jsonInput, '$.div_sno');
        SET @brn_sno      = JSON_VALUE(@jsonInput, '$.brn_sno');
        SET @dept_sno     = JSON_VALUE(@jsonInput, '$.dept_sno');
    END

    SELECT
        r.request_sno, r.request_no, r.requested_by, r.requested_name, r.department,
        r.purpose, r.status, r.reject_reason, r.issued_by,
        r.source_type, r.pr_basic_sno, r.pr_no, r.grn_basic_sno,
        r.received_by_ecno, r.received_by_name,
        r.com_sno, c.com_name,
        r.div_sno, dv.div_name,
        r.brn_sno, br.brn_name,
        r.dept_sno, dp.dept_name,
        (SELECT COUNT(*)                 FROM dbo.nt_stock_request_items WHERE request_sno = r.request_sno) AS item_count,
        (SELECT ISNULL(SUM(requested_qty), 0) FROM dbo.nt_stock_request_items WHERE request_sno = r.request_sno) AS total_requested_qty,
        (SELECT ISNULL(SUM(issued_qty), 0)    FROM dbo.nt_stock_request_items WHERE request_sno = r.request_sno) AS total_issued_qty,
        CONVERT(VARCHAR(30), r.issued_at, 120)  AS issued_at,
        CONVERT(VARCHAR(30), r.created_at, 120) AS created_at,
        CONVERT(VARCHAR(30), r.updated_at, 120) AS updated_at
    FROM dbo.nt_stock_requests r
    LEFT JOIN dbo.company_master c   ON c.com_sno  = r.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = r.div_sno
    LEFT JOIN dbo.branch_master br   ON br.brn_sno = r.brn_sno
    LEFT JOIN dbo.dept_master dp     ON dp.dept_sno = r.dept_sno
    WHERE (@status       IS NULL OR r.status       = @status)
      AND (@requested_by IS NULL OR r.requested_by = @requested_by)
      AND (@com_sno      IS NULL OR r.com_sno      = @com_sno)
      AND (@div_sno      IS NULL OR r.div_sno      = @div_sno)
      AND (@brn_sno      IS NULL OR r.brn_sno      = @brn_sno)
      AND (@dept_sno     IS NULL OR r.dept_sno     = @dept_sno)
    ORDER BY r.request_sno DESC;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_GetStockMovements
SET QUOTED_IDENTIFIER OFF
GO
-- restore previous definition

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetStockMovements
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_sno INT = JSON_VALUE(@jsonInput, '$.item_sno');

    SELECT
        movement_sno, item_sno, item_code, item_name, movement_type, quantity,
        balance_after, uom, reference_no, warehouse, reason, created_by,
        CONVERT(VARCHAR(30), created_at, 120) AS created_at
    FROM dbo.nt_stock_movements
    WHERE item_sno = @item_sno
    ORDER BY movement_sno DESC;
END;

GO
SET QUOTED_IDENTIFIER ON
GO
-- undo [F2. procedures] dbo.sp_nt_GetStockBatches  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_GetStockBatches];
GO
-- undo [F2. procedures] dbo.sp_nt_GetServiceTypeRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetServiceTypeRecords
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
-- undo [F2. procedures] dbo.sp_nt_GetServiceRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetServiceRecords
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
-- undo [F2. procedures] dbo.sp_nt_GetServicePoDispatchInfo  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_GetServicePoDispatchInfo];
GO
-- undo [F2. procedures] dbo.sp_nt_GetServicePoCyclesForApproval  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_GetServicePoCyclesForApproval];
GO
-- undo [F2. procedures] dbo.sp_nt_GetServicePoCycles  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_GetServicePoCycles];
GO
-- undo [F2. procedures] dbo.sp_nt_GetServiceAgreementsForApproval
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetServiceAgreementsForApproval
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
-- undo [F2. procedures] dbo.sp_nt_GetServiceAgreements
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetServiceAgreements
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
-- undo [F2. procedures] dbo.sp_nt_GetServiceAgreementHistory  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_GetServiceAgreementHistory];
GO
-- undo [F2. procedures] dbo.sp_nt_GetScreenRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetScreenRecords]

AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SELECT * 
        FROM [Non_Trade].[dbo].[screens] WHERE is_active='Y';
    END TRY

    BEGIN CATCH
        SELECT  
            ERROR_NUMBER() AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage,
            ERROR_LINE() AS ErrorLine,
            ERROR_PROCEDURE() AS ErrorProcedure;
    END CATCH
END
GO
-- undo [F2. procedures] dbo.sp_nt_GetScreenPermissionRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetScreenPermissionRecords]

AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SELECT * 
        FROM [Non_Trade].[dbo].[permissions] WHERE is_active='Y';
    END TRY

    BEGIN CATCH
        SELECT  
            ERROR_NUMBER() AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage,
            ERROR_LINE() AS ErrorLine,
            ERROR_PROCEDURE() AS ErrorProcedure;
    END CATCH
END
GO
-- undo [F2. procedures] dbo.sp_nt_GetProductStockLevels  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_GetProductStockLevels];
GO
-- undo [F2. procedures] dbo.sp_nt_GetProductRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetProductRecords]     
AS    
BEGIN    
    SET NOCOUNT ON;    
        
    BEGIN TRY    
        SELECT * FROM product_master pm inner join category_master cm on pm.cat_sno=cm.cat_sno
        inner join subcategory_master scm on scm.subcat_sno=pm.subcat_sno inner join uom_master um on um.uom_sno=pm.uom_sno
WHERE prod_active='Y'     
ORDER BY prod_sno;    
    END TRY    
    BEGIN CATCH    
         DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();    
        DECLARE @ErrorNumber INT = ERROR_NUMBER();    
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();    
            
        -- Re-throw the original error    
        THROW;    
    END CATCH    
END
GO
-- undo [F2. procedures] dbo.sp_nt_GetPrLinesForPoGrouping
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPrLinesForPoGrouping
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

    ;WITH pr_lines AS (
        SELECT
            pid.pr_item_sno,
            pid.item_type,
            pid.prod_sno,
            pm.prod_name,
            pid.service_sno,
            sm.service_name,
            pid.qty,
            pid.remarks,
            sq.vendor_sno,
            k.company_name AS vendor_name
        FROM dbo.pr_item_details pid
        LEFT JOIN dbo.product_master pm ON pm.prod_sno = pid.prod_sno
        LEFT JOIN dbo.service_master sm ON sm.service_sno = pid.service_sno
        LEFT JOIN dbo.supplier_quotation_items sqi ON sqi.pr_item_sno = pid.pr_item_sno AND sqi.is_active = 1
        LEFT JOIN dbo.supplier_quotation_info sq ON sq.sq_basic_sno = sqi.sq_basic_sno AND sq.is_selected = 1
        LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sq.vendor_sno
        WHERE pid.pr_basic_sno = @pr_basic_sno AND pid.is_active = 'Y'
    )
    SELECT
        vendor_sno,
        vendor_name,
        item_type AS line_type,
        (
            SELECT pl2.pr_item_sno, pl2.item_type, pl2.prod_sno, pl2.prod_name,
                   pl2.service_sno, pl2.service_name, pl2.qty, pl2.remarks
            FROM pr_lines pl2
            WHERE ISNULL(pl2.vendor_sno, -1) = ISNULL(pr_lines.vendor_sno, -1)
              AND pl2.item_type = pr_lines.item_type
            FOR JSON PATH
        ) AS lines,
        (
            SELECT TOP 1 po_basic_sno FROM dbo.po_request_info
            WHERE pr_basic_sno = @pr_basic_sno AND vendor_sno = pr_lines.vendor_sno AND is_active = 'Y'
        ) AS existing_po_basic_sno
    FROM pr_lines
    GROUP BY vendor_sno, vendor_name, item_type
    ORDER BY vendor_name, item_type;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_GetPayableBills
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPayableBills
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        iad.invoice_alloc_sno AS bill_sno,
        i.invoice_no          AS bill_no,
        i.vendor_invoice_no   AS supplier_invoice_no,
        p.po_df_no            AS po_no,
        i.vendor_sno,
        k.company_name        AS vendor_name,
        i.invoice_date,
        i.due_date,
        iad.bucket_type,
        iad.allocated_amount,
        iad.hold_amount,
        iad.matched_qty_ratio,
        iad.release_amount    AS net_payable,
        ISNULL(paid.paidSoFar, 0)                       AS paid_amount,
        (iad.release_amount - ISNULL(paid.paidSoFar, 0)) AS outstanding
    FROM dbo.invoice_allocation_details iad
    JOIN dbo.invoice_info i        ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = i.vendor_sno
    OUTER APPLY (
        SELECT paidSoFar = ISNULL(SUM(pad.amount), 0)
        FROM dbo.payment_allocation_details pad
        WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno
    ) paid
    WHERE iad.is_active = 'Y'
      AND iad.release_amount > ISNULL(paid.paidSoFar, 0) + 0.01
    ORDER BY iad.invoice_alloc_sno DESC;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_GetMyPRTracking
-- restore previous definition
-- ============================================================
-- PR Tracking — surface approver NAMES and the full multi-stage chain
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Follow-up to sql/29_pr_tracking.sql, based on user feedback after the
-- first live walkthrough: the "PR Approval" stage only showed a generic
-- "Pending" status with no indication of WHO it's pending with, and no view
-- of the full approval chain (e.g. "Stage 1: KTM1148 -> Stage 2: KTM1006").
--
-- All 4 objects touched here are ones this feature itself created in file
-- 29 (not pre-existing/UAT procedures) — CREATE OR ALTER is safe, same as
-- every other proc in that file.
--
-- Root cause: the existing (pre-dates this feature, NOT touched)
-- vw_PR_Basic_Info.pr_history_data subquery omits status/approver_ecno/
-- ordering — it only has {status_by, ename, status_date, commends,
-- pr_edit_data}, no way to tell approve vs reject or which stage. Rather
-- than alter that view (also read by sp_get_pr_details_for_approval, which
-- UAT is actively using), this adds two new result sets to
-- sp_nt_GetPRTrackingTimeline that resolve the full stage chain (from
-- workflow_stage.stage_order_json) and the full ordered history (straight
-- from pr_history_data, not the view) independently.
-- ============================================================

-- ── 1. sp_nt_GetMyPRTracking — add current_approver_name ───────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetMyPRTracking
    @ecno VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        pbf.pr_basic_sno,
        pbf.pr_no,
        pbf.status                 AS pr_status,
        pbf.purpose,
        pbf.required_date,
        pbf.created_date,
        vadr.com_name, vadr.div_name, vadr.brn_name, vadr.dept_name,
        pbf.current_approver_id,
        vve_approver.ename         AS current_approver_name,
        sq.sq_basic_sno,
        sq.status                  AS quotation_status,
        po.po_basic_sno,
        po.status                  AS po_status,
        po.supplier_ack_status,
        po.po_pdf_url,
        ds.dispatch_slip_sno,
        ge.gate_entry_sno,
        ge.status                  AS gate_entry_status,
        grn.grn_basic_sno,
        grn.status                 AS grn_status,
        CASE
            WHEN grn.grn_basic_sno IS NOT NULL AND grn.status IN ('Received', 'Partial') THEN 'Received Stock'
            WHEN grn.grn_basic_sno IS NOT NULL                                            THEN 'GRN'
            WHEN ge.gate_entry_sno IS NOT NULL                                             THEN 'Gate Entry'
            WHEN ds.dispatch_slip_sno IS NOT NULL                                          THEN 'Dispatched'
            WHEN po.po_basic_sno IS NOT NULL AND po.status = 'A'                           THEN 'PO Sent / In Transit'
            WHEN po.po_basic_sno IS NOT NULL                                               THEN 'PO Approval'
            WHEN sq.sq_basic_sno IS NOT NULL                                               THEN 'Purchase Quotation'
            WHEN pbf.status = 'A'                                                          THEN 'PR Approved — Awaiting Quotation/PO'
            WHEN pbf.status = 'R'                                                          THEN 'PR Rejected'
            ELSE 'PR Approval Pending'
        END AS current_stage
    FROM dbo.pr_basic_info pbf
    INNER JOIN dbo.vw_ActiveDeptRecords vadr
        ON pbf.brn_sno = vadr.brn_sno AND pbf.dept_sno = vadr.dept_sno
    LEFT JOIN dbo.vw_verified_employees vve_approver
        ON vve_approver.ecno = pbf.current_approver_id
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.supplier_quotation_info
        WHERE pr_basic_sno = pbf.pr_basic_sno ORDER BY sq_basic_sno DESC
    ) sq
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.po_request_info
        WHERE pr_basic_sno = pbf.pr_basic_sno ORDER BY po_basic_sno DESC
    ) po
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.nt_dispatch_slip
        WHERE po_basic_sno = po.po_basic_sno ORDER BY dispatch_slip_sno DESC
    ) ds
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.nt_gate_entry
        WHERE po_basic_sno = po.po_basic_sno ORDER BY gate_entry_sno DESC
    ) ge
    OUTER APPLY (
        SELECT TOP 1 * FROM dbo.grn_basic_info
        WHERE po_basic_sno = po.po_basic_sno ORDER BY grn_basic_sno DESC
    ) grn
    WHERE pbf.created_by = @ecno AND pbf.is_active = 'Y'
    ORDER BY pbf.created_date DESC, pbf.pr_basic_sno DESC;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_GetLoanDetail  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_GetLoanDetail];
GO
-- undo [F2. procedures] dbo.sp_nt_GetLoanAccounts  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_GetLoanAccounts];
GO
-- undo [F2. procedures] dbo.sp_nt_GetInventoryItems
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetInventoryItems
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @category  VARCHAR(50)  = NULL;
    DECLARE @warehouse VARCHAR(100) = NULL;
    DECLARE @status    VARCHAR(20)  = NULL;
    DECLARE @com_sno   INT          = NULL;
    DECLARE @div_sno   INT          = NULL;
    DECLARE @brn_sno   INT          = NULL;
    DECLARE @dept_sno  INT          = NULL;
    DECLARE @exclude_non_regular BIT = 0;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @category  = JSON_VALUE(@jsonInput, '$.category');
        SET @warehouse = JSON_VALUE(@jsonInput, '$.warehouse');
        SET @status    = JSON_VALUE(@jsonInput, '$.status');
        SET @com_sno   = JSON_VALUE(@jsonInput, '$.com_sno');
        SET @div_sno   = JSON_VALUE(@jsonInput, '$.div_sno');
        SET @brn_sno   = JSON_VALUE(@jsonInput, '$.brn_sno');
        SET @dept_sno  = JSON_VALUE(@jsonInput, '$.dept_sno');
        SET @exclude_non_regular = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.exclude_non_regular') AS BIT), 0);
    END

    SELECT
        i.item_sno, i.item_code, i.item_name, i.category, i.sub_category, i.uom,
        i.current_stock, i.min_stock, i.max_stock, i.reorder_qty, i.warehouse,
        i.location AS location_code,
        wl.location_name,
        i.cost_price, i.selling_price, i.status, i.hsn_code, i.description, i.prod_sno,
        i.com_sno, c.com_name,
        i.div_sno, dv.div_name,
        i.brn_sno, br.brn_name,
        i.dept_sno, dp.dept_name,
        CONVERT(VARCHAR(30), i.created_at, 120) AS created_at,
        CONVERT(VARCHAR(30), i.updated_at, 120) AS updated_at
    FROM dbo.nt_inventory_items i
    LEFT JOIN dbo.company_master c   ON c.com_sno  = i.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = i.div_sno
    LEFT JOIN dbo.branch_master br   ON br.brn_sno = i.brn_sno
    LEFT JOIN dbo.dept_master dp     ON dp.dept_sno = i.dept_sno
    LEFT JOIN dbo.product_master pm      ON pm.prod_sno   = i.prod_sno
    LEFT JOIN dbo.subcategory_master scm ON scm.subcat_sno = pm.subcat_sno
    LEFT JOIN dbo.warehouse_location_master wl ON wl.location_code = i.location
    WHERE (@category  IS NULL OR i.category  = @category)
      AND (@warehouse IS NULL OR i.warehouse = @warehouse)
      AND (@status    IS NULL OR i.status    = @status)
      AND (@com_sno   IS NULL OR i.com_sno   = @com_sno)
      AND (@div_sno   IS NULL OR i.div_sno   = @div_sno)
      AND (@brn_sno   IS NULL OR i.brn_sno   = @brn_sno)
      AND (@dept_sno  IS NULL OR i.dept_sno  = @dept_sno)
      AND (@exclude_non_regular = 0 OR ISNULL(scm.subcat_stock_type, 'Regular') <> 'Non-Regular')
    ORDER BY i.item_sno DESC;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_GetGRNsByPO
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNsByPO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_basic_sno INT = JSON_VALUE(@jsonInput, '$.po_basic_sno');

    SELECT
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.gate_entry_sno,
        ge.gate_entry_no,
        b.po_basic_sno,
        p.po_df_no                                  AS po_no,
        b.vendor_sno,
        k.company_name                              AS vendor_name,
        CONVERT(VARCHAR(10), b.received_date, 120)   AS received_date,
        b.doc_ref_no,
        b.vehicle_no,
        b.challan_no,
        b.remarks,
        b.status,
        b.created_by                                 AS received_by,
        b.created_by                                 AS received_by_name,
        CONVERT(VARCHAR(30), b.created_date, 120)     AS created_at,
        (
            SELECT
                gi.grn_item_sno,
                gi.po_item_sno,
                gi.prod_sno,
                gi.prod_name,
                gi.specification,
                gi.po_qty                            AS ordered_qty,
                gi.received_qty,
                gi.rejected_qty,
                gi.unit_name,
                gi.condition,
                gi.hsn_code,
                gi.remarks,
                gi.warehouse_location_sno,
                gi.warehouse_location_name
            FROM dbo.grn_item_details gi
            WHERE gi.grn_basic_sno = b.grn_basic_sno
              AND gi.is_active = 'Y'
            FOR JSON PATH
        ) AS items
    FROM dbo.grn_basic_info b
    LEFT JOIN dbo.nt_gate_entry ge
        ON ge.gate_entry_sno = b.gate_entry_sno
    LEFT JOIN dbo.po_request_info p
        ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k
        ON k.kyc_basic_info_sno = b.vendor_sno
    WHERE b.po_basic_sno = @po_basic_sno
      AND b.is_active = 'Y'
    ORDER BY b.grn_basic_sno DESC;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_GetGRNItemsForInventorySync
-- restore previous definition
-- ── Procs ───────────────────────────────────────────────────────────────────

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNItemsForInventorySync
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @grn_basic_sno INT = JSON_VALUE(@jsonInput, '$.grn_basic_sno');

    SELECT
        gi.grn_item_sno, gi.grn_basic_sno, gi.po_item_sno, gi.prod_sno, gi.prod_name,
        gi.unit_name, gi.received_qty, gi.rejected_qty, gi.warehouse_location_sno,
        gi.inventory_sync_status,
        gb.com_sno, gb.div_sno, gb.brn_sno, gb.dept_sno, gb.created_by,
        'GRN-' + CAST(YEAR(gb.created_date) AS VARCHAR(4)) + '-'
            + RIGHT('000000' + CAST(gb.grn_no AS VARCHAR(6)), 6) AS grn_no
    FROM dbo.grn_item_details gi
    JOIN dbo.grn_basic_info gb ON gb.grn_basic_sno = gi.grn_basic_sno
    WHERE gi.grn_basic_sno = @grn_basic_sno;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_GetDivisionsRecords
-- restore previous definition

CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetDivisionsRecords] 
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        SELECT * FROM vw_ActiveDivisions;
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        -- Re-throw the original error
        THROW;
    END CATCH
END
GO
-- undo [F2. procedures] dbo.sp_nt_GetDeptRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetDeptRecords] 
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        SELECT * FROM vw_ActiveDeptRecords 
 
    END TRY
    BEGIN CATCH
         DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        -- Re-throw the original error
        THROW;
    END CATCH
END

GO
-- undo [F2. procedures] dbo.sp_nt_GetCompanyRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetCompanyRecords] 
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        SELECT * FROM vw_company_address;
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        -- Re-throw the original error
        THROW;
    END CATCH
END

GO
-- undo [F2. procedures] dbo.sp_nt_GetBranchesRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetBranchesRecords] 
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        SELECT * FROM ActiveBranches;
    END TRY
    BEGIN CATCH
       DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        -- Re-throw the original error
        THROW;
    END CATCH
END

GO
-- undo [F2. procedures] dbo.sp_nt_GetBankPaymentVouchersForApproval  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_GetBankPaymentVouchersForApproval];
GO
-- undo [F2. procedures] dbo.sp_nt_GetBankPaymentVouchers  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_GetBankPaymentVouchers];
GO
-- undo [F2. procedures] dbo.sp_nt_GetBankPaymentVoucher  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_GetBankPaymentVoucher];
GO
-- undo [F2. procedures] dbo.sp_nt_GetApprovedPRsForPurchase
-- restore previous definition


CREATE OR ALTER PROCEDURE dbo.sp_nt_GetApprovedPRsForPurchase
    @HierarchyJson NVARCHAR(MAX) = NULL
AS
BEGIN TRY

    WITH pr_with_groups AS
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
            vve.ename                     AS created_by_name,
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
            g.grp                         AS [group],
            CASE
                WHEN g.grp IS NOT NULL AND g.group_count > 1
                    THEN pbf.pr_no + '/' + CAST(g.grp AS VARCHAR(10))
                ELSE pbf.pr_no
            END                            AS pr_no,
            pbf.workflow_types_id,
            pbf.current_approver_id,
            pbf.status,
            pbf.pr_no                     AS base_pr_no,  -- Keep base pr_no for joining

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
                    pid.created_by,
                    pid.created_date,
                    pid.modified_by,
                    pid.modified_date,
                    pid.is_active,
                    pid.[group],
                    pid.pr_no
                FROM pr_item_details pid
                INNER JOIN uom_master uom
                    ON uom.uom_sno = pid.unit
                INNER JOIN product_master pm
                    ON pid.prod_sno = pm.prod_sno
                WHERE pid.pr_basic_sno = pbf.pr_basic_sno
                  AND pid.is_active = 'Y'
                  AND (pid.[group] = g.grp OR (pid.[group] IS NULL AND g.grp IS NULL))
                FOR JSON PATH
            ) AS pr_item_details,

            (
                SELECT ws.stage_order_json
                FROM workflow_stage ws
                WHERE ws.workflow_types_id = pbf.workflow_types_id
                  AND ws.is_active = 'Y'
            ) AS stage_order_json,

            (
                SELECT
                    phd.status_by,
                    vve.ename,
                    phd.status_date,
                    phd.commends,
                    phd.pr_edit_data
                FROM pr_history_data phd
                INNER JOIN vw_verified_employees vve
                    ON phd.status_by = vve.ecno
                WHERE phd.pr_basic_sno = pbf.pr_basic_sno
                FOR JSON PATH
            ) AS pr_history_data,

            g.group_count

        FROM pr_basic_info pbf
        INNER JOIN workflow_types wt
            ON pbf.workflow_types_id = wt.workflow_types_id
        INNER JOIN vw_ActiveDeptRecords vadr
            ON pbf.brn_sno = vadr.brn_sno
           AND pbf.dept_sno = vadr.dept_sno
        INNER JOIN vw_verified_employees vve
            ON pbf.created_by = vve.ecno
        OUTER APPLY
        (
            SELECT
                pid.[group]        AS grp,
                COUNT(*) OVER ()   AS group_count
            FROM pr_item_details pid
            WHERE pid.pr_basic_sno = pbf.pr_basic_sno
              AND pid.is_active = 'Y'
            GROUP BY pid.[group]
        ) g
    )

    SELECT
        pr_basic_sno,
        brn_sno,
        brn_name,
        brn_prefix,
        dept_name,
        div_prefix,
        div_name,
        div_sno,
        com_name,
        com_sno,
        created_by_name,
        dept_sno,
        reg_date,
        required_date,
        priority_sno,
        purpose,
        is_active,
        created_by,
        created_date,
        modified_by,
        modified_date,
        [group],
        pr_no,
        workflow_types_id,
        current_approver_id,
        status,
        pr_item_details,
        stage_order_json,
        pr_history_data,
        CASE
            WHEN (SELECT COUNT(sqi.pr_no)
                  FROM supplier_quotation_info sqi
                  WHERE sqi.pr_no = p.pr_no) > 0
                THEN CAST(1 AS BIT)
            ELSE CAST(0 AS BIT)
        END AS isQuotationSubmitted
    FROM pr_with_groups p
    WHERE status = 'A'
      AND NOT EXISTS
      (
          SELECT 1
          FROM supplier_quotation_history sqh
          WHERE sqh.pr_no = p.pr_no
            AND sqh.is_active = 1
      )
      AND (
          @HierarchyJson IS NULL
          OR EXISTS
          (
              SELECT 1
              FROM OPENJSON(@HierarchyJson)
              WITH (
                  com_sno INT '$.com_sno',
                  div_sno INT '$.div_sno',
                  brn_sno INT '$.brn_sno'
              ) h
              WHERE h.com_sno = p.com_sno
                AND (h.div_sno IS NULL OR h.div_sno = p.div_sno)
                AND (h.brn_sno IS NULL OR h.brn_sno = p.brn_sno)
          )
      );

END TRY
BEGIN CATCH
    DECLARE @ErrorMessage2  NVARCHAR(4000) = ERROR_MESSAGE(),
            @ErrorSeverity2 INT            = ERROR_SEVERITY(),
            @ErrorState2    INT            = ERROR_STATE();

    RAISERROR(@ErrorMessage2, @ErrorSeverity2, @ErrorState2);
END CATCH;
GO
-- undo [F2. procedures] dbo.sp_nt_GetApplicableStockLevel  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_GetApplicableStockLevel];
GO
-- undo [F2. procedures] dbo.sp_nt_GetAllUsersSignUp
-- restore previous definition

  
  
  CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetAllUsersSignUp]  
     
AS  
BEGIN  
    SET NOCOUNT ON;  
     
  Select ntsp.nt_sign_up_sno,ntsp.ecno,vve.ename,vve.dept from nt_sign_up ntsp   
  inner join [Non_Trade].[dbo].[vw_verified_employees] vve on ntsp.ecno=vve.ecno   
  --where ntsp.is_active='N'  
     
     
      
         
    END  
GO
-- undo [F2. procedures] dbo.sp_nt_GetAllGRNs
-- restore previous definition
-- 3. sp_nt_GetAllGRNs / sp_nt_GetGRNsByPO — add location to the item JSON
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetAllGRNs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @status = JSON_VALUE(@jsonInput, '$.status');

    SELECT
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.gate_entry_sno,
        ge.gate_entry_no,
        b.po_basic_sno,
        p.po_df_no                                 AS po_no,
        b.vendor_sno,
        k.company_name                              AS vendor_name,
        CONVERT(VARCHAR(10), b.received_date, 120)  AS received_date,
        b.doc_ref_no,
        b.vehicle_no,
        b.challan_no,
        b.remarks,
        b.status,
        b.created_by                                AS received_by_name,
        CONVERT(VARCHAR(30), b.created_date, 120)    AS created_at,
        (
            SELECT
                gi.grn_item_sno,
                gi.po_item_sno,
                gi.prod_sno,
                gi.prod_name,
                gi.specification,
                gi.po_qty                            AS ordered_qty,
                gi.received_qty,
                gi.rejected_qty,
                gi.unit_name,
                gi.condition,
                gi.hsn_code,
                gi.remarks,
                gi.warehouse_location_sno,
                gi.warehouse_location_name
            FROM dbo.grn_item_details gi
            WHERE gi.grn_basic_sno = b.grn_basic_sno
              AND gi.is_active = 'Y'
            FOR JSON PATH
        )                                            AS items
    FROM dbo.grn_basic_info b
    LEFT JOIN dbo.nt_gate_entry ge   ON ge.gate_entry_sno = b.gate_entry_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = b.vendor_sno
    WHERE b.is_active = 'Y'
      AND (@status IS NULL OR b.status = @status)
    ORDER BY b.grn_basic_sno DESC;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_GetAgreementsDueForNotification
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetAgreementsDueForNotification
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
-- undo [F2. procedures] dbo.sp_nt_ExpireServiceAgreements
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_ExpireServiceAgreements
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.service_agreement
    SET status = 'X'
    WHERE status = 'A' AND period_end_date < CAST(GETDATE() AS DATE);

    SELECT @@ROWCOUNT AS expired_count;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_DirectIssueServicePO
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_DirectIssueServicePO
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
-- undo [F2. procedures] dbo.sp_nt_DeleteProductStockLevel  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_DeleteProductStockLevel];
GO
-- undo [F2. procedures] dbo.sp_nt_DeleteLoanRatePeriod  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_DeleteLoanRatePeriod];
GO
-- undo [F2. procedures] dbo.sp_nt_DeleteLoanPrincipalTxn  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_DeleteLoanPrincipalTxn];
GO
-- undo [F2. procedures] dbo.sp_nt_DeleteInventoryItem
SET QUOTED_IDENTIFIER OFF
GO
-- restore previous definition

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteInventoryItem
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_sno   INT         = JSON_VALUE(@jsonInput, '$.item_sno');
    DECLARE @updated_by VARCHAR(50) = JSON_VALUE(@jsonInput, '$.updated_by');

    UPDATE dbo.nt_inventory_items
    SET status     = 'Discontinued',
        updated_by = @updated_by,
        updated_at = GETDATE()
    WHERE item_sno = @item_sno;

    SELECT item_sno, item_code, item_name, status
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;

GO
SET QUOTED_IDENTIFIER ON
GO
-- undo [F2. procedures] dbo.sp_nt_CreateWorkflowMaster
-- restore previous definition
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateWorkflowMaster]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        -- Input validation
        IF @jsonInput IS NULL OR @jsonInput = ''
        BEGIN
            SELECT 'Failed' AS Status, 'JSON input is required' AS ErrorMessage;
            RETURN;
        END

        -- Validate JSON format
        IF ISJSON(@jsonInput) = 0
        BEGIN
            SELECT 'Failed' AS Status, 'Invalid JSON format' AS ErrorMessage;
            RETURN;
        END

        BEGIN TRANSACTION;

        DECLARE @InsertedCount INT;

        -- Insert records into approval_workflow_master
        INSERT INTO [Non_Trade].[dbo].[approval_workflow_master] (
            workflow_name,
            workflow_code,
            entity_type,
            [description],
            is_active,
            created_by,
            created_at
        )
        SELECT
            LTRIM(RTRIM(workflow_name))   AS workflow_name,
            LTRIM(RTRIM(workflow_code))   AS workflow_code,
            LTRIM(RTRIM(entity_type))     AS entity_type,
            [description],
            ISNULL(is_active, 'Y')        AS is_active,   -- default 'Y' if not provided
            created_by,
            ISNULL(created_at, GETDATE()) AS created_at   -- default current timestamp
        FROM OPENJSON(@jsonInput)
        WITH (
            workflow_name  VARCHAR(200) '$.workflow_name',
            workflow_code  VARCHAR(100) '$.workflow_code',
            entity_type    VARCHAR(100) '$.entity_type',
            [description]  NVARCHAR(MAX) '$.description',
            is_active      CHAR(1)       '$.is_active',
            created_by     INT           '$.created_by',
            created_at     DATETIME      '$.created_at'
        );

        SET @InsertedCount = @@ROWCOUNT;

        COMMIT TRANSACTION;

        -- Return success message with count
        SELECT
            'Success'                                                    AS Status,
            CONCAT('Successfully inserted ', @InsertedCount, ' workflow record(s)') AS Message,
            @InsertedCount                                               AS RecordsInserted;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber   INT            = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT            = ERROR_SEVERITY();

        -- Return structured error instead of re-throwing (optional: use THROW to bubble up)
        SELECT
            'Failed'         AS Status,
            @ErrorMessage    AS ErrorMessage,
            @ErrorNumber     AS ErrorNumber,
            @ErrorSeverity   AS ErrorSeverity;

        -- Uncomment below if you want to re-throw to the caller instead:
        -- THROW;
    END CATCH
END

GO
-- undo [F2. procedures] dbo.sp_nt_CreateVendorDrivenPOFromPR  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_CreateVendorDrivenPOFromPR];
GO
-- undo [F2. procedures] dbo.sp_nt_CreateUomRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateUomRecords]  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
      
    BEGIN TRY  
        -- Input validation  
        IF @jsonInput IS NULL OR @jsonInput = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'JSON input is required' as ErrorMessage;  
            RETURN;  
        END  
          
        -- Validate JSON format  
        IF ISJSON(@jsonInput) = 0  
        BEGIN  
            SELECT 'Failed' as Status, 'Invalid JSON format' as ErrorMessage;  
            RETURN;  
        END  
          
        -- Validate required fields  
        IF JSON_VALUE(@jsonInput, '$.uom_code') IS NULL OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.uom_code'))) = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'uom_code is required' as ErrorMessage;  
            RETURN;  
        END  
        
        BEGIN TRANSACTION;     
          
        DECLARE @InsertedCount INT;  
       
        -- Insert records into uom_master table  
        INSERT INTO [Non_Trade].[dbo].[uom_master](  
            uom_code,   
            uom_name,   
            uom_class,  
            uom_base_uom_flag,
            is_active,
            created_date,
            uom_con_factor
            
        )  
        SELECT   
            LTRIM(RTRIM(uom_code)) as uom_code,   
            LTRIM(RTRIM(uom_name)) as uom_name,   
            LTRIM(RTRIM(uom_class)) as uom_class,  
            LTRIM(RTRIM(uom_base_uom_flag)) as uom_base_uom_flag,
            'Y',
            getDate(),
            uom_con_factor  
        FROM OPENJSON(@jsonInput)  
        WITH (  
            uom_code CHAR(5) '$.uom_code',  
            uom_name VARCHAR(50) '$.uom_name',  
            uom_class VARCHAR(30) '$.uom_class',  
            uom_base_uom_flag CHAR(1) '$.uom_base_uom_flag',  
            uom_con_factor DECIMAL(18,6) '$.uom_con_factor'  
        )  
          
        SET @InsertedCount = @@ROWCOUNT;  
          
        COMMIT TRANSACTION;  
          
        -- Return success message with count  
        SELECT   
            'Success' as Status,   
            CONCAT('Successfully inserted ', @InsertedCount, ' UOM record(s)') as Message,  
            @InsertedCount as RecordsInserted;  
              
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
          
        -- Return detailed error information  
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();  
        DECLARE @ErrorNumber INT = ERROR_NUMBER();  
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();  
          
        -- Re-throw the original error  
        THROW;  
    END CATCH  
END  
GO
-- undo [F2. procedures] dbo.sp_nt_CreateSubCategoryRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateSubCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @cat_sno            INT           = JSON_VALUE(@jsonInput, '$.cat_sno'),
            @subcat_name        NVARCHAR(50)  = JSON_VALUE(@jsonInput, '$.subcat_name'),
            @subcat_description NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.subcat_description'),
            @subcat_notes       NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.subcat_notes'),
            @subcat_stock_type  VARCHAR(20)   = ISNULL(NULLIF(JSON_VALUE(@jsonInput, '$.subcat_stock_type'), ''), 'Regular'),
            @created_by         VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @cat_sno IS NULL OR @subcat_name IS NULL OR LTRIM(RTRIM(@subcat_name)) = ''
    BEGIN
        THROW 50002, N'cat_sno and subcat_name are required.', 1;
        RETURN;
    END;

    IF @subcat_stock_type NOT IN ('Regular', 'Non-Regular')
    BEGIN
        THROW 50005, N'subcat_stock_type must be Regular or Non-Regular.', 1;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.category_master WHERE cat_sno = @cat_sno AND cat_active = 'Y')
    BEGIN
        THROW 50003, N'Category not found.', 1;
        RETURN;
    END;

    IF EXISTS (
        SELECT 1 FROM dbo.subcategory_master
        WHERE cat_sno = @cat_sno AND subcat_name = @subcat_name AND subcat_active = 'Y'
    )
    BEGIN
        THROW 50004, N'A sub category with this name already exists under the selected category.', 1;
        RETURN;
    END;

    INSERT INTO dbo.subcategory_master (
        cat_sno, subcat_name, subcat_description, subcat_notes, subcat_stock_type,
        subcat_active, subcat_created_date, subcat_created_by
    )
    VALUES (
        @cat_sno, @subcat_name, @subcat_description, @subcat_notes, @subcat_stock_type,
        'Y', GETDATE(), @created_by
    );

    SELECT SCOPE_IDENTITY()  AS subcat_sno,
           @subcat_name      AS subcat_name,
           @subcat_stock_type AS subcat_stock_type,
           N'SUCCESS'        AS status,
           N'Sub category created successfully.' AS message;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_CreateServiceTypeRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateServiceTypeRecords
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
-- undo [F2. procedures] dbo.sp_nt_CreateServiceRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateServiceRecords
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
-- undo [F2. procedures] dbo.sp_nt_CreateServiceAgreement
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateServiceAgreement
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
-- undo [F2. procedures] dbo.sp_nt_CreateRecurrenceCadenceRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateRecurrenceCadenceRecords
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
-- undo [F2. procedures] dbo.sp_nt_CreateProductStockLevel  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_CreateProductStockLevel];
GO
-- undo [F2. procedures] dbo.sp_nt_CreateProductRecord
-- restore previous definition
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateProductRecord]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    -- ───────────────────────────────────────────
    -- 1. Basic Input Validation
    -- ───────────────────────────────────────────
    IF @jsonInput IS NULL OR LTRIM(RTRIM(@jsonInput)) = ''
    BEGIN
        SELECT 'Failed' AS Status, 'JSON input is required' AS ErrorMessage;
        RETURN;
    END

    IF ISJSON(@jsonInput) = 0
    BEGIN
        SELECT 'Failed' AS Status, 'Invalid JSON format' AS ErrorMessage;
        RETURN;
    END

    -- ───────────────────────────────────────────
    -- 2. Normalize: wrap single object into array
    --    Handles both {} and [{}] inputs transparently
    -- ───────────────────────────────────────────
    DECLARE @normalizedJson NVARCHAR(MAX);

    SET @normalizedJson = CASE
        WHEN LEFT(LTRIM(@jsonInput), 1) = '{'
        THEN '[' + @jsonInput + ']'   -- single object → wrap as array
        ELSE @jsonInput               -- already an array
    END;

    -- Re-validate after normalization
    IF ISJSON(@normalizedJson) = 0
    BEGIN
        SELECT 'Failed' AS Status, 'Invalid JSON structure after normalization' AS ErrorMessage;
        RETURN;
    END

    BEGIN TRY

        -- ───────────────────────────────────────────
        -- 3. Parse JSON Array into Temp Table ONCE
        --    WITH clause = single parse pass (faster)
        --    ROW_NUMBER() used instead of [key]
        --    ([key] not available when WITH clause is used)
        -- ───────────────────────────────────────────
        CREATE TABLE #parsed_input (
            row_index           INT,
            company_sno         INT,
            division_sno        INT,
            branch_sno          INT,
            dept_sno            INT,
            cat_sno             INT,
            subcat_sno          INT,
            prod_name           VARCHAR(255),
            prod_description    VARCHAR(MAX),
            prod_notes          VARCHAR(MAX),
            hsn_code            VARCHAR(50),
            uom_sno             INT,
            tax_sno             INT,
            prod_uom_con_factor DECIMAL(18,6),
            created_by          VARCHAR(50)
        );

        INSERT INTO #parsed_input
        SELECT
            ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1  AS row_index,
            company_sno,
            division_sno,
            branch_sno,
            dept_sno,
            cat_sno,
            subcat_sno,
            LTRIM(RTRIM(prod_name))                         AS prod_name,
            LTRIM(RTRIM(ISNULL(prod_description, '')))      AS prod_description,
            LTRIM(RTRIM(ISNULL(prod_notes, '')))            AS prod_notes,
            LTRIM(RTRIM(ISNULL(hsn_code, '')))              AS hsn_code,
            uom_sno,
            tax_sno,
            prod_uom_con_factor,
            created_by
        FROM OPENJSON(@normalizedJson)
        WITH (
            company_sno         INT             '$.company_sno',
            division_sno        INT             '$.division_sno',
            branch_sno           INT            '$.branch_sno',
            dept_sno             INT            '$.dept_sno',
            cat_sno              INT            '$.cat_sno',
            subcat_sno           INT            '$.subcat_sno',
            prod_name            VARCHAR(255)   '$.prod_name',
            prod_description     VARCHAR(MAX)   '$.prod_description',
            prod_notes           VARCHAR(MAX)   '$.prod_notes',
            hsn_code             VARCHAR(50)    '$.hsn_code',
            uom_sno              INT            '$.uom_sno',
            tax_sno              INT            '$.tax_sno',
            prod_uom_con_factor  DECIMAL(18,6)  '$.prod_uom_con_factor',
            created_by           VARCHAR(50)    '$.created_by'
        );

        -- ───────────────────────────────────────────
        -- 4. Row-Level Validation
        --    Collects ALL failures across ALL rows before aborting
        -- ───────────────────────────────────────────
        CREATE TABLE #validation_errors (
            row_index    INT,
            ErrorMessage VARCHAR(500)
        );

        INSERT INTO #validation_errors (row_index, ErrorMessage)
        SELECT row_index, 'cat_sno is required'
            FROM #parsed_input WHERE cat_sno IS NULL
        UNION ALL
        SELECT row_index, 'prod_name is required'
            FROM #parsed_input WHERE prod_name IS NULL OR prod_name = ''
        UNION ALL
        SELECT row_index, 'uom_sno is required'
            FROM #parsed_input WHERE uom_sno IS NULL;

        IF EXISTS (SELECT 1 FROM #validation_errors)
        BEGIN
            SELECT
                'Failed'   AS Status,
                row_index  AS RowIndex,
                ErrorMessage
            FROM #validation_errors
            ORDER BY row_index;

            DROP TABLE #parsed_input;
            DROP TABLE #validation_errors;
            RETURN;
        END

        DROP TABLE #validation_errors;

        -- ───────────────────────────────────────────
        -- 5. Validate All Categories Exist (set-based)
        -- ───────────────────────────────────────────
        IF EXISTS (
            SELECT 1
            FROM (SELECT DISTINCT cat_sno FROM #parsed_input) pi
            LEFT JOIN category_master cm ON cm.cat_sno = pi.cat_sno
            WHERE cm.cat_sno IS NULL
        )
        BEGIN
            SELECT
                'Failed'             AS Status,
                pi.cat_sno           AS InvalidCatSno,
                'Category not found' AS ErrorMessage
            FROM (SELECT DISTINCT cat_sno FROM #parsed_input) pi
            LEFT JOIN category_master cm ON cm.cat_sno = pi.cat_sno
            WHERE cm.cat_sno IS NULL;

            DROP TABLE #parsed_input;
            RETURN;
        END

        -- ───────────────────────────────────────────
        -- 5b. Validate product-specific UOM conversion factor
        --     A non-base UOM with no fixed uom_master.uom_con_factor (e.g.
        --     Box) varies per product, so prod_uom_con_factor must be
        --     supplied. A non-base UOM that already has a fixed factor (e.g.
        --     Dozen), or the base unit itself, needs no per-product entry.
        -- ───────────────────────────────────────────
        IF EXISTS (
            SELECT 1
            FROM #parsed_input pi
            JOIN uom_master um ON um.uom_sno = pi.uom_sno
            WHERE um.uom_base_uom_flag = 'N'
              AND um.uom_con_factor IS NULL
              AND (pi.prod_uom_con_factor IS NULL OR pi.prod_uom_con_factor <= 0)
        )
        BEGIN
            SELECT
                'Failed'                                                    AS Status,
                pi.row_index                                                AS RowIndex,
                'prod_uom_con_factor is required for unit ' + um.uom_name +
                    ' (its conversion is not fixed and varies per product)' AS ErrorMessage
            FROM #parsed_input pi
            JOIN uom_master um ON um.uom_sno = pi.uom_sno
            WHERE um.uom_base_uom_flag = 'N'
              AND um.uom_con_factor IS NULL
              AND (pi.prod_uom_con_factor IS NULL OR pi.prod_uom_con_factor <= 0);

            DROP TABLE #parsed_input;
            RETURN;
        END

        -- ───────────────────────────────────────────
        -- 6. Generate Product Codes — set-based per category
        --    MAX existing seq fetched once per category (with lock)
        --    ROW_NUMBER() per cat assigns each new row its offset
        -- ───────────────────────────────────────────
        CREATE TABLE #products_with_code (
            row_index           INT,
            company_sno         INT,
            division_sno        INT,
            branch_sno          INT,
            dept_sno            INT,
            cat_sno             INT,
            subcat_sno          INT,
            prod_name           VARCHAR(255),
            prod_description    VARCHAR(MAX),
            prod_notes          VARCHAR(MAX),
            prod_code           VARCHAR(50),
            hsn_code            VARCHAR(50),
            uom_sno             INT,
            tax_sno             INT,
            prod_uom_con_factor DECIMAL(18,6),
            created_by          VARCHAR(50)
        );

        ;WITH CategoryPrefix AS (
            SELECT
                cm.cat_sno,
                cm.cat_notes AS cat_prefix,
                ISNULL(MAX(
                    CASE
                        WHEN ISNUMERIC(
                            SUBSTRING(pm.prod_code, LEN(cm.cat_notes) + 1, LEN(pm.prod_code))
                        ) = 1
                        THEN CAST(
                            SUBSTRING(pm.prod_code, LEN(cm.cat_notes) + 1, LEN(pm.prod_code))
                        AS INT)
                        ELSE 0
                    END
                ), 0) AS max_seq
            FROM (SELECT DISTINCT cat_sno FROM #parsed_input) pi
            JOIN category_master cm ON cm.cat_sno = pi.cat_sno
            LEFT JOIN product_master pm WITH (UPDLOCK, ROWLOCK)
                ON  pm.cat_sno   = cm.cat_sno
                AND pm.prod_code LIKE cm.cat_notes + '%'
            GROUP BY cm.cat_sno, cm.cat_notes
        ),
        RankedRows AS (
            SELECT
                pi.*,
                cp.cat_prefix,
                cp.max_seq,
                ROW_NUMBER() OVER (
                    PARTITION BY pi.cat_sno
                    ORDER BY pi.row_index
                ) AS rn
            FROM #parsed_input pi
            JOIN CategoryPrefix cp ON cp.cat_sno = pi.cat_sno
        )
        INSERT INTO #products_with_code
        SELECT
            row_index,
            company_sno,
            division_sno,
            branch_sno,
            dept_sno,
            cat_sno,
            subcat_sno,
            prod_name,
            prod_description,
            prod_notes,
            cat_prefix + RIGHT('00000' + CAST((max_seq + rn) AS VARCHAR(5)), 5) AS prod_code,
            hsn_code,
            uom_sno,
            tax_sno,
            prod_uom_con_factor,
            created_by
        FROM RankedRows;

        DROP TABLE #parsed_input;

        -- ───────────────────────────────────────────
        -- 7. Bulk Insert with OUTPUT clause
        --    All prod_sno values captured safely — no SCOPE_IDENTITY() race
        -- ───────────────────────────────────────────
        CREATE TABLE #inserted_results (
            prod_sno  INT,
            prod_code VARCHAR(50)
        );

        BEGIN TRANSACTION;

            INSERT INTO [dbo].[product_master] (
                company_sno,
                division_sno,
                branch_sno,
                dept_sno,
                cat_sno,
                subcat_sno,
                prod_name,
                prod_description,
                prod_notes,
                prod_code,
                uom_sno,
                tax_sno,
                prod_hsn_code,
                prod_uom_con_factor,
                prod_active,
                prod_created_date,
                prod_created_by
            )
            OUTPUT
                INSERTED.prod_sno,
                INSERTED.prod_code
            INTO #inserted_results (prod_sno, prod_code)
            SELECT
                company_sno,
                division_sno,
                branch_sno,
                dept_sno,
                cat_sno,
                subcat_sno,
                prod_name,
                prod_description,
                prod_notes,
                prod_code,
                uom_sno,
                tax_sno,
                hsn_code             AS prod_hsn_code,
                prod_uom_con_factor,
                'Y'                  AS prod_active,
                GETDATE()            AS prod_created_date,
                created_by           AS prod_created_by
            FROM #products_with_code
            ORDER BY row_index;

        COMMIT TRANSACTION;

        -- ───────────────────────────────────────────
        -- 8. Return Results — joined via prod_code
        -- ───────────────────────────────────────────
        SELECT
            'Success'                       AS Status,
            'Product inserted successfully' AS Message,
            ir.prod_sno,
            ir.prod_code,
            pwc.prod_name,
            pwc.cat_sno,
            pwc.row_index                   AS InputRowIndex
        FROM #inserted_results ir
        JOIN #products_with_code pwc ON pwc.prod_code = ir.prod_code
        ORDER BY pwc.row_index;

        DROP TABLE #products_with_code;
        DROP TABLE #inserted_results;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        IF OBJECT_ID('tempdb..#parsed_input')       IS NOT NULL DROP TABLE #parsed_input;
        IF OBJECT_ID('tempdb..#validation_errors')  IS NOT NULL DROP TABLE #validation_errors;
        IF OBJECT_ID('tempdb..#products_with_code') IS NOT NULL DROP TABLE #products_with_code;
        IF OBJECT_ID('tempdb..#inserted_results')   IS NOT NULL DROP TABLE #inserted_results;

        SELECT
            'Failed'        AS Status,
            ERROR_MESSAGE() AS ErrorMessage,
            ERROR_NUMBER()  AS ErrorNumber,
            ERROR_LINE()    AS ErrorLine;
    END CATCH
END
GO
-- undo [F2. procedures] dbo.sp_nt_CreatePriorityRecords
-- restore previous definition

 CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreatePriorityRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
       
       
       
      
        BEGIN TRANSACTION;   
        
        DECLARE @InsertedCount INT;
     
        -- Insert records into ac_master table
        INSERT INTO [Non_Trade].[dbo].[priority_master](
            priority_name, 
            priority_desc
        )
        SELECT 
            LTRIM(RTRIM(priority_name)) as priority_name, 
            LTRIM(RTRIM(priority_desc)) as priority_desc
        FROM OPENJSON(@jsonInput)
        WITH (
            priority_name VARCHAR(50) '$.priority_name',
            priority_desc VARCHAR(50) '$.priority_desc'
        );
        
        SET @InsertedCount = @@ROWCOUNT;
        
        COMMIT TRANSACTION;
        
        -- Return success message with count
        SELECT 
            'Success' as Status, 
            CONCAT('Successfully inserted ', @InsertedCount, ' record(s)') as Message,
            @InsertedCount as RecordsInserted;
            
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        
        -- Return detailed error information
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        THROW;
    END CATCH
END

GO
-- undo [F2. procedures] dbo.sp_nt_CreateNonStaffLogin
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateNonStaffLogin
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 51101, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @login_id        VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.login_id'),
            @full_name       NVARCHAR(150) = JSON_VALUE(@jsonInput, '$.full_name'),
            @designation_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.designation_sno') AS INT),
            @email           VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.email'),
            @phone           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.phone'),
            @password_hash   VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.password_hash'),
            @created_by      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @login_id IS NULL OR @full_name IS NULL OR @designation_sno IS NULL
       OR @email IS NULL OR @password_hash IS NULL
    BEGIN
        THROW 51102, N'login_id, full_name, designation_sno, email and password_hash are required.', 1;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.designation_master WHERE designation_sno = @designation_sno AND is_active = 'Y')
    BEGIN
        THROW 51103, N'Unknown or inactive designation_sno.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.nt_nonstaff_login WHERE login_id = @login_id)
    BEGIN
        THROW 51104, N'A user with this login ID already exists.', 1;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.nt_nonstaff_login WHERE email = @email AND is_active = 'Y')
    BEGIN
        THROW 51105, N'A user with this email already exists.', 1;
        RETURN;
    END;

    INSERT INTO dbo.nt_nonstaff_login (
        login_id, full_name, designation_sno, email, phone,
        password_hash, must_reset_password, is_active, created_by
    )
    VALUES (
        @login_id, @full_name, @designation_sno, @email, @phone,
        @password_hash, 'Y', 'Y', @created_by
    );

    SELECT nonstaff_login_sno, login_id, full_name, must_reset_password
    FROM dbo.nt_nonstaff_login WHERE login_id = @login_id;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_CreateInventoryItem
SET QUOTED_IDENTIFIER OFF
GO
-- restore previous definition

CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateInventoryItem
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_code      VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.item_code');
    DECLARE @item_name      VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.item_name');
    DECLARE @category       VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.category');
    DECLARE @sub_category   VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.sub_category');
    DECLARE @uom            VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.uom');
    DECLARE @current_stock  DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.current_stock');
    DECLARE @min_stock      DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.min_stock');
    DECLARE @max_stock      DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.max_stock');
    DECLARE @reorder_qty    DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.reorder_qty');
    DECLARE @warehouse      VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.warehouse');
    DECLARE @location       VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.location');
    DECLARE @cost_price     DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.cost_price');
    DECLARE @selling_price  DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.selling_price');
    DECLARE @status         VARCHAR(20)   = ISNULL(JSON_VALUE(@jsonInput, '$.status'), 'Active');
    DECLARE @hsn_code       VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.hsn_code');
    DECLARE @description    VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.description');
    DECLARE @prod_sno       INT           = JSON_VALUE(@jsonInput, '$.prod_sno');
    DECLARE @created_by     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @item_code IS NULL OR @item_name IS NULL
    BEGIN
        RAISERROR('item_code and item_name are required.', 16, 1);
        RETURN;
    END

    SET @current_stock = ISNULL(@current_stock, 0);

    DECLARE @item_sno INT;

    BEGIN TRANSACTION;
    BEGIN TRY
        INSERT INTO dbo.nt_inventory_items (
            item_code, item_name, category, sub_category, uom, current_stock,
            min_stock, max_stock, reorder_qty, warehouse, location, cost_price,
            selling_price, status, hsn_code, description, prod_sno, created_by, created_at
        )
        VALUES (
            @item_code, @item_name, @category, @sub_category, @uom, @current_stock,
            ISNULL(@min_stock, 0), ISNULL(@max_stock, 0), ISNULL(@reorder_qty, 0),
            @warehouse, @location, ISNULL(@cost_price, 0),
            ISNULL(@selling_price, 0), @status, @hsn_code, @description, @prod_sno, @created_by, GETDATE()
        );

        SET @item_sno = SCOPE_IDENTITY();

        IF @current_stock > 0
        BEGIN
            INSERT INTO dbo.nt_stock_movements (
                item_sno, item_code, item_name, movement_type, quantity,
                balance_after, uom, reference_no, warehouse, reason, created_by, created_at
            )
            VALUES (
                @item_sno, @item_code, @item_name, 'IN', @current_stock,
                @current_stock, @uom, NULL, @warehouse, 'Opening Stock', @created_by, GETDATE()
            );
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT item_sno, item_code, item_name, category, uom, current_stock, warehouse, status
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;

GO
SET QUOTED_IDENTIFIER ON
GO
-- undo [F2. procedures] dbo.sp_nt_CreateGstStateRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateGstStateRecords]  
    @jsonInput NVARCHAR(MAX)  
AS  
BEGIN  
    SET NOCOUNT ON;  
      
    BEGIN TRY  
        -- Input validation  
        IF @jsonInput IS NULL OR @jsonInput = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'JSON input is required' as ErrorMessage;  
            RETURN;  
        END  
          
        -- Validate JSON format  
        IF ISJSON(@jsonInput) = 0  
        BEGIN  
            SELECT 'Failed' as Status, 'Invalid JSON format' as ErrorMessage;  
            RETURN;  
        END  
          
        -- Validate required fields  
        IF JSON_VALUE(@jsonInput, '$.gst_state_un_name') IS NULL OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.gst_state_un_name'))) = ''  
        BEGIN  
            SELECT 'Failed' as Status, 'State/Un name is required' as ErrorMessage;  
            RETURN;  
        END  
        
        BEGIN TRANSACTION;     
          
        DECLARE @InsertedCount INT;  
     
        -- Insert records into gst_master table (corrected table name)  
        INSERT INTO [Non_Trade].[dbo].[gst_master](  
            gst_state_un_name,   
            gst_code,
            is_active,
            created_date,
            gst_alpha_code  
        )  
        SELECT   
            LTRIM(RTRIM(gst_state_un_name)) as gst_state_un_name,   
            LTRIM(RTRIM(gst_code)) as gst_code, 
            'Y',
            getDate(),
            LTRIM(RTRIM(gst_alpha_code)) as gst_alpha_code  
        FROM OPENJSON(@jsonInput)  
        WITH (  
            gst_state_un_name VARCHAR(50) '$.gst_state_un_name',  
            gst_code VARCHAR(10) '$.gst_code',  
            gst_alpha_code VARCHAR(5) '$.gst_alpha_code'  
        );  
          
        SET @InsertedCount = @@ROWCOUNT;  
          
        COMMIT TRANSACTION;  
          
        -- Return success message with count  
        SELECT   
            'Success' as Status,   
            CONCAT('Successfully inserted ', @InsertedCount, ' GST record(s)') as Message,  
            @InsertedCount as RecordsInserted;  
              
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
          
          DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();  
        DECLARE @ErrorNumber INT = ERROR_NUMBER();  
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();  
          
        -- Re-throw the original error  
        THROW;  
    END CATCH  
END
GO
-- undo [F2. procedures] dbo.sp_nt_CreateGRN
-- restore previous definition
-- =============================================
-- 2. sp_nt_CreateGRN v3 — adds warehouse_location_sno/_name per item
-- =============================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateGRN
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    -------------------------------------------------------------------
    -- Parse header-level fields from JSON input
    -------------------------------------------------------------------
    DECLARE @gate_entry_sno INT           = JSON_VALUE(@jsonInput, '$.gate_entry_sno');
    DECLARE @po_basic_sno   INT           = JSON_VALUE(@jsonInput, '$.po_basic_sno');
    DECLARE @vendor_sno     INT           = JSON_VALUE(@jsonInput, '$.vendor_sno');
    DECLARE @received_date  DATE          = JSON_VALUE(@jsonInput, '$.received_date');
    DECLARE @doc_ref_no     VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.doc_ref_no');
    DECLARE @vehicle_no     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.vehicle_no');
    DECLARE @challan_no     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.challan_no');
    DECLARE @remarks        VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.remarks');
    DECLARE @created_by     VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
    DECLARE @items          NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');

    -------------------------------------------------------------------
    -- Validation
    -------------------------------------------------------------------
    IF @gate_entry_sno IS NULL OR @po_basic_sno IS NULL OR @received_date IS NULL
    BEGIN
        RAISERROR('gate_entry_sno, po_basic_sno and received_date are required.', 16, 1);
        RETURN;
    END

    IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
    BEGIN
        RAISERROR('At least one item is required.', 16, 1);
        RETURN;
    END

    -------------------------------------------------------------------
    -- Derive org context from the PO
    -------------------------------------------------------------------
    DECLARE @grn_basic_sno INT;
    DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT;

    SELECT
        @com_sno  = com_sno,
        @div_sno  = div_sno,
        @brn_sno  = brn_sno,
        @dept_sno = dept_sno
    FROM dbo.po_request_info
    WHERE po_basic_sno = @po_basic_sno;

    BEGIN TRANSACTION;
    BEGIN TRY

        -------------------------------------------------------------------
        -- Header insert
        -------------------------------------------------------------------
        DECLARE @grn_no INT;
        SELECT @grn_no = ISNULL(MAX(grn_no), 0) + 1 FROM dbo.grn_basic_info;

        INSERT INTO dbo.grn_basic_info (
            grn_no, com_sno, div_sno, brn_sno, dept_sno,
            gate_entry_sno, po_basic_sno, vendor_sno,
            received_date, doc_ref_no, vehicle_no, challan_no, remarks,
            is_active, status, created_by, created_date
        )
        VALUES (
            @grn_no, @com_sno, @div_sno, @brn_sno, @dept_sno,
            @gate_entry_sno, @po_basic_sno, @vendor_sno,
            @received_date, @doc_ref_no, @vehicle_no, @challan_no, @remarks,
            'Y', 'Received', @created_by, GETDATE()
        );

        SET @grn_basic_sno = SCOPE_IDENTITY();

        -------------------------------------------------------------------
        -- Line item insert (with warehouse location lookup)
        -------------------------------------------------------------------
        INSERT INTO dbo.grn_item_details (
            grn_basic_sno, po_item_sno, prod_sno, prod_name, specification,
            po_qty, received_qty, diff_qty, rejected_qty, unit_name,
            condition, hsn_code, remarks,
            warehouse_location_sno, warehouse_location_name,
            created_by, created_date, is_active
        )
        SELECT
            @grn_basic_sno,
            j.po_item_sno,
            j.prod_sno,
            j.prod_name,
            j.specification,
            j.ordered_qty,
            j.received_qty,
            (ISNULL(j.received_qty, 0) - ISNULL(j.ordered_qty, 0)),
            ISNULL(j.rejected_qty, 0),
            j.unit_name,
            ISNULL(j.condition, 'Good'),
            NULLIF(LTRIM(RTRIM(j.hsn_code)), ''),
            j.remarks,
            j.warehouse_location_sno,
            wl.location_name,
            @created_by,
            GETDATE(),
            'Y'
        FROM OPENJSON(@items)
        WITH (
            po_item_sno            INT           '$.po_item_sno',
            prod_sno                INT           '$.prod_sno',
            prod_name               VARCHAR(255)  '$.prod_name',
            specification           VARCHAR(500)  '$.specification',
            ordered_qty             DECIMAL(18,2) '$.ordered_qty',
            received_qty            DECIMAL(18,2) '$.received_qty',
            rejected_qty            DECIMAL(18,2) '$.rejected_qty',
            unit_name               VARCHAR(50)   '$.unit_name',
            condition               VARCHAR(20)   '$.condition',
            hsn_code                VARCHAR(10)   '$.hsn_code',
            remarks                 VARCHAR(500)  '$.remarks',
            warehouse_location_sno  INT           '$.warehouse_location_sno'
        ) j
        LEFT JOIN dbo.warehouse_location_master wl
            ON wl.location_sno = j.warehouse_location_sno;

        -------------------------------------------------------------------
        -- Line-level audit trail
        -------------------------------------------------------------------
        INSERT INTO dbo.grn_history_data (
            event_type, po_basic_sno, po_item_sno, grn_basic_sno, gate_entry_sno,
            qty, pending_qty_after, to_status, status_by, remarks
        )
        SELECT
            'Item Received',
            @po_basic_sno,
            j.po_item_sno,
            @grn_basic_sno,
            @gate_entry_sno,
            j.received_qty,
            (ISNULL(j.ordered_qty, 0) - ISNULL(j.received_qty, 0)),
            'Received',
            @created_by,
            j.remarks
        FROM OPENJSON(@items)
        WITH (
            po_item_sno   INT           '$.po_item_sno',
            ordered_qty   DECIMAL(18,2) '$.ordered_qty',
            received_qty  DECIMAL(18,2) '$.received_qty',
            remarks       VARCHAR(500)  '$.remarks'
        ) j;

        -------------------------------------------------------------------
        -- Header-level audit trail
        -------------------------------------------------------------------
        INSERT INTO dbo.grn_history_data (
            event_type, po_basic_sno, grn_basic_sno, gate_entry_sno,
            to_status, status_by, remarks
        )
        VALUES (
            'GRN Created', @po_basic_sno, @grn_basic_sno, @gate_entry_sno,
            'Received', @created_by, @remarks
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    -------------------------------------------------------------------
    -- Return the created GRN header
    -------------------------------------------------------------------
    SELECT
        b.grn_basic_sno,
        'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-'
            + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
        b.gate_entry_sno,
        b.po_basic_sno,
        b.vendor_sno,
        CONVERT(VARCHAR(10), b.received_date, 120) AS received_date,
        b.doc_ref_no,
        b.vehicle_no,
        b.challan_no,
        b.remarks,
        b.status,
        CONVERT(VARCHAR(30), b.created_date, 120) AS created_at
    FROM dbo.grn_basic_info b
    WHERE b.grn_basic_sno = @grn_basic_sno;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_CreateBankPaymentVoucher  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_CreateBankPaymentVoucher];
GO
-- undo [F2. procedures] dbo.sp_nt_CreateAcYearRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateAcYearRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        -- Input validation
        IF @jsonInput IS NULL OR @jsonInput = ''
        BEGIN
            SELECT 'Failed' as Status, 'JSON input is required' as ErrorMessage;
            RETURN;
        END
        
        -- Validate JSON format
        IF ISJSON(@jsonInput) = 0
        BEGIN
            SELECT 'Failed' as Status, 'Invalid JSON format' as ErrorMessage;
            RETURN;
        END
        
        -- Validate required fields
        IF JSON_VALUE(@jsonInput, '$.ac_year_code') IS NULL OR LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.ac_year_code'))) = ''
        BEGIN
            SELECT 'Failed' as Status, 'Ac year code is required' as ErrorMessage;
            RETURN;
        END
      
        BEGIN TRANSACTION;   
        
        DECLARE @InsertedCount INT;
     
        -- Insert records into ac_master table
        INSERT INTO [Non_Trade].[dbo].[ac_master](
            ac_year_code, 
            ac_year
        )
        SELECT 
            LTRIM(RTRIM(ac_year_code)) as ac_year_code, 
            LTRIM(RTRIM(ac_year)) as ac_year
        FROM OPENJSON(@jsonInput)
        WITH (
            ac_year_code VARCHAR(50) '$.ac_year_code',
            ac_year VARCHAR(50) '$.ac_year'
        );
        
        SET @InsertedCount = @@ROWCOUNT;
        
        COMMIT TRANSACTION;
        
        -- Return success message with count
        SELECT 
            'Success' as Status, 
            CONCAT('Successfully inserted ', @InsertedCount, ' record(s)') as Message,
            @InsertedCount as RecordsInserted;
            
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        
        -- Return detailed error information
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        -- Re-throw the original error
        THROW;
    END CATCH
END

GO
-- undo [F2. procedures] dbo.sp_nt_CalcLoanVoucher  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_CalcLoanVoucher];
GO
-- undo [F2. procedures] dbo.sp_nt_BuildServicePoCycleSplit  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_BuildServicePoCycleSplit];
GO
-- undo [F2. procedures] dbo.sp_nt_AutoCreateStockIssueFromGRN
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_AutoCreateStockIssueFromGRN
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_item_sno   INT           = JSON_VALUE(@jsonInput, '$.po_item_sno');
    DECLARE @item_sno      INT           = JSON_VALUE(@jsonInput, '$.item_sno');
    DECLARE @qty           DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.qty');
    DECLARE @grn_basic_sno INT           = JSON_VALUE(@jsonInput, '$.grn_basic_sno');
    DECLARE @grn_no        VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.grn_no');
    DECLARE @created_by    VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @po_item_sno IS NULL OR @item_sno IS NULL OR @qty IS NULL OR @qty <= 0
        RETURN;

    -- Resolve PR origin + the product's subcategory stock type in one hop.
    DECLARE @pr_item_sno    INT,
            @pr_basic_sno   INT,
            @pr_no          VARCHAR(20),
            @requester_ecno VARCHAR(20),
            @com_sno        INT, @div_sno INT, @brn_sno INT, @dept_sno INT,
            @stock_type     VARCHAR(20);

    SELECT
        @pr_item_sno    = pid.pr_item_sno,
        @pr_basic_sno   = pb.pr_basic_sno,
        @pr_no          = pb.pr_no,
        @requester_ecno = pb.created_by,
        @com_sno        = pb.com_sno,
        @div_sno        = pb.div_sno,
        @brn_sno        = pb.brn_sno,
        @dept_sno       = pb.dept_sno,
        @stock_type     = scm.subcat_stock_type
    FROM dbo.po_item_details poid
    JOIN dbo.pr_item_details pid ON pid.pr_item_sno = poid.pr_item_sno
    JOIN dbo.pr_basic_info pb    ON pb.pr_basic_sno = pid.pr_basic_sno
    LEFT JOIN dbo.product_master pm     ON pm.prod_sno   = pid.prod_sno
    LEFT JOIN dbo.subcategory_master scm ON scm.subcat_sno = pm.subcat_sno
    WHERE poid.po_item_sno = @po_item_sno;

    -- Not PR-traceable (e.g. a direct/Store PO line) -> nothing to create,
    -- nothing to notify.
    IF @pr_item_sno IS NULL
        RETURN;

    -- Idempotency: this exact Non-Regular GRN line already produced a
    -- request (a retried GRN post). Nothing new to create or (re-)notify.
    IF @stock_type = 'Non-Regular' AND EXISTS (
        SELECT 1
        FROM dbo.nt_stock_request_items sri
        JOIN dbo.nt_stock_requests sr ON sr.request_sno = sri.request_sno
        WHERE sr.grn_basic_sno = @grn_basic_sno AND sri.po_item_sno = @po_item_sno
    )
        RETURN;

    DECLARE @requester_name VARCHAR(255);
    SELECT @requester_name = ename FROM dbo.vw_verified_employees WHERE ecno = @requester_ecno;

    DECLARE @item_code VARCHAR(50), @item_name VARCHAR(255), @uom VARCHAR(20);
    SELECT @item_code = item_code, @item_name = item_name, @uom = uom
    FROM dbo.nt_inventory_items WHERE item_sno = @item_sno;

    DECLARE @request_sno INT, @request_no VARCHAR(30);

    -- Non-Regular only: auto-create the directly-issuable Pending request so
    -- the requester never has to raise a manual Store Requisition.
    IF @stock_type = 'Non-Regular'
    BEGIN
        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));

        BEGIN TRANSACTION;
        BEGIN TRY
            DECLARE @seq INT;
            SELECT @seq = ISNULL(MAX(CAST(RIGHT(request_no, 4) AS INT)), 0) + 1
            FROM dbo.nt_stock_requests WITH (UPDLOCK, HOLDLOCK)
            WHERE request_no LIKE 'SR-' + @year + '-%';

            SET @request_no = 'SR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

            INSERT INTO dbo.nt_stock_requests (
                request_no, requested_by, requested_name, purpose, status,
                source_type, pr_basic_sno, pr_no, grn_basic_sno,
                com_sno, div_sno, brn_sno, dept_sno, created_at
            )
            VALUES (
                @request_no, @requester_ecno, @requester_name,
                'Auto: GRN receipt for non-regular item, PR ' + ISNULL(@pr_no, ''), 'Pending',
                'Auto-GRN', @pr_basic_sno, @pr_no, @grn_basic_sno,
                @com_sno, @div_sno, @brn_sno, @dept_sno, GETDATE()
            );

            SET @request_sno = SCOPE_IDENTITY();

            INSERT INTO dbo.nt_stock_request_items (
                request_sno, item_sno, item_code, item_name, uom,
                requested_qty, issued_qty, line_status, pr_item_sno, po_item_sno
            )
            VALUES (
                @request_sno, @item_sno, @item_code, @item_name, @uom,
                @qty, 0, 'Pending', @pr_item_sno, @po_item_sno
            );

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            THROW;
        END CATCH
    END

    -- Always returned when PR-traceable, so the caller can notify the
    -- requester regardless of stock type. request_sno/request_no are only
    -- non-NULL when the Non-Regular auto-create above just ran.
    SELECT
        @requester_ecno AS requester_ecno,
        @requester_name AS requester_name,
        @pr_no          AS pr_no,
        @pr_basic_sno   AS pr_basic_sno,
        @stock_type     AS stock_type,
        @item_name      AS item_name,
        @uom            AS uom,
        @qty            AS qty,
        @request_sno    AS request_sno,
        @request_no     AS request_no;
END;
GO
-- undo [F2. procedures] dbo.sp_nt_ApproveSupplierQuotation
-- restore previous definition
-- ============================================================
-- Part B2 — PO grouping/combining: patch sp_nt_ApproveSupplierQuotation +
-- new sp_nt_GetPrLinesForPoGrouping
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- BACKUP of the pre-patch live definition is at
-- backend-stpl/sql/backups/pre_B2_2026-08-14T04-03-02-773Z.sql — that file
-- is a directly-runnable CREATE OR ALTER that restores exact prior behavior
-- if anything here needs to be rolled back.
--
-- Why this is needed
-- ------------------
-- Civil_Electrical_Transportation_Requisition_Flow.pdf's grouping rule: same
-- vendor + same PR always shares one PO document, whether the lines are
-- MATERIAL or SERVICE. sp_nt_CreateServicePO (07_po_service_extensions.sql)
-- already does its half of this — it looks for an existing active PO on
-- (pr_basic_sno, vendor_sno) before creating a new one. This patch adds the
-- other half: on final quotation approval, before inserting a new
-- po_request_info row, check for that same existing PO (which may already
-- exist because a Service PO for this vendor+PR was created first) and
-- append MATERIAL-section items to it instead. Symmetric, same lookup key,
-- same "append vs create" branching — this is what makes the Electrical
-- worked example (Schneider: panel boards + panel testing -> 1 combined PO,
-- 2 sections) come out to exactly one po_basic_sno regardless of which side
-- (product quotation vs. service PO) gets approved first.
--
-- Also fixes the same "INNER JOIN silently drops service lines" bug found
-- earlier in vw_PR_Basic_Info: the @po_items_json response query INNER
-- JOINed product_master/uom_master, which would exclude any SERVICE-section
-- line already on a combined PO (service lines have prod_sno=NULL) from the
-- approval-confirmation response. Widened to LEFT JOIN + service_master
-- added, so the response shows both sections combined.
--
-- Every other line of the ~400-line proc (reject/forward/backward, stage
-- resolution, workflow history, vendor/PO-header JSON) is preserved
-- byte-for-byte from the backup — only sections 5a/5c/5d/6 changed.
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_ApproveSupplierQuotation
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        ------------------------------------------------------------------
        -- 1. Validate input
        ------------------------------------------------------------------
        IF ISJSON(@jsonInput) = 0
        BEGIN
            RAISERROR('Invalid JSON format for @jsonInput', 16, 1);
            RETURN;
        END

        DECLARE @sq_basic_sno    INT            = TRY_CAST(JSON_VALUE(@jsonInput, '$.sq_basic_sno') AS INT),
                @pr_no           VARCHAR(30)    = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.pr_no'))), ''),
                @comments        VARCHAR(1000)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages NVARCHAR(MAX)  = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by     VARCHAR(30)    = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.approved_by'))), ''),
                @transfer_to     VARCHAR(30)    = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.transfer_to_ecno'))), ''),
                @action          VARCHAR(30)    = LOWER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.action'))));

        IF @sq_basic_sno IS NULL
        BEGIN
            RAISERROR('sq_basic_sno is required.', 16, 1);
            RETURN;
        END

        IF @action IS NULL OR @action NOT IN ('approve', 'reject', 'forward', 'backward')
        BEGIN
            RAISERROR('Invalid action. Use approve | reject | forward | backward.', 16, 1);
            RETURN;
        END

        IF @approved_by IS NULL
        BEGIN
            RAISERROR('approved_by (approver EC number) is required.', 16, 1);
            RETURN;
        END

        IF @action IN ('forward', 'backward')
           AND @transfer_to IS NULL
        BEGIN
            RAISERROR('transfer_to_ecno is required for forward/backward.', 16, 1);
            RETURN;
        END

        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
        BEGIN
            RAISERROR('Invalid or missing approval_stages.', 16, 1);
            RETURN;
        END

        ------------------------------------------------------------------
        -- 2. Load quotation header
        ------------------------------------------------------------------
        DECLARE @pr_basic_sno      INT,
                @vendor_sno        INT,
                @com_sno           INT,
                @div_sno           INT,
                @brn_sno           INT,
                @dept_sno          INT,
                @workflow_types_id INT,
                @cur_transfer_from VARCHAR(30),
                @sq_pr_no          VARCHAR(30);

        SELECT
            @pr_basic_sno      = sq.pr_basic_sno,
            @vendor_sno        = sq.vendor_sno,
            @com_sno           = pr.com_sno,
            @div_sno           = pr.div_sno,
            @brn_sno           = sq.brn_sno,
            @dept_sno          = sq.dept_sno,
            @workflow_types_id = sq.workflow_types_id,
            @cur_transfer_from = sq.transferred_from,
            @sq_pr_no          = sq.pr_no
        FROM supplier_quotation_info sq
        INNER JOIN pr_basic_info pr ON pr.pr_basic_sno = sq.pr_basic_sno
        WHERE sq.sq_basic_sno = @sq_basic_sno
          AND sq.is_active = 1;

        IF @pr_basic_sno IS NULL
        BEGIN
            RAISERROR('Invalid sq_basic_sno or inactive quotation.', 16, 1);
            RETURN;
        END

        IF @pr_no IS NULL
    SET @pr_no = @sq_pr_no;

        ------------------------------------------------------------------
        -- 3. Materialize approval stages into temp table
        ------------------------------------------------------------------
        CREATE TABLE #approval_stages (
            seq_no             INT,
            approver_ecno      VARCHAR(30),
          stage              VARCHAR(100),
            required_approvals VARCHAR(10),
            is_mandatory       CHAR(1),
            escalation_hours   VARCHAR(10),
            approver_condition VARCHAR(200),
            next_approver_ecno VARCHAR(30),
            can_forward        CHAR(1),
            can_backward       CHAR(1),
            can_edit_data      CHAR(1)
        );

        INSERT INTO #approval_stages (
            seq_no, approver_ecno, stage, required_approvals, is_mandatory,
            escalation_hours, approver_condition, next_approver_ecno,
            can_forward, can_backward, can_edit_data
        )
        SELECT
            CAST(oj.[key] AS INT),
            JSON_VALUE(oj.[value], '$.approver_ecno'),
            JSON_VALUE(oj.[value], '$.stage'),
            JSON_VALUE(oj.[value], '$.required_approvals'),
            JSON_VALUE(oj.[value], '$.is_mandatory'),
            JSON_VALUE(oj.[value], '$.escalation_hours'),
            JSON_VALUE(oj.[value], '$.approver_condition'),
            JSON_VALUE(oj.[value], '$.next_approver_ecno'),
            JSON_VALUE(oj.[value], '$.can_forward'),
            JSON_VALUE(oj.[value], '$.can_backward'),
            JSON_VALUE(oj.[value], '$.can_edit_data')
        FROM OPENJSON(@approval_stages) AS oj;

        DECLARE @stage_ecno VARCHAR(30) =
            CASE
                WHEN EXISTS (SELECT 1 FROM #approval_stages WHERE approver_ecno = @approved_by)
                    THEN @approved_by
                ELSE @cur_transfer_from
            END;

        IF @action IN ('approve', 'forward', 'backward')
           AND NOT EXISTS (SELECT 1 FROM #approval_stages WHERE approver_ecno = @stage_ecno)
        BEGIN
            RAISERROR('Current approver is not part of the approval workflow.', 16, 1);
            RETURN;
        END

        BEGIN TRANSACTION;

        ------------------------------------------------------------------
        -- 4A. REJECT
        -- Reject process for all quotations under same PR
        ------------------------------------------------------------------
        IF @action = 'reject'
        BEGIN
            INSERT INTO supplier_quotation_history (
                sq_basic_sno, sq_edit_data, is_active, workflow_types_id,
                approver_ecno, status, status_by, transferred_from,
                transferred_to, comment, action_type, pr_basic_sno,
                selected_by, pr_no
            )
            SELECT
                sq.sq_basic_sno, NULL, 1, sq.workflow_types_id,
                @approved_by, 'R', @approved_by, sq.transferred_from,
                sq.transferred_to, @comments, 'REJECTED', sq.pr_basic_sno,
                NULL, sq.pr_no
            FROM supplier_quotation_info sq
            WHERE sq.pr_no = @pr_no
              AND sq.is_active = 1;

            UPDATE supplier_quotation_info
            SET status           = 'R',
                approver_ecno    = NULL,
                transferred_from = NULL,
                transferred_to   = NULL,
                modifed_by       = @approved_by,
                modifed_date     = GETDATE()
            WHERE pr_no = @pr_no
              AND is_active = 1;

            COMMIT TRANSACTION;
            DROP TABLE #approval_stages;

            SELECT 'REJECTED'    AS result,
                   @sq_basic_sno AS sq_basic_sno,
                   @pr_no        AS pr_no,
                   @approved_by  AS rejected_by,
                   GETDATE()     AS rejected_on,
                   @comments     AS rejection_reason;
            RETURN;
        END

        ------------------------------------------------------------------
        -- 4B. FORWARD / BACKWARD
        -- Update workflow columns for all quotations under same PR
        -- Keep status as process flag only; do not touch is_selected
        ------------------------------------------------------------------
      IF @action IN ('forward', 'backward')
        BEGIN
            DECLARE @can CHAR(1);

            SELECT @can =
                CASE
                    WHEN @action = 'forward' THEN can_forward
                    ELSE can_backward
                END
            FROM #approval_stages
            WHERE approver_ecno = @stage_ecno;

            IF ISNULL(@can, 'N') <> 'Y'
            BEGIN
                ROLLBACK TRANSACTION;
                DROP TABLE #approval_stages;
                RAISERROR('Current approver is not allowed to %s.', 16, 1, @action);
                RETURN;
            END

            INSERT INTO supplier_quotation_history (
                sq_basic_sno, sq_edit_data, is_active, workflow_types_id,
                approver_ecno, status, status_by, transferred_from,
                transferred_to, comment, action_type, pr_basic_sno,
                selected_by, pr_no
            )
            SELECT
                sq.sq_basic_sno, NULL, 1, sq.workflow_types_id,
                @transfer_to, sq.status, @approved_by, @approved_by,
                @transfer_to, @comments, UPPER(@action), sq.pr_basic_sno,
                sq.is_selected, sq.pr_no
            FROM supplier_quotation_info sq
            WHERE sq.pr_no = @pr_no
              AND sq.is_active = 1;

            UPDATE supplier_quotation_info
            SET approver_ecno    = @transfer_to,
                transferred_from = @approved_by,
                transferred_to   = @transfer_to,
                modifed_by       = @approved_by,
                modifed_date     = GETDATE()
            WHERE pr_no = @pr_no
              AND is_active = 1;

            COMMIT TRANSACTION;
            DROP TABLE #approval_stages;

            SELECT UPPER(@action) AS result,
                   @sq_basic_sno  AS sq_basic_sno,
                   @pr_no         AS pr_no,
                   @approved_by   AS transferred_from,
                   @transfer_to   AS transferred_to,
                   GETDATE()      AS transferred_on;
            RETURN;
        END

        ------------------------------------------------------------------
        -- 4C. APPROVE — resolve next stage
        -- Update workflow columns for all quotations under same PR
        -- Keep final status/is_selected only for chosen quotation at final stage
        ------------------------------------------------------------------
        DECLARE @next_approver  VARCHAR(30),
                @next_condition VARCHAR(200);

        ;WITH stage_cte AS
        (
            SELECT
                seq_no,
                approver_ecno,
                LEAD(approver_ecno) OVER (ORDER BY seq_no) AS next_ecno
            FROM #approval_stages
        )
        SELECT
            @next_approver  = s2.approver_ecno,
            @next_condition = s2.approver_condition
        FROM stage_cte s1
        LEFT JOIN #approval_stages s2
               ON s2.approver_ecno = s1.next_ecno
        WHERE s1.approver_ecno = @stage_ecno;

        INSERT INTO supplier_quotation_history (
            sq_basic_sno, sq_edit_data, is_active, workflow_types_id,
            approver_ecno, status, status_by, transferred_from,
            transferred_to, comment, action_type, pr_basic_sno,
            selected_by, pr_no
        )
        VALUES (
            @sq_basic_sno, NULL, 1, @workflow_types_id,
            @approved_by,
            CASE WHEN @next_approver IS NULL THEN 'A' ELSE 'P' END,
            @approved_by, NULL,
            NULL,
            @comments,
            CASE WHEN @next_approver IS NULL THEN 'FINAL_APPROVED' ELSE 'APPROVED' END,
            @pr_basic_sno,
            CASE WHEN @next_approver IS NULL THEN @approved_by ELSE NULL END,
            @pr_no
        );

        ------------------------------------------------------------------
        -- Intermediate approval: move all quotations in same PR
    -- to next approver, but do not finalize selection/status
        ------------------------------------------------------------------
        IF @next_approver IS NOT NULL
        BEGIN
            UPDATE supplier_quotation_info
            SET approver_ecno    = @next_approver,
                transferred_from = NULL,
                transferred_to   = NULL,
                modifed_by       = @approved_by,
                modifed_date     = GETDATE()
            WHERE pr_no = @pr_no
              AND is_active = 1;

            COMMIT TRANSACTION;
            DROP TABLE #approval_stages;

            SELECT 'APPROVED'      AS result,
                   @sq_basic_sno   AS sq_basic_sno,
                   @pr_no          AS pr_no,
                   @approved_by    AS approved_by,
                   GETDATE()       AS approved_on,
                   @next_approver  AS next_approver,
                   @next_condition AS next_condition,
                   'N'             AS is_final;
            RETURN;
        END

        --================================================================
        -- 5. FINAL STAGE → selected quotation only gets approved/selected
        -- other quotations only workflow columns reset; status/is_selected
        -- remain independent
        --================================================================

        UPDATE supplier_quotation_info
        SET status           = 'A',
            is_selected      = 1,
            approver_ecno    = NULL,
            transferred_from = NULL,
            transferred_to   = NULL,
            modifed_by       = @approved_by,
            modifed_date     = GETDATE()
        WHERE sq_basic_sno = @sq_basic_sno
          AND is_active = 1;

        UPDATE supplier_quotation_info
        SET is_selected      = 0,
            approver_ecno    = NULL,
            transferred_from = NULL,
            transferred_to   = NULL,
            modifed_by       = @approved_by,
            modifed_date     = GETDATE()
        WHERE pr_no = @pr_no
          AND sq_basic_sno <> @sq_basic_sno
          AND is_active = 1;

        ------------------------------------------------------------------
        -- 5a. Insert PO header — OR reuse an existing active PO for the
        -- same (pr_basic_sno, vendor_sno) pair (Part B grouping rule: a
        -- Service PO for this vendor+PR may already exist, e.g. the
        -- Electrical worked example's combined PO). Symmetric to the
        -- merge-check in sp_nt_CreateServicePO.
        ------------------------------------------------------------------
        DECLARE @po_basic_sno INT;
        DECLARE @po_df_no VARCHAR(50);
        DECLARE @is_new_po BIT = 0;

        SELECT @po_basic_sno = po_basic_sno, @po_df_no = po_df_no
        FROM po_request_info
        WHERE pr_basic_sno = @pr_basic_sno
          AND vendor_sno = @vendor_sno
          AND is_active = 'Y';

        IF @po_basic_sno IS NULL
        BEGIN
            SET @is_new_po = 1;

            INSERT INTO po_request_info (
                vendor_sno, brn_sno, dept_sno, com_sno, div_sno,
                pr_basic_sno, po_date,
                terms_conditions,
      is_active, workflow_types_id, status,
                po_df_no,
                split_pr_no
            )
            SELECT
                sq.vendor_sno,
                sq.brn_sno,
                sq.dept_sno,
                pr.com_sno,
                pr.div_sno,
                sq.pr_basic_sno,
                GETDATE(),
                sq.payment_terms,
                'Y',
                sq.workflow_types_id,
                'A',
                NULL,
                @pr_no
            FROM supplier_quotation_info sq
            INNER JOIN pr_basic_info pr ON pr.pr_basic_sno = sq.pr_basic_sno
            WHERE sq.sq_basic_sno = @sq_basic_sno;

            SET @po_basic_sno = SCOPE_IDENTITY();

            ------------------------------------------------------------------
            -- 5b. Generate formatted PO number: com_prefix+div_prefix+brn_prefix+seq
            ------------------------------------------------------------------
            DECLARE @po_prefix VARCHAR(30),
                    @next_seq  INT;

            SELECT @po_prefix = ISNULL(vadr.com_prefix, '')
                              + ISNULL(vadr.div_prefix, '')
                              + ISNULL(vadr.brn_prefix, '')
            FROM vw_ActiveDeptRecords vadr
            WHERE vadr.com_sno  = @com_sno
              AND vadr.div_sno  = @div_sno
              AND vadr.brn_sno  = @brn_sno
              AND vadr.dept_sno = @dept_sno;

            IF @po_prefix IS NULL OR @po_prefix = ''
            BEGIN
                ROLLBACK TRANSACTION;
                DROP TABLE #approval_stages;
                RAISERROR('Unable to resolve PO prefix (company/division/branch).', 16, 1);
                RETURN;
            END

            -- Find last sequence for this prefix; lock to avoid duplicates under concurrency
            SELECT @next_seq = ISNULL(MAX(
                       TRY_CAST(SUBSTRING(po_df_no, LEN(@po_prefix) + 1, 20) AS INT)
                   ), 0) + 1
            FROM po_request_info WITH (UPDLOCK, HOLDLOCK)
            WHERE po_df_no LIKE @po_prefix + '%'
              AND TRY_CAST(SUBSTRING(po_df_no, LEN(@po_prefix) + 1, 20) AS INT) IS NOT NULL;

            SET @po_df_no = @po_prefix + RIGHT('000' + CAST(@next_seq AS VARCHAR(10)), 3);

            UPDATE po_request_info
            SET po_df_no = @po_df_no
            WHERE po_basic_sno = @po_basic_sno;
        END

        ------------------------------------------------------------------
        -- 5c. Insert PO line items (po_section='MATERIAL' — a combined PO
        -- may also carry SERVICE-section lines inserted separately by
        -- sp_nt_CreateServicePO, either before or after this runs)
        ------------------------------------------------------------------
       INSERT INTO po_item_details (
    po_basic_sno, pr_item_sno, prod_sno, specification,
    qty, unit, agreed_unit_price, discount_pct, tax_pct,
    total_cost, net_cost, remarks, po_section,
    created_by, created_date, is_active, split_pr_no
)
SELECT
    @po_basic_sno,
    sid.pr_item_sno,
    sid.prod_sno,
    sid.specification,
    sid.qty,
    sid.unit,
    sid.unit_price,
    sid.discount_pct,
    sid.tax_pct,
    sid.total_amount,              -- total_cost
    calc.net_cost,                 -- net_cost
    sid.remarks,
    'MATERIAL',
    @approved_by,
    GETDATE(),
    1,
    @pr_no
FROM supplier_quotation_items sid
CROSS APPLY (
    SELECT
      ((sid.qty * sid.unit_price - (sid.qty * sid.unit_price * ISNULL(sid.discount_pct,0) / 100.0))
            * ISNULL(sid.tax_pct,0) / 100.0) AS net_cost
) calc
WHERE sid.sq_basic_sno = @sq_basic_sno
  AND sid.is_active = 1;

        ------------------------------------------------------------------
        -- 5d. PO creation history
        ------------------------------------------------------------------
        INSERT INTO supplier_quotation_history (
            sq_basic_sno, sq_edit_data, is_active, workflow_types_id,
            approver_ecno, status, status_by, transferred_from,
            transferred_to, comment, action_type, pr_basic_sno,
            selected_by, pr_no
        )
        VALUES (
            @sq_basic_sno, NULL, 1, @workflow_types_id,
            @approved_by, 'A', @approved_by, NULL,
            NULL,
            'PO ' + @po_df_no + CASE WHEN @is_new_po = 1
                THEN ' auto-generated on final quotation approval'
                ELSE ' — MATERIAL lines appended to the existing PO already shared with this vendor on this PR'
                END,
            'PO_CREATED',
            @pr_basic_sno,
            @approved_by,
            @pr_no
        );

        COMMIT TRANSACTION;
        DROP TABLE #approval_stages;

        ------------------------------------------------------------------
        -- 6. Final response
        ------------------------------------------------------------------
        DECLARE @po_header_json NVARCHAR(MAX),
                @vendor_json    NVARCHAR(MAX),
                @po_items_json  NVARCHAR(MAX),
                @approver_name  NVARCHAR(200);

        SELECT @po_header_json = (
            SELECT
                po.po_basic_sno,
                po.po_df_no,
                po.split_pr_no                              AS po_pr_no,
                CONVERT(VARCHAR(23), po.po_date, 126)       AS po_date,
                po.status                                   AS po_status,
                po.terms_conditions,
                vadr.com_sno,
                vadr.com_name,
                ISNULL(vadr.logo, '')                       AS com_logo,
                vadr.company_address,
                vadr.branch_address,
                vadr.div_sno,
                vadr.div_name,
                vadr.div_prefix,
                vadr.brn_name,
                vadr.brn_prefix,
                vadr.dept_name,
                pr.pr_basic_sno                             AS source_pr_basic_sno,
                pr.pr_no                                    AS source_pr_no,
                CONVERT(VARCHAR(23), pr.reg_date, 126)      AS pr_reg_date,
                CONVERT(VARCHAR(23), pr.required_date, 126) AS pr_required_date,
                pr.purpose                                  AS pr_purpose,
                pr.priority_sno
            FROM po_request_info po
            INNER JOIN vw_ActiveDeptRecords vadr
                ON vadr.brn_sno = po.brn_sno
               AND vadr.dept_sno = po.dept_sno
            INNER JOIN pr_basic_info pr
                ON pr.pr_basic_sno = po.pr_basic_sno
            WHERE po.po_basic_sno = @po_basic_sno
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        SELECT @vendor_json = (
            SELECT
               vgaki.kyc_basic_info_sno AS vendor_sno,
                vgaki.company_name       AS vendor_name,
                vgaki.supp_code          AS vendor_code,
                vgaki.contact_person,
                vgaki.mobile_number      AS vendor_mobile,
                vgaki.email              AS vendor_email,
                vgaki.kyc_address        AS vendor_address,
                vgaki.gst_no,
                vgaki.pan_no,
                vgaki.business_type
            FROM vw_get_all_kyc_info vgaki
            WHERE vgaki.kyc_basic_info_sno = @vendor_sno
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        -- v2: LEFT JOIN product_master/uom_master/pr_item_details (were
        -- INNER — would silently exclude SERVICE-section lines already on a
        -- combined PO, since those rows have prod_sno=NULL) + LEFT JOIN
        -- service_master + po_section, so the response shows every line on
        -- the PO, both sections combined.
        SELECT @po_items_json = (
            SELECT
                pid.po_item_sno,
                pid.po_basic_sno,
                @po_df_no                                    AS po_df_no,
                pid.split_pr_no                              AS pr_no,
                pid.pr_item_sno,
                pid.po_section,
                pid.prod_sno,
                pm.prod_name,
                pm.prod_code,
                pm.prod_notes,
                pid.service_sno,
                sm.service_name,
                pid.specification,
                pid.qty,
                pid.unit                                     AS uom_sno,
                uom.uom_name,
                uom.uom_code,
                pid.agreed_unit_price,
                pid.discount_pct,
                pid.tax_pct,
                pid.total_cost,
                pid.net_cost,
                pid.remarks,
                prid.est_cost                                AS pr_est_cost,
                prid.total_cost                              AS pr_total_cost,
                prid.qty                                     AS pr_qty,
                pid.created_by,
                CONVERT(VARCHAR(23), pid.created_date, 126)  AS created_date,
                pid.is_active
            FROM po_item_details pid
            LEFT JOIN product_master pm     ON pm.prod_sno = pid.prod_sno
            LEFT JOIN service_master sm     ON sm.service_sno = pid.service_sno
            LEFT JOIN uom_master uom        ON uom.uom_sno = pid.unit
            LEFT JOIN pr_item_details prid  ON prid.pr_item_sno = pid.pr_item_sno
            WHERE pid.po_basic_sno = @po_basic_sno
              AND pid.is_active = 1
            ORDER BY pid.po_item_sno
            FOR JSON PATH
        );

        SELECT @approver_name = vve.ename
        FROM vw_verified_employees vve
        WHERE vve.ecno = @approved_by;

        IF @approver_name IS NULL
            SELECT @approver_name = nsl.full_name
            FROM dbo.nt_nonstaff_login nsl
            WHERE nsl.login_id = @approved_by;

        SELECT
            'FINAL_APPROVED'                     AS result,
            'Y'                                  AS is_final,
            @sq_basic_sno                        AS sq_basic_sno,
            @pr_no                               AS pr_no,
            @approved_by                         AS final_approved_by,
            @approver_name  AS final_approved_by_name,
            CONVERT(VARCHAR(23), GETDATE(), 126) AS final_approved_on,
            @is_new_po                           AS is_new_po,
            JSON_QUERY(@po_header_json)          AS po_header,
    JSON_QUERY(@vendor_json)             AS vendor,
            JSON_QUERY(@po_items_json)           AS po_items;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL
            DROP TABLE #approval_stages;

        SELECT
            'ERROR'            AS result,
            ERROR_NUMBER()     AS error_number,
            ERROR_MESSAGE()    AS error_message,
            ERROR_LINE()       AS error_line,
            ERROR_PROCEDURE()  AS error_procedure;
    END CATCH
END;
GO
-- undo [F2. procedures] dbo.sp_nt_ApproveServicePoCycle  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_ApproveServicePoCycle];
GO
-- undo [F2. procedures] dbo.sp_nt_ApproveBankPaymentVoucher  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_ApproveBankPaymentVoucher];
GO
-- undo [F2. procedures] dbo.sp_nt_AdjustStock
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_nt_AdjustStock
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    ------------------------------------------------------------
    -- 1. Parse input JSON
    ------------------------------------------------------------
    DECLARE @item_sno      INT           = JSON_VALUE(@jsonInput, '$.item_sno');
    DECLARE @movement_type VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.movement_type');
    DECLARE @quantity      DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.quantity');
    DECLARE @reference_no  VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.reference_no');
    DECLARE @to_warehouse  VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.to_warehouse');
    DECLARE @reason        VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.reason');
    DECLARE @created_by    VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.created_by');

    ------------------------------------------------------------
    -- 2. Validate required fields
    ------------------------------------------------------------
    IF @item_sno IS NULL OR @movement_type IS NULL
    BEGIN
        RAISERROR('item_sno and movement_type are required.', 16, 1);
        RETURN;
    END

    ------------------------------------------------------------
    -- 3. Load current item state
    ------------------------------------------------------------
    DECLARE @current_stock DECIMAL(18,2),
            @warehouse     VARCHAR(100),
            @item_code     VARCHAR(50),
            @item_name     VARCHAR(255),
            @uom           VARCHAR(20);

    DECLARE @com_sno  INT,
            @div_sno  INT,
            @brn_sno  INT,
            @dept_sno INT;

    SELECT
        @current_stock = current_stock,
        @warehouse     = warehouse,
        @item_code     = item_code,
        @item_name     = item_name,
        @uom           = uom,
        @com_sno       = com_sno,
        @div_sno       = div_sno,
        @brn_sno       = brn_sno
        --@dept_sno      = dept_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;

    IF @current_stock IS NULL
    BEGIN
        RAISERROR('Inventory item not found.', 16, 1);
        RETURN;
    END

    ------------------------------------------------------------
    -- 4. Apply movement logic
    ------------------------------------------------------------
    DECLARE @new_stock     DECIMAL(18,2) = @current_stock;
    DECLARE @new_warehouse VARCHAR(100)  = @warehouse;

    IF @movement_type = 'IN'
    BEGIN
        SET @new_stock = @current_stock + ISNULL(@quantity, 0);
    END
    ELSE IF @movement_type = 'OUT'
    BEGIN
        SET @new_stock = @current_stock - ISNULL(@quantity, 0);
    END
    ELSE IF @movement_type = 'ADJUSTMENT'
    BEGIN
        SET @new_stock = ISNULL(@quantity, @current_stock);
    END
    ELSE IF @movement_type = 'TRANSFER'
    BEGIN
        IF @to_warehouse IS NULL
        BEGIN
            RAISERROR('to_warehouse is required for TRANSFER.', 16, 1);
            RETURN;
        END

        SET @new_warehouse = @to_warehouse;
    END
    ELSE
    BEGIN
        RAISERROR('Invalid movement_type ''%s''.', 16, 1, @movement_type);
        RETURN;
    END

    ------------------------------------------------------------
    -- 5. Persist updated stock/warehouse
    ------------------------------------------------------------
    UPDATE dbo.nt_inventory_items
    SET current_stock = @new_stock,
        warehouse      = @new_warehouse,
        updated_by     = @created_by,
        updated_at     = GETDATE()
    WHERE item_sno = @item_sno;

    ------------------------------------------------------------
    -- 6. Log the movement
    ------------------------------------------------------------
    INSERT INTO dbo.nt_stock_movements
    (
        item_sno, item_code, item_name, movement_type, quantity,
        balance_after, uom, reference_no, warehouse, reason,
        com_sno, div_sno, brn_sno, dept_sno, created_by, created_at
    )
    VALUES
    (
        @item_sno, @item_code, @item_name, @movement_type, ISNULL(@quantity, 0),
        @new_stock, @uom, @reference_no, @new_warehouse, @reason,
        @com_sno, @div_sno, @brn_sno, @dept_sno, @created_by, GETDATE()
    );

    ------------------------------------------------------------
    -- 7. Return the inserted movement record
    ------------------------------------------------------------
    SELECT
        movement_sno, item_sno, item_code, item_name, movement_type, quantity,
        balance_after, uom, reference_no, warehouse, reason,
        com_sno, div_sno, brn_sno, created_by,
        CONVERT(VARCHAR(30), created_at, 120) AS created_at
    FROM dbo.nt_stock_movements
    WHERE movement_sno = SCOPE_IDENTITY();
END;
GO
-- undo [F2. procedures] dbo.sp_nt_AddLoanRatePeriod  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_AddLoanRatePeriod];
GO
-- undo [F2. procedures] dbo.sp_nt_AddLoanPrincipalTxn  (new)
DROP PROCEDURE IF EXISTS [dbo].[sp_nt_AddLoanPrincipalTxn];
GO
-- undo [F2. procedures] dbo.sp_InsertPurchaseRecords
-- restore previous definition
CREATE OR ALTER PROCEDURE [dbo].[sp_InsertPurchaseRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE
            @com_sno           INT,
            @div_sno           INT,
            @brn_sno           INT,
            @dept_sno          INT,
            @pr_basic_sno      INT,
            @po_date           DATE,
            @required_date     DATE,
            @priority_sno      INT,
            @purpose           NVARCHAR(500),
            @split_pr_no       VARCHAR(20),
            @created_by        VARCHAR(20),
            @po_basic_sno      INT,
            @workflow_types_id INT,
            @first_approver    VARCHAR(20),
            @items_inserted    INT;

        -- ── Parse JSON ─────────────────────────────────────────────────────
        SELECT
            @brn_sno       = JSON_VALUE(@jsonInput, '$.brn_sno'),
            @dept_sno      = JSON_VALUE(@jsonInput, '$.dept_sno'),
            @pr_basic_sno  = JSON_VALUE(@jsonInput, '$.pr_basic_sno'),
            @created_by    = JSON_VALUE(@jsonInput, '$.created_by'),
            @com_sno       = JSON_VALUE(@jsonInput, '$.com_sno'),
            @div_sno       = JSON_VALUE(@jsonInput, '$.div_sno'),
            @po_date       = NULLIF(JSON_VALUE(@jsonInput, '$.po_date'),       ''),
            @required_date = NULLIF(JSON_VALUE(@jsonInput, '$.required_date'), ''),
            @priority_sno  = JSON_VALUE(@jsonInput, '$.priority_sno'),
            @purpose       = NULLIF(JSON_VALUE(@jsonInput, '$.purpose'),       ''),
            @split_pr_no   = NULLIF(JSON_VALUE(@jsonInput, '$.split_pr_no'),   '');

            SELECT @brn_sno,@dept_sno,@pr_basic_sno,@created_by,@com_sno,@div_sno
        -- ── Field Validations ──────────────────────────────────────────────
        IF @brn_sno IS NULL
            THROW 50001, 'Branch (brn_sno) is required.', 1;

        IF @dept_sno IS NULL
            THROW 50012, 'Department (dept_sno) is required.', 1;

        IF @pr_basic_sno IS NULL
            THROW 50014, 'PR Basic SNO (pr_basic_sno) is required.', 1;

        IF @created_by IS NULL
            THROW 50004, 'Created by is required.', 1;

        IF NOT EXISTS (
            SELECT 1
            FROM OPENJSON(@jsonInput, '$.items')
            WHERE JSON_VALUE(value, '$.prod_sno') IS NOT NULL
              AND JSON_VALUE(value, '$.prod_sno') != ''
              AND JSON_VALUE(value, '$.unit')      IS NOT NULL
              AND JSON_VALUE(value, '$.unit')      != ''
        )
            THROW 50005, 'At least one valid item with prod_sno and unit is required.', 1;

        -- ── Resolve Workflow ───────────────────────────────────────────────
        SELECT TOP 1
            @workflow_types_id = wt.workflow_types_id
        FROM workflow_types wt
        INNER JOIN approval_workflow_master awm
            ON awm.workflow_id = wt.workflow_id
        WHERE wt.brn_sno      = @brn_sno
          AND wt.dept_sno     = @dept_sno
          AND (wt.com_sno     = @com_sno OR @com_sno IS NULL)
          AND (wt.div_sno     = @div_sno OR @div_sno IS NULL)
          AND awm.entity_type = 'PurchaseOrder'
        ORDER BY wt.workflow_types_id;

        --IF @workflow_types_id IS NULL
        --    THROW 50009, 'No approval workflow found for this branch/department.', 1;

        SELECT TOP 1
            @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
        FROM vw_workflow_stages AS ws
        CROSS APPLY OPENJSON(ws.stages_json) AS s
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
        WHERE ws.workflow_types_id = @workflow_types_id
          AND s.[key]  = '0'
          AND s2.[key] = '0';

        --IF @first_approver IS NULL
        --    THROW 50010, 'No first approver found for the resolved workflow.', 1;

        -- ── Insert PO Basic Info ───────────────────────────────────────────
        INSERT INTO [Non_Trade].[dbo].[po_request_info]
        (
            [brn_sno],              [dept_sno],             [com_sno],
            [div_sno],              [pr_basic_sno],         [po_date],
            [required_date],        [priority_sno],         [purpose],
            [is_active],            [workflow_types_id],    [current_approver_id],
            [status],               [split_pr_no]       
        )
        VALUES
        (
            @brn_sno,               @dept_sno,              @com_sno,
            @div_sno,               @pr_basic_sno,          @po_date,
            @required_date,         @priority_sno,          @purpose,
            'Y',                    @workflow_types_id,     @first_approver,
            'P',                    @split_pr_no         
        );

        SET @po_basic_sno = SCOPE_IDENTITY();

        -- ── Insert PO Item Details ─────────────────────────────────────────
        INSERT INTO [Non_Trade].[dbo].[po_item_details]
        (
            [po_basic_sno],         [pr_item_sno],          [prod_sno],
            [prod_name],            [specification],        [qty],
            [unit],                 [unit_name],            [agreed_unit_price],
            [total_cost],           [discount_pct],         [tax_pct],
            [net_cost],             [remarks],              [split_pr_no],
            [is_active]
        )
        SELECT
            @po_basic_sno,
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.pr_item_sno'),              '') AS INT),
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.prod_sno'),                 '') AS INT),
            NULLIF(JSON_VALUE(value, '$.prod_name'),                         ''),
            NULLIF(JSON_VALUE(value, '$.specification'),                     ''),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.qty'),              '') AS DECIMAL(18,4)), 0),
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.unit'),                    '') AS INT),
            NULLIF(JSON_VALUE(value, '$.unit_name'),                         ''),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.agreed_unit_price'),'') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.total_cost'),       '') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.discount_pct'),     '') AS DECIMAL(5,2)),  0),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.tax_pct'),          '') AS DECIMAL(5,2)),  0),
            ISNULL(TRY_CAST(NULLIF(JSON_VALUE(value, '$.net_cost'),         '') AS DECIMAL(18,4)), 0),
            NULLIF(JSON_VALUE(value, '$.remarks'),                           ''),
            @split_pr_no,
            'Y'
        FROM OPENJSON(@jsonInput, '$.items')
        WHERE JSON_VALUE(value, '$.prod_sno') IS NOT NULL
          AND JSON_VALUE(value, '$.prod_sno') != ''
          AND JSON_VALUE(value, '$.unit')      IS NOT NULL
          AND JSON_VALUE(value, '$.unit')      != '';

        SET @items_inserted = @@ROWCOUNT;

        IF @items_inserted = 0
            THROW 50008, 'No items were inserted. Check that items array is valid and non-empty.', 1;

        COMMIT TRANSACTION;

        SELECT
            'Success'       AS Status,
            @po_basic_sno   AS POBasicSno,
            @items_inserted AS ItemsInserted;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT            = ERROR_SEVERITY();
        DECLARE @ErrorState    INT            = ERROR_STATE();

        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END;
GO
-- undo [F2. procedures] dbo.sp_InsertKYCData
-- restore previous definition
  
      
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
            @workflow_types_id  INT;          
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
            
  
          
  
          SET  @workflow_types_id=32;          
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
            legal_name,trade_name,txp_type, gst_status,gst_blk_status ,date_of_reg                          
        )                
        VALUES (                
            @company_name, @contact_name, @email, @mobile_number,                
            @business_type, @is_gst_avail, @gst_no, @is_msme_avail,                
            @msme_no, @pan_no, @created_by, GETDATE(), 'Y', 'P' ,@workflow_types_id ,@approver_ecno ,@supplier_cat_code      
            ,@legal_name,@trade_name,@txp_type,@gst_status,@gst_blk_status,@date_of_reg      
        );                
                
        SET @kyc_basic_info_sno = SCOPE_IDENTITY();                
                
        -- 2. Insert into kyc_address_info                
        IF ISJSON(@addresses) = 1              
        BEGIN              
            INSERT INTO kyc_address_info (                
                kyc_basic_info_sno, address_type, door_no, street, area, city,                
                taluk, state, pincode, location_link, is_primary,                
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
                JSON_VALUE(value, '$.pincode'),                
                NULLIF(JSON_VALUE(value, '$.location_link'), ''),                
                CASE WHEN JSON_VALUE(value, '$.isPrimary') = 'true' THEN 'Y' ELSE 'N' END,                
                GETDATE(), 'Y', 'P'                
            FROM OPENJSON(@addresses);              
        END              
                
        -- 3. Insert into kyc_bank_info                
        IF ISJSON(@bankDetails) = 1              
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
-- undo [F2. procedures] dbo.sp_InserPurchaseRecords
-- restore previous definition
  
  
CREATE OR ALTER PROCEDURE [dbo].[sp_InserPurchaseRecords]  
    @jsonInput   NVARCHAR(MAX)  
    --@po_no       VARCHAR(20) OUTPUT  
AS  
BEGIN  
    SET NOCOUNT ON;  
  
    BEGIN TRY  
        BEGIN TRANSACTION;  
  
        DECLARE  
            @com_sno             INT,  
            @div_sno             INT,  
            @brn_sno             INT,  
            @dept_sno            INT,  
            --@vendor_sno          INT,  
            @pr_basic_sno        INT,  
            --@budget_sno          INT,  
            --@budget_code         VARCHAR(50),  
            @po_date             DATE,  
            @required_date       DATE,  
            @priority_sno        INT,  
            @purpose             NVARCHAR(500),  
            --@terms_conditions    NVARCHAR(MAX),  
            --@delivery_address    NVARCHAR(500),  
            @split_pr_no         VARCHAR(20),  
            @created_by          VARCHAR(20),  
            @current_year        VARCHAR(10),  
            @po_prefix           VARCHAR(20),  
            @sequence_number     INT,  
            @po_basic_sno        INT,  
            @workflow_id         INT,  
            @workflow_types_id   INT,  
            @first_approver      VARCHAR(20),  
            @items_inserted      INT;  
  
        -- ── Generate PO Number ─────────────────────────────────────────────  
        SET @current_year = dbo.fn_GetFinancialYear(GETDATE());  
        SET @po_prefix    = 'PO' + @current_year;  -- e.g. 'PO26-27'  
  
        --SELECT @sequence_number = ISNULL(MAX(  
        --    CASE  
        --        WHEN po_no LIKE @po_prefix + '%'  
        --        THEN TRY_CAST(  
        --                 SUBSTRING(po_no, LEN(@po_prefix) + 1, LEN(po_no))  
        --             AS INT)  
        --        ELSE 0  
        --    END  
        --), 0) + 1  
        --FROM [Non_Trade].[dbo].[po_request_info] WITH (UPDLOCK, HOLDLOCK)  
        --WHERE po_no LIKE @po_prefix + '%';  
  
        --SET @po_no = @po_prefix + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);  
        -- e.g. PO26-270001  
  
        -- ── Parse JSON ─────────────────────────────────────────────────────  
        SELECT  
            @com_sno          = JSON_VALUE(@jsonInput, '$.com_sno'),  
            @div_sno          = JSON_VALUE(@jsonInput, '$.div_sno'),  
            @brn_sno          = JSON_VALUE(@jsonInput, '$.brn_sno'),  
            @dept_sno         = JSON_VALUE(@jsonInput, '$.dept_sno'),  
            --@vendor_sno       = JSON_VALUE(@jsonInput, '$.basicInfo.vendor_sno'),  
            @pr_basic_sno     = JSON_VALUE(@jsonInput, '$.pr_basic_sno'),  
            --@budget_sno       = JSON_VALUE(@jsonInput, '$.basicInfo.budget_sno'),  
            --@budget_code      = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.budget_code'),   ''),  
            @po_date          = JSON_VALUE(@jsonInput, '$.po_date'),  
            @required_date    = JSON_VALUE(@jsonInput, '$.required_date'),  
            @priority_sno     = JSON_VALUE(@jsonInput, '$.priority_sno'),  
            @purpose          = NULLIF(JSON_VALUE(@jsonInput, '$.purpose'),       ''),  
            --@terms_conditions = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.terms_conditions'), ''),  
            --@delivery_address = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.delivery_address'), ''),  
            @split_pr_no      = NULLIF(JSON_VALUE(@jsonInput, '$.split_pr_no'),   ''),  
            @created_by       = JSON_VALUE(@jsonInput, '$.created_by');  
  
        -- ── Field Validations ──────────────────────────────────────────────  
        --IF @com_sno IS NULL  
        --    THROW 50010, 'Company (com_sno) is required.', 1;  
  
        --IF @div_sno IS NULL  
        --    THROW 50011, 'Division (div_sno) is required.', 1;  
  
        --IF @brn_sno IS NULL  
        --    THROW 50001, 'Branch (brn_sno) is required.', 1;  
  
        --IF @dept_sno IS NULL  
        --    THROW 50012, 'Department (dept_sno) is required.', 1;  
  
        --IF @vendor_sno IS NULL  
        --    THROW 50013, 'Vendor (vendor_sno) is required.', 1;  
  
        --IF @po_date IS NULL  
        --    THROW 50002, 'PO date (po_date) is required.', 1;  
  
        --IF @required_date IS NULL  
        --    THROW 50003, 'Required date is required.', 1;  
  
        --IF @created_by IS NULL  
        --    THROW 50004, 'Created by is required.', 1;  
  
        -- Validate items array  
        IF NOT EXISTS (  
            SELECT 1  
            FROM OPENJSON(@jsonInput, '$.items')  
            WHERE JSON_VALUE(value, '$.prod_sno') IS NOT NULL  
              AND JSON_VALUE(value, '$.prod_sno') != ''  
              AND JSON_VALUE(value, '$.unit')      IS NOT NULL  
              AND JSON_VALUE(value, '$.unit')      != ''  
        )  
            THROW 50005, 'At least one valid item with prod_sno and unit is required.', 1;  
  
        -- ── Resolve Workflow ───────────────────────────────────────────────  
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
  
        --IF @workflow_types_id IS NULL  
        --    THROW 50006, 'No workflow configuration found for this branch and department.', 1;  
        -- Resolve first approver  
        SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')  
        FROM vw_workflow_stages AS ws  
        CROSS APPLY OPENJSON(ws.stages_json) AS s  
        CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2  
        WHERE ws.workflow_types_id = @workflow_types_id  
          AND s.[key]  = '0'  
          AND s2.[key] = '0';  
  
        --IF @first_approver IS NULL  
        --    THROW 50007, 'No approver found for the first stage of the workflow.', 1;  
  
        -- ── Insert PO Basic Info ───────────────────────────────────────────  
        INSERT INTO [Non_Trade].[dbo].[po_request_info]  
        (  
                                [brn_sno],  
            [dept_sno],           [com_sno],              [div_sno],  
               [pr_basic_sno],  
            [po_date],            [required_date],        [priority_sno],  
            [purpose],             
            [is_active],          [workflow_types_id],    [current_approver_id],  
            [status],             [split_pr_no]            
              
        )  
        VALUES  
        (  
                                  @brn_sno,  
            @dept_sno,            @com_sno,               @div_sno,  
             @pr_basic_sno,  
            @po_date,             @required_date,         @priority_sno,  
            @purpose,              
            'Y',                  @workflow_types_id,     @first_approver,  
            'P',                  @split_pr_no             
            
        );  
  
        SET @po_basic_sno = SCOPE_IDENTITY();  
  
        -- ── Insert PO Item Details ─────────────────────────────────────────  
        INSERT INTO [Non_Trade].[dbo].[po_item_details]  
        (  
            [po_basic_sno],       [pr_item_sno],          [prod_sno],  
            [prod_name],                   [specification],  
            [qty],                [unit],                 [unit_name],  
            [agreed_unit_price],  [total_cost],           [discount_pct],  
            [tax_pct],            [net_cost],             [remarks],  
            [split_pr_no],        [is_active],            [created_by],  
            [created_date]  
        )  
        SELECT  
            @po_basic_sno,  
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.pr_item_sno'),        '') AS INT),  
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.prod_sno'),           '') AS INT),  
            NULLIF(JSON_VALUE(value, '$.prod_name'),                   ''),  
             
            NULLIF(JSON_VALUE(value, '$.specification'),               ''),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.qty'),                  ''), 0),  
            TRY_CAST(NULLIF(JSON_VALUE(value, '$.unit'),               '') AS INT),  
            NULLIF(JSON_VALUE(value, '$.unit_name'),                   ''),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.agreed_unit_price'),    ''), 0),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.total_cost'),           ''), 0),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.discount_pct'),         ''), 0),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.tax_pct'),              ''), 0),  
            ISNULL(NULLIF(JSON_VALUE(value, '$.net_cost'),             ''), 0),  
            NULLIF(JSON_VALUE(value, '$.remarks'),                     ''),  
            @split_pr_no,  
            'Y',  
            @created_by,  
            GETDATE()  
        FROM OPENJSON(@jsonInput, '$.items')  
        WHERE JSON_VALUE(value, '$.prod_sno') IS NOT NULL  
          AND JSON_VALUE(value, '$.prod_sno') != ''  
          AND JSON_VALUE(value, '$.unit')      IS NOT NULL  
          AND JSON_VALUE(value, '$.unit')      != '';  
  
        SET @items_inserted = @@ROWCOUNT;  
  
        IF @items_inserted = 0  
            THROW 50008, 'No items were inserted. Check that items array is valid and non-empty.', 1;  
  
        COMMIT TRANSACTION;  
  
        SELECT  
            --'PO Data Saved Successfully. PO No: ' + @pr_basic_sno AS Message,  
            --@jsonInput AS 'jsonInput',  
            'Success'                                       AS Status,  
            @po_basic_sno                                   AS POBasicSno,  
            @items_inserted                                 AS ItemsInserted;  
  
    END TRY  
    BEGIN CATCH  
        IF @@TRANCOUNT > 0  
            ROLLBACK TRANSACTION;  
  
        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();  
        DECLARE @ErrorSeverity INT            = ERROR_SEVERITY();  
        DECLARE @ErrorState    INT            = ERROR_STATE();  
  
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);  
    END CATCH  
END;
GO
-- undo [F2. procedures] dbo.sp_Get_Business_Details
-- restore previous definition

  CREATE OR ALTER PROCEDURE [dbo].[sp_Get_Business_Details] 
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        SELECT  [business_types_id]
      ,[business_types_name]
      ,[Description]
      ,[LiabilityType]
      ,[IsActive]
      ,[CreatedAt]
  FROM [Non_Trade].[dbo].[business_types]
WHERE IsActive=1
ORDER BY business_types_id;
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        
        -- Re-throw the original error
        THROW;
    END CATCH
END
GO
-- undo [F2. procedures] dbo.sp_approve_service_agreement
-- restore previous definition
CREATE OR ALTER PROCEDURE dbo.sp_approve_service_agreement
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
-- undo [F2. procedures] dbo.sp_approve_pr_datas
-- restore previous definition
CREATE OR ALTER PROCEDURE sp_approve_pr_datas
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        -- Validate JSON input
        IF ISJSON(@jsonInput) = 0
        BEGIN
            RAISERROR('Invalid JSON format for @jsonInput', 16, 1);
            RETURN;
        END

        -- Extract scalar fields
        DECLARE @pr_no           VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.pr_no'),
                @comments        VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.comments'),
                @approval_stages NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.approval_stages'),
                @approved_by     VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.approved_by'),
                @action          VARCHAR(30)   = JSON_VALUE(@jsonInput, '$.action');  -- 'approve' or 'reject'

        -- Validate action
        IF @action IS NULL OR LTRIM(RTRIM(LOWER(@action))) NOT IN ('approve', 'reject')
        BEGIN
            RAISERROR('Invalid action. Must be ''approve'' or ''reject''.', 16, 1);
            RETURN;
        END

        -- Normalize action to lowercase for comparison
        SET @action = LOWER(LTRIM(RTRIM(@action)));

        -- Validate approval_stages
        IF @approval_stages IS NULL OR ISJSON(@approval_stages) = 0
        BEGIN
            RAISERROR('Invalid or missing approval_stages in JSON', 16, 1);
            RETURN;
        END

        -- Validate approver
        IF @approved_by IS NULL OR LTRIM(RTRIM(@approved_by)) = ''
        BEGIN
            RAISERROR('Approver EC number is required.', 16, 1);
            RETURN;
        END

        -- ✅ TEMP TABLE
        CREATE TABLE #approval_stages (
            seq_no               INT,
            approver_ecno        VARCHAR(30),
            stage                VARCHAR(100),
            required_approvals   VARCHAR(10),
            is_mandatory         CHAR(1),
            escalation_hours     VARCHAR(10),
            approver_condition   VARCHAR(200),
            next_approver_ecno   VARCHAR(30),
            can_forward          CHAR(1),
            can_backward         CHAR(1),
            can_edit_data        CHAR(1)
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

        -- Check PR exists
        DECLARE @pr_basic_sno INT;

        SELECT @pr_basic_sno = pr_basic_sno
        FROM pr_basic_info
        WHERE pr_no = @pr_no AND is_active = 'Y';

        IF @pr_basic_sno IS NULL
        BEGIN
            RAISERROR('Purchase Request not found or inactive: %s', 16, 1, @pr_no);
            RETURN;
        END

        -- =============================================
        -- ✅ REJECT FLOW
        -- =============================================
        IF @action = 'reject'
        BEGIN
            -- Insert rejection into history with status = 'R'
            INSERT INTO pr_history_data (
                pr_basic_sno, pr_edit_data, workflow_types_id,
                approver_ecno, status, status_by,
                status_date, commends, is_active, pr_no
            )
            SELECT
                @pr_basic_sno,
                NULL,
                NULL,
                s.approver_ecno,
                'R',                -- R = Rejected
                @approved_by,
                GETDATE(),
                @comments,          -- Rejection reason stored as comments
                'Y',
                @pr_no
            FROM #approval_stages s
            WHERE s.approver_ecno = @approved_by;

            -- Update PR basic info: status = 'R', clear current approver
            UPDATE pr_basic_info
            SET status             = 'R',           -- R = Rejected
                current_approver_id = NULL           -- No further approval needed
            WHERE pr_basic_sno = @pr_basic_sno;

            DROP TABLE #approval_stages;

            -- Return rejection result
            SELECT
                'REJECTED'       AS result,
                @pr_no           AS pr_no,
                @approved_by     AS rejected_by,
                GETDATE()        AS rejected_on,
                @comments        AS rejection_reason;

            RETURN;
        END

        -- =============================================
        -- ✅ APPROVE FLOW (original logic)
        -- =============================================

        -- Find next approver using LEAD()
        DECLARE @next_current_approver  VARCHAR(30);
        DECLARE @next_condition         VARCHAR(200);
        DECLARE @next_can_forward       CHAR(1);
        DECLARE @next_can_backward      CHAR(1);
        DECLARE @next_is_mandatory      CHAR(1);

        SELECT
            @next_current_approver = next_stage.approver_ecno,
            @next_condition        = next_stage.approver_condition,
            @next_can_forward      = next_stage.can_forward,
            @next_can_backward     = next_stage.can_backward,
            @next_is_mandatory     = next_stage.is_mandatory
        FROM (
            SELECT
                approver_ecno,
                LEAD(approver_ecno, 1, NULL) OVER (ORDER BY seq_no) AS next_approver_ecno
            FROM #approval_stages
        ) current_stage
        LEFT JOIN #approval_stages next_stage
            ON next_stage.approver_ecno = current_stage.next_approver_ecno
        WHERE current_stage.approver_ecno = @approved_by;

        -- Insert approval history
        INSERT INTO pr_history_data (
            pr_basic_sno, pr_edit_data, workflow_types_id,
            approver_ecno, status, status_by,
            status_date, commends, is_active, pr_no
        )
        SELECT
            @pr_basic_sno,
            NULL,
            NULL,
            s.approver_ecno,
            'A',                -- A = Approved
            @approved_by,
            GETDATE(),
            @comments,
            'Y',
            @pr_no
        FROM #approval_stages s
        WHERE s.approver_ecno = @approved_by;

        DECLARE @stages_processed INT = @@ROWCOUNT;

        -- Update current approver (NULL = final stage reached)
        UPDATE pr_basic_info
        SET current_approver_id = @next_current_approver
        WHERE pr_basic_sno = @pr_basic_sno;

        -- If final stage, mark PR as fully Approved
        IF @next_current_approver IS NULL
        BEGIN
            UPDATE pr_basic_info
            SET status = 'A'
            WHERE pr_basic_sno = @pr_basic_sno;
        END

        DROP TABLE #approval_stages;

        -- Return approval result
        SELECT
            'SUCCESS'                                  AS result,
            @pr_no                                     AS pr_no,
            @approved_by                               AS approved_by,
            GETDATE()                                  AS approved_on,
            @stages_processed                          AS stages_processed,
            ISNULL(@next_current_approver, 'FINAL_STAGE') AS next_approver,
            @next_condition                            AS next_condition,
            @next_can_forward                          AS next_can_forward;

    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#approval_stages') IS NOT NULL
            DROP TABLE #approval_stages;

        SELECT
            'ERROR'           AS result,
            ERROR_NUMBER()    AS error_number,
            ERROR_MESSAGE()   AS error_message,
            ERROR_LINE()      AS error_line,
            ERROR_PROCEDURE() AS error_procedure;
    END CATCH

END;
GO
-- undo [F1. views] dbo.vw_PR_Basic_Info
-- restore previous definition
-- ============================================================
-- Non-staff approver-name display fixes
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Why this is needed
-- ------------------
-- Non-staff users (dbo.nt_nonstaff_login) can now be picked as a workflow-
-- stage approver (Approval Workflow admin screen) and are being made
-- selectable in Role Approval (32_nonstaff_role_approval.sql). But every
-- query that resolves an approver/status-by identity to a display name
-- only ever joined dbo.vw_verified_employees, a staff-only view. Two
-- distinct problems found (both confirmed against the LIVE object
-- definitions via OBJECT_DEFINITION(), not guessed):
--
-- 1. vw_PR_Basic_Info's pr_history_data subquery used an INNER JOIN — a PR
--    approval actioned by a non-staff login_id has no matching row in
--    vw_verified_employees, so the INNER JOIN silently drops that entire
--    history entry from the JSON array (not blank — just missing).
--
-- 2. sp_nt_GetQuotationsForApproval's approver name JOIN was ALSO an INNER
--    JOIN (`appr`) — and this one is more than cosmetic: this exact proc
--    is what NonStaffApprovalService.getMyApprovals calls (via
--    POService.getPoRecords) to build a non-staff approver's own "my
--    approvals" list. Because the INNER JOIN sits inside the same
--    subquery already filtered to WHERE sq.approver_ecno = @Ecno, a
--    non-staff person's pending PO/quotation approvals would silently
--    return ZERO rows system-wide — not a display bug, a "can't approve
--    at all via this path" bug. Widened to LEFT JOIN + COALESCE with
--    nt_nonstaff_login, same pattern as (1). Also added the same COALESCE
--    to quotation_history's status_by_name (already LEFT JOIN there, so
--    only the name was missing, not the row).
--
-- 3. sp_nt_ApproveSupplierQuotation's final-approval response resolves
--    @approver_name for the one-time confirmation payload the same way —
--    fixed with the same LEFT JOIN + COALESCE pattern.
--
-- All three bodies below are reproduced byte-for-byte from
-- OBJECT_DEFINITION() (fetched live, not retyped from this repo's older
-- copies) with ONLY the specific JOIN/SELECT lines called out above
-- changed — everything else is untouched.
--
-- created_by_name / pr_created_by_name / quotation_created_by_name (the PR
-- requester and the quotation submitter) are deliberately NOT touched —
-- non-staff users are approvers only, never requesters, so those joins
-- staying staff-only INNER JOINs is correct existing behavior.
-- ============================================================

-- ── vw_PR_Basic_Info: surface category alongside the rest of the header ────
-- Additive-only — every existing consumer gets one new field, nothing removed
-- or renamed. Base definition copied from 06b_vw_pr_basic_info_service_lines.sql.

CREATE OR ALTER VIEW dbo.vw_PR_Basic_Info
AS
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
    vve.ename                   AS created_by_name,
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
    pbf.category,
    pbf.source_invoice_sno,

    -- group number of this split row (NULL when the PR has no items)
    g.grp                       AS [group],

    -- append /group ONLY when the PR is actually split into >1 group
    CASE
       WHEN g.grp IS NOT NULL AND g.group_count > 1
            THEN pbf.pr_no + '/' + CAST(g.grp AS VARCHAR(10))
        ELSE pbf.pr_no
    END                         AS pr_no,

    pbf.workflow_types_id,
    pbf.current_approver_id,
    pbf.status,

    -- PR Item Details as JSON array (only items of THIS group)
    (
        SELECT
            pid.pr_item_sno,
            pid.pr_basic_sno,
            pid.item_type,
            pid.prod_sno,
            pm.prod_name,
            pm.prod_code,
            pm.prod_notes,
            pid.service_sno,
            sm.service_name,
            sm.service_code,
            pid.specification,
            pid.qty,
            pid.unit,
            uom.uom_name,
            uom.uom_code,
            pid.est_cost,
            pid.total_cost,
            pid.remarks,
            pid.created_by,
            pid.created_date,
            pid.modified_by,
            pid.modified_date,
            pid.is_active,
            pid.[group],
            pid.pr_no
        FROM pr_item_details pid
        LEFT JOIN uom_master uom
            ON uom.uom_sno = pid.unit
        LEFT JOIN product_master pm
            ON pid.prod_sno = pm.prod_sno
        LEFT JOIN service_master sm
            ON pid.service_sno = sm.service_sno
        WHERE pid.pr_basic_sno = pbf.pr_basic_sno
          AND pid.is_active = 'Y'
          AND (pid.[group] = g.grp OR (pid.[group] IS NULL AND g.grp IS NULL))
        FOR JSON PATH
    ) AS pr_item_details,

    -- Workflow stage JSON
    (
        SELECT
            ws.stage_order_json
        FROM workflow_stage ws
        WHERE ws.workflow_types_id = pbf.workflow_types_id
          AND ws.is_active = 'Y'
    ) AS stage_order_json,

    (
        SELECT
            phd.status_by, COALESCE(vve.ename, nsl.full_name) AS ename, phd.status_date, phd.commends, phd.pr_edit_data
        FROM pr_history_data phd
        LEFT JOIN vw_verified_employees vve
            ON phd.status_by = vve.ecno
        LEFT JOIN dbo.nt_nonstaff_login nsl
            ON phd.status_by = nsl.login_id
        WHERE phd.pr_basic_sno = pbf.pr_basic_sno
        FOR JSON PATH
    ) AS pr_history_data

FROM pr_basic_info pbf
INNER JOIN workflow_types wt
    ON pbf.workflow_types_id = wt.workflow_types_id
INNER JOIN vw_ActiveDeptRecords vadr
    ON pbf.brn_sno   = vadr.brn_sno
   AND pbf.dept_sno  = vadr.dept_sno
INNER JOIN vw_verified_employees vve
    ON pbf.created_by = vve.ecno
OUTER APPLY (
    -- one row per distinct group in this PR; group_count = number of groups
    SELECT
        pid.[group]      AS grp,
        COUNT(*) OVER () AS group_count
    FROM pr_item_details pid
    WHERE pid.pr_basic_sno = pbf.pr_basic_sno
      AND pid.is_active = 'Y'
    GROUP BY pid.[group]
) g;
GO
-- undo [F1. views] dbo.vw_company_address
-- restore previous definition
  CREATE OR ALTER VIEW vw_company_address AS
SELECT 
    -- Company Master fields
    cm.com_sno AS com_sno ,
    cm.com_name AS com_name,
    cm.com_prefix AS com_prefix,
    cm.is_active AS is_active,
    cm.created_date AS created_date,
    
    -- Address Master fields
     am.add_pan AS add_pan,
    am.is_gst_applicable AS is_gst_applicable,
    am.add_gst AS add_gst,
    am.add_tan AS add_tan,
    am.add_cin AS add_cin,
    am.add_door_no AS add_door_no,
    am.add_street AS add_street,
    am.add_city AS add_city,
    am.add_state AS add_state,
    am.add_state_code AS add_state_code,
    am.add_pin_code AS add_pin_code,
    am.add_reg_door_no AS add_reg_door_no,
    am.add_reg_street AS add_reg_street,
    am.add_reg_city AS add_reg_city,
    am.add_reg_state AS add_reg_state,
    am.add_reg_pincode AS add_reg_pincode
    
FROM [Non_Trade].[dbo].[company_master] cm
LEFT JOIN [Non_Trade].[dbo].[address_master] am 
    ON cm.add_sno = am.add_sno where cm.is_active='Y' ;
GO
-- undo [F1. views] dbo.vw_ActiveDivisions
-- restore previous definition
CREATE OR ALTER VIEW [dbo].[vw_ActiveDivisions]  
AS  
SELECT   
    dm.div_sno AS div_sno,  
    dm.div_name AS div_name,  
dm.div_prefix as div_prefix,  
    dm.div_type AS div_type, 
    cm.com_sno AS com_sno,
    cm.com_name AS com_name,  
    cm.com_prefix AS com_prefix  
FROM [Non_Trade].[dbo].[division_master] dm   
LEFT JOIN [Non_Trade].[dbo].[company_master] cm   
    ON dm.com_sno = cm.com_sno   
WHERE dm.is_active = 'Y';
GO
-- undo [F1. views] dbo.ActiveBranches
-- restore previous definition
CREATE OR ALTER View ActiveBranches  
AS  
SELECT    
  bm.brn_sno,  
  bm.brn_name,  
  bm.brn_prefix,  
  cm.com_name, 
  cm.com_sno,
  cm.com_prefix,  
  dm.div_name,
  dm.div_sno,
  dm.div_prefix,  
  dm.div_type,  
  am.add_door_no,  
  am.add_street,  
  am.add_city,  
  am.add_state,  
  am.add_state_code,  
  am.add_pin_code  
  
  FROM [Non_Trade].[dbo].[branch_master] bm left join [Non_Trade].[dbo].[company_master] cm on  
  bm.com_sno=cm.com_sno left join [Non_Trade].[dbo].[division_master] dm on bm.div_sno =dm.div_sno   
  left join [Non_Trade].[dbo].[address_master] am on bm.add_sno=am.add_sno where bm.is_active='Y'
GO
-- undo [F0. functions] dbo.fn_LoanRateAt  (new)
DROP FUNCTION IF EXISTS [dbo].[fn_LoanRateAt];
GO
-- undo [F0. functions] dbo.fn_LoanPrincipalAt  (new)
DROP FUNCTION IF EXISTS [dbo].[fn_LoanPrincipalAt];
GO
-- undo [F0. functions] dbo.fn_LoanNextDueDate  (new)
DROP FUNCTION IF EXISTS [dbo].[fn_LoanNextDueDate];
GO
-- undo [F0. functions] dbo.fn_LoanLockedThrough  (new)
DROP FUNCTION IF EXISTS [dbo].[fn_LoanLockedThrough];
GO
-- undo [F0. functions] dbo.fn_LoanInterestSegments  (new)
DROP FUNCTION IF EXISTS [dbo].[fn_LoanInterestSegments];
GO
-- undo [F0. functions] dbo.fn_LoanBilledThrough  (new)
DROP FUNCTION IF EXISTS [dbo].[fn_LoanBilledThrough];
GO
-- undo [E. foreign keys (new tables)] dbo.service_po_cycle.FK_service_po_cycle_po
ALTER TABLE [dbo].[service_po_cycle] DROP CONSTRAINT IF EXISTS [FK_service_po_cycle_po];
GO
-- undo [E. foreign keys (new tables)] dbo.service_po_cycle_vendor.FK_service_po_cycle_vendor_po
ALTER TABLE [dbo].[service_po_cycle_vendor] DROP CONSTRAINT IF EXISTS [FK_service_po_cycle_vendor_po];
GO
-- undo [E. foreign keys (new tables)] dbo.service_po_cycle_history.FK_service_po_cycle_history_cycle
ALTER TABLE [dbo].[service_po_cycle_history] DROP CONSTRAINT IF EXISTS [FK_service_po_cycle_history_cycle];
GO
-- undo [E. foreign keys (new tables)] dbo.service_po_cycle_vendor.FK_service_po_cycle_vendor_cycle
ALTER TABLE [dbo].[service_po_cycle_vendor] DROP CONSTRAINT IF EXISTS [FK_service_po_cycle_vendor_cycle];
GO
-- undo [E. foreign keys (new tables)] dbo.loan_principal_txn.FK_loan_principal_txn_voucher
ALTER TABLE [dbo].[loan_principal_txn] DROP CONSTRAINT IF EXISTS [FK_loan_principal_txn_voucher];
GO
-- undo [E. foreign keys (new tables)] dbo.bank_payment_voucher_history.FK_bank_payment_voucher_history_voucher
ALTER TABLE [dbo].[bank_payment_voucher_history] DROP CONSTRAINT IF EXISTS [FK_bank_payment_voucher_history_voucher];
GO
-- undo [E. foreign keys (new tables)] dbo.nt_stock_batches.FK_nt_stock_batches_item
ALTER TABLE [dbo].[nt_stock_batches] DROP CONSTRAINT IF EXISTS [FK_nt_stock_batches_item];
GO
-- undo [E. foreign keys (new tables)] dbo.service_po_cycle.FK_service_po_cycle_agreement
ALTER TABLE [dbo].[service_po_cycle] DROP CONSTRAINT IF EXISTS [FK_service_po_cycle_agreement];
GO
-- undo [E. foreign keys (new tables)] dbo.bank_payment_voucher.FK_bank_payment_voucher_agreement
ALTER TABLE [dbo].[bank_payment_voucher] DROP CONSTRAINT IF EXISTS [FK_bank_payment_voucher_agreement];
GO
-- undo [E. foreign keys (new tables)] dbo.loan_principal_txn.FK_loan_principal_txn_agreement
ALTER TABLE [dbo].[loan_principal_txn] DROP CONSTRAINT IF EXISTS [FK_loan_principal_txn_agreement];
GO
-- undo [E. foreign keys (new tables)] dbo.service_agreement_version.FK_service_agreement_version_agreement
ALTER TABLE [dbo].[service_agreement_version] DROP CONSTRAINT IF EXISTS [FK_service_agreement_version_agreement];
GO
-- undo [E. foreign keys (new tables)] dbo.loan_rate_period.FK_loan_rate_period_agreement
ALTER TABLE [dbo].[loan_rate_period] DROP CONSTRAINT IF EXISTS [FK_loan_rate_period_agreement];
GO
-- undo [E. foreign keys (new tables)] dbo.service_agreement_statutory.FK_service_agreement_statutory_agreement
ALTER TABLE [dbo].[service_agreement_statutory] DROP CONSTRAINT IF EXISTS [FK_service_agreement_statutory_agreement];
GO
-- undo [E. foreign keys (new tables)] dbo.service_agreement_vendor.FK_service_agreement_vendor_agreement
ALTER TABLE [dbo].[service_agreement_vendor] DROP CONSTRAINT IF EXISTS [FK_service_agreement_vendor_agreement];
GO
-- undo [E. foreign keys] dbo.nt_stock_movements.FK_nt_stock_movements_batch
ALTER TABLE [dbo].[nt_stock_movements] DROP CONSTRAINT IF EXISTS [FK_nt_stock_movements_batch];
GO
-- undo [E. foreign keys] dbo.service_agreement.FK_service_agreement_cadence
ALTER TABLE [dbo].[service_agreement] DROP CONSTRAINT IF EXISTS [FK_service_agreement_cadence];
GO
-- undo [E. checks] dbo.subcategory_master.CK_subcategory_master_perishable_days
ALTER TABLE [dbo].[subcategory_master] DROP CONSTRAINT IF EXISTS [CK_subcategory_master_perishable_days];
GO
-- undo [E. checks] dbo.service_agreement.CK_service_agreement_rate
ALTER TABLE [dbo].[service_agreement] DROP CONSTRAINT IF EXISTS [CK_service_agreement_rate];
GO
-- undo [E. checks] dbo.service_agreement.CK_service_agreement_qty
ALTER TABLE [dbo].[service_agreement] DROP CONSTRAINT IF EXISTS [CK_service_agreement_qty];
GO
-- undo [E. indexes] dbo.nt_user_permissions_json.UX_nt_user_permissions_json_staff_user
DROP INDEX IF EXISTS [UX_nt_user_permissions_json_staff_user] ON [dbo].[nt_user_permissions_json];
GO
-- undo [E. indexes] dbo.pr_basic_info.IX_pr_basic_info_vendor_mode
DROP INDEX IF EXISTS [IX_pr_basic_info_vendor_mode] ON [dbo].[pr_basic_info];
GO
-- undo [D2. relax legacy columns] dbo.service_agreement.recurrence_cadence
ALTER TABLE [dbo].[service_agreement] ALTER COLUMN [recurrence_cadence] varchar(20) NOT NULL;
GO
-- undo [D. alter columns] dbo.service_agreement_history.comment
ALTER TABLE [dbo].[service_agreement_history] ALTER COLUMN [comment] varchar(200) NULL;
GO
-- undo [D. alter columns] dbo.service_agreement.status
ALTER TABLE [dbo].[service_agreement] DROP CONSTRAINT [DF__service_a__statu__1C281490];
ALTER TABLE [dbo].[service_agreement] ALTER COLUMN [status] char(1) NOT NULL;
GO
-- undo [D. alter columns] dbo.service_agreement.notify_days_before
ALTER TABLE [dbo].[service_agreement] DROP CONSTRAINT [DF__service_a__notif__1B33F057];
ALTER TABLE [dbo].[service_agreement] ALTER COLUMN [notify_days_before] smallint NULL;
GO
-- undo [D. alter columns] dbo.service_agreement.recurrence_cadence_sno
ALTER TABLE [dbo].[service_agreement] ALTER COLUMN [recurrence_cadence_sno] int NULL;
GO
-- undo [D. alter columns] dbo.service_agreement.rate_amount
ALTER TABLE [dbo].[service_agreement] ALTER COLUMN [rate_amount] decimal(18,2) NULL;
GO
-- undo [D. alter columns] dbo.service_agreement.vendor_sno
ALTER TABLE [dbo].[service_agreement] ALTER COLUMN [vendor_sno] int NULL;
GO
-- undo [C. add columns] dbo.subcategory_master.perishable_days
ALTER TABLE [dbo].[subcategory_master] DROP COLUMN [perishable_days];  -- loses whatever was written to this column since the sync
GO
-- undo [C. add columns] dbo.service_agreement_history.version_no
ALTER TABLE [dbo].[service_agreement_history] DROP COLUMN [version_no];  -- loses whatever was written to this column since the sync
GO
-- undo [C. add columns] dbo.service_agreement_history.created_at
ALTER TABLE [dbo].[service_agreement_history] DROP CONSTRAINT [DF__service_a__creat__29820FAE];
ALTER TABLE [dbo].[service_agreement_history] DROP COLUMN [created_at];  -- loses whatever was written to this column since the sync
GO
-- undo [C. add columns] dbo.service_agreement.terms_conditions
ALTER TABLE [dbo].[service_agreement] DROP COLUMN [terms_conditions];  -- loses whatever was written to this column since the sync
GO
-- undo [C. add columns] dbo.service_agreement.qty
ALTER TABLE [dbo].[service_agreement] DROP CONSTRAINT [DF__service_agr__qty__1A3FCC1E];
ALTER TABLE [dbo].[service_agreement] DROP COLUMN [qty];  -- loses whatever was written to this column since the sync
GO
-- undo [C. add columns] dbo.product_master.prod_uom_con_uom_sno
ALTER TABLE [dbo].[product_master] DROP COLUMN [prod_uom_con_uom_sno];  -- loses whatever was written to this column since the sync
GO
-- undo [C. add columns] dbo.pr_item_details.gst_amount
ALTER TABLE [dbo].[pr_item_details] DROP COLUMN [gst_amount];  -- loses whatever was written to this column since the sync
GO
-- undo [C. add columns] dbo.pr_item_details.taxable_amount
ALTER TABLE [dbo].[pr_item_details] DROP COLUMN [taxable_amount];  -- loses whatever was written to this column since the sync
GO
-- undo [C. add columns] dbo.pr_item_details.discount_pct
ALTER TABLE [dbo].[pr_item_details] DROP COLUMN [discount_pct];  -- loses whatever was written to this column since the sync
GO
-- undo [C. add columns] dbo.pr_item_details.gst_pct
ALTER TABLE [dbo].[pr_item_details] DROP COLUMN [gst_pct];  -- loses whatever was written to this column since the sync
GO
-- undo [C. add columns] dbo.pr_item_details.item_rate
ALTER TABLE [dbo].[pr_item_details] DROP COLUMN [item_rate];  -- loses whatever was written to this column since the sync
GO
-- undo [C. add columns] dbo.pr_item_details.item_description
ALTER TABLE [dbo].[pr_item_details] DROP COLUMN [item_description];  -- loses whatever was written to this column since the sync
GO
-- undo [C. add columns] dbo.pr_basic_info.payment_cycle_days
ALTER TABLE [dbo].[pr_basic_info] DROP COLUMN [payment_cycle_days];  -- loses whatever was written to this column since the sync
GO
-- undo [C. add columns] dbo.pr_basic_info.vendor_sno
ALTER TABLE [dbo].[pr_basic_info] DROP COLUMN [vendor_sno];  -- loses whatever was written to this column since the sync
GO
-- undo [C. add columns] dbo.pr_basic_info.request_mode
ALTER TABLE [dbo].[pr_basic_info] DROP CONSTRAINT [DF_pr_basic_info_request_mode];
ALTER TABLE [dbo].[pr_basic_info] DROP COLUMN [request_mode];  -- loses whatever was written to this column since the sync
GO
-- undo [C. add columns] dbo.nt_stock_movements.batch_sno
ALTER TABLE [dbo].[nt_stock_movements] DROP COLUMN [batch_sno];  -- loses whatever was written to this column since the sync
GO
-- undo [C. add columns] dbo.kyc_address_info.state_code
ALTER TABLE [dbo].[kyc_address_info] DROP COLUMN [state_code];  -- loses whatever was written to this column since the sync
GO
-- undo [B. sequences] seq_nonstaff_login_id
DROP SEQUENCE IF EXISTS [dbo].[seq_nonstaff_login_id];
GO
-- undo [A. create tables] dbo.service_po_cycle_history
DROP TABLE IF EXISTS [dbo].[service_po_cycle_history];  -- only safe while the table is still empty
GO
-- undo [A. create tables] dbo.service_po_cycle
DROP TABLE IF EXISTS [dbo].[service_po_cycle];  -- only safe while the table is still empty
GO
-- undo [A. create tables] dbo.nt_stock_batches
DROP TABLE IF EXISTS [dbo].[nt_stock_batches];  -- only safe while the table is still empty
GO
-- undo [A. create tables] dbo.product_stock_level_master
DROP TABLE IF EXISTS [dbo].[product_stock_level_master];  -- only safe while the table is still empty
GO
-- undo [A. create tables] dbo.pr_vendor_driven_item_details
DROP TABLE IF EXISTS [dbo].[pr_vendor_driven_item_details];  -- only safe while the table is still empty
GO
-- undo [A. create tables] dbo.pr_vendor_driven_info
DROP TABLE IF EXISTS [dbo].[pr_vendor_driven_info];  -- only safe while the table is still empty
GO
-- undo [A. create tables] dbo.bank_payment_voucher_history
DROP TABLE IF EXISTS [dbo].[bank_payment_voucher_history];  -- only safe while the table is still empty
GO
-- undo [A. create tables] dbo.bank_payment_voucher
DROP TABLE IF EXISTS [dbo].[bank_payment_voucher];  -- only safe while the table is still empty
GO
-- undo [A. create tables] dbo.service_po_cycle_vendor
DROP TABLE IF EXISTS [dbo].[service_po_cycle_vendor];  -- only safe while the table is still empty
GO
-- undo [A. create tables] dbo.loan_principal_txn
DROP TABLE IF EXISTS [dbo].[loan_principal_txn];  -- only safe while the table is still empty
GO
-- undo [A. create tables] dbo.loan_rate_period
DROP TABLE IF EXISTS [dbo].[loan_rate_period];  -- only safe while the table is still empty
GO
-- undo [A. create tables] dbo.service_agreement_version
DROP TABLE IF EXISTS [dbo].[service_agreement_version];  -- only safe while the table is still empty
GO
-- undo [A. create tables] dbo.service_agreement_statutory
DROP TABLE IF EXISTS [dbo].[service_agreement_statutory];  -- only safe while the table is still empty
GO
-- undo [A. create tables] dbo.service_agreement_vendor
DROP TABLE IF EXISTS [dbo].[service_agreement_vendor];  -- only safe while the table is still empty
GO