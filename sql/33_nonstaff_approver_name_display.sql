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
                        pid2.est_cost   AS pr_est_cost,
                        pid2.total_cost AS pr_total_cost,
                        pid2.qty        AS pr_qty
                    FROM supplier_quotation_items sid
                    INNER JOIN product_master pm2  ON pm2.prod_sno  = sid.prod_sno
                    INNER JOIN uom_master uom2     ON uom2.uom_sno  = sid.unit
              INNER  JOIN pr_item_details pid2 ON pid2.pr_item_sno = sid.pr_item_sno
                    WHERE
                    --sid.sq_basic_sno = sq.sq_basic_sno AND
                       sid.is_active = 1    AND
                      pr_no= pg.split_pr_no
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

-- ============================================================
-- After running, confirm:
--   SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.vw_PR_Basic_Info'));
--   SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.sp_nt_ApproveSupplierQuotation'));
--   SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.sp_nt_GetQuotationsForApproval'));
-- each should show the LEFT JOIN + COALESCE changes described above.
--
-- Manual smoke test: have a non-staff login_id be the approver_ecno on a
-- pending quotation/PO stage, then call sp_nt_GetQuotationsForApproval
-- with that login_id as @Ecno — the quotation should now appear (it would
-- have returned zero rows before this fix) with approver_name populated.
-- ============================================================
