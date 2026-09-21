-- ============================================================
-- Vendor-driven PR: dedicated extension tables
-- Database: Non_trade_Dev (MSSQL)
--
-- Moves vendor-driven-only PR data (vendor_sno, payment_cycle_days on the
-- header; item_rate, gst_pct, discount_pct, taxable_amount, gst_amount per
-- line) into two new extension tables keyed 1:1 to pr_basic_info/
-- pr_item_details, instead of living as nullable columns on those shared
-- tables. request_mode stays on pr_basic_info — it's the shared flow
-- discriminator every approval/tracking proc already keys on, not
-- vendor-driven-only data.
--
-- Deliberately NOT a full separate header table: po_request_info.pr_basic_sno,
-- sp_approve_pr_datas, and the PR-tracking procs (sp_nt_GetPRTrackingTimeline,
-- sp_nt_GetMyPRTracking, sp_nt_GetOrgPRTracking, sp_nt_GetPrNoByPoBasicSno)
-- all assume every PR row lives in pr_basic_info. Keeping one pr_basic_info/
-- pr_item_details row per vendor-driven PR means none of those need to
-- change — only the procs that actually read vendor_sno/rate/gst/discount
-- directly (rewritten below, plus grn-service/sql/29_...) do.
--
-- The old columns (pr_basic_info.vendor_sno/payment_cycle_days,
-- pr_item_details.item_rate/gst_pct/discount_pct/taxable_amount/gst_amount)
-- are left in place, not dropped, and usp_InsertVendorDrivenPurchaseRequest
-- keeps writing them too (dual-write) — non-destructive and gives a live
-- fallback if something is later found still reading the old columns
-- directly. Every read path below now sources from the new tables.
-- ============================================================

IF OBJECT_ID('dbo.pr_vendor_driven_info', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.pr_vendor_driven_info (
        pr_vd_info_sno INT IDENTITY(1,1) PRIMARY KEY,
        pr_basic_sno INT NOT NULL,
        vendor_sno INT NOT NULL,
        payment_cycle_days INT NOT NULL DEFAULT 15,
        created_by VARCHAR(20) NULL,
        created_date DATETIME NULL,
        CONSTRAINT UQ_pr_vendor_driven_info_pr_basic_sno UNIQUE (pr_basic_sno)
    );
END
GO

IF OBJECT_ID('dbo.pr_vendor_driven_item_details', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.pr_vendor_driven_item_details (
        pr_vd_item_sno INT IDENTITY(1,1) PRIMARY KEY,
        pr_item_sno INT NOT NULL,
        item_rate DECIMAL(18,4) NOT NULL,
        gst_pct DECIMAL(5,2) NOT NULL DEFAULT 0,
        discount_pct DECIMAL(5,2) NOT NULL DEFAULT 0,
        taxable_amount DECIMAL(18,2) NOT NULL,
        gst_amount DECIMAL(18,2) NOT NULL,
        CONSTRAINT UQ_pr_vendor_driven_item_details_pr_item_sno UNIQUE (pr_item_sno)
    );
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.pr_vendor_driven_info') AND name = 'IX_pr_vendor_driven_info_vendor'
)
    CREATE INDEX IX_pr_vendor_driven_info_vendor
        ON dbo.pr_vendor_driven_info (vendor_sno, pr_basic_sno);
GO

-- One-time backfill for vendor-driven PR rows already written against the
-- shared columns before this migration existed. Re-runnable: skips rows
-- that already have an extension row.
INSERT INTO dbo.pr_vendor_driven_info (pr_basic_sno, vendor_sno, payment_cycle_days, created_by, created_date)
SELECT pb.pr_basic_sno, pb.vendor_sno, ISNULL(pb.payment_cycle_days, 15), pb.created_by, pb.created_date
FROM dbo.pr_basic_info pb
WHERE pb.request_mode = 'VENDOR_DRIVEN'
  AND pb.vendor_sno IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.pr_vendor_driven_info x WHERE x.pr_basic_sno = pb.pr_basic_sno);
GO

INSERT INTO dbo.pr_vendor_driven_item_details (pr_item_sno, item_rate, gst_pct, discount_pct, taxable_amount, gst_amount)
SELECT pid.pr_item_sno, pid.item_rate, ISNULL(pid.gst_pct, 0), ISNULL(pid.discount_pct, 0),
       ISNULL(pid.taxable_amount, pid.item_rate * pid.qty), ISNULL(pid.gst_amount, 0)
FROM dbo.pr_item_details pid
INNER JOIN dbo.pr_basic_info pb ON pb.pr_basic_sno = pid.pr_basic_sno
WHERE pb.request_mode = 'VENDOR_DRIVEN'
  AND pid.item_rate IS NOT NULL
  AND pid.is_active = 'Y'
  AND NOT EXISTS (SELECT 1 FROM dbo.pr_vendor_driven_item_details x WHERE x.pr_item_sno = pid.pr_item_sno);
GO

-- ============================================================
-- usp_InsertVendorDrivenPurchaseRequest — unchanged pr_basic_info/
-- pr_item_details inserts (dual-write, see header), plus new extension-
-- table inserts sourced from the pr_item_details rows just written via
-- an OUTPUT clause (captures the generated pr_item_sno per row).
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_InsertVendorDrivenPurchaseRequest
    @jsonInput NVARCHAR(MAX),
    @pr_no VARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @com_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.com_sno') AS INT),
        @div_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.div_sno') AS INT),
        @brn_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.brn_sno') AS INT),
        @dept_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.dept_sno') AS INT),
        @reg_date DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.req_date') AS DATE),
        @required_date DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.required_date') AS DATE),
        @priority_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.priority_sno') AS INT),
        @purpose NVARCHAR(500) = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.purpose'), ''),
        @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.vendor_sno') AS INT),
        @payment_cycle_days INT = COALESCE(TRY_CAST(JSON_VALUE(@jsonInput, '$.basicInfo.payment_cycle_days') AS INT), 15),
        @created_by VARCHAR(20) = NULLIF(JSON_VALUE(@jsonInput, '$.basicInfo.created_by'), ''),
        @items NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items'),
        @workflow_types_id INT,
        @workflow_id INT,
        @first_approver VARCHAR(20),
        @pr_basic_sno INT,
        @financial_year VARCHAR(10),
        @sequence_number INT,
        @items_inserted INT;

    DECLARE @insertedItems TABLE (
        pr_item_sno INT,
        item_rate DECIMAL(18,4),
        gst_pct DECIMAL(5,2),
        discount_pct DECIMAL(5,2),
        taxable_amount DECIMAL(18,2),
        gst_amount DECIMAL(18,2)
    );

    IF ISJSON(@jsonInput) <> 1
        THROW 59001, 'Invalid vendor-driven requisition payload.', 1;

    IF @com_sno IS NULL OR @div_sno IS NULL OR @brn_sno IS NULL OR @dept_sno IS NULL
       OR @reg_date IS NULL OR @required_date IS NULL OR @priority_sno IS NULL
       OR @vendor_sno IS NULL OR @created_by IS NULL
        THROW 59002, 'Company, division, branch, department, dates, priority, supplier and creator are required.', 1;

    IF @payment_cycle_days < 1 OR @payment_cycle_days > 365
        THROW 59003, 'payment_cycle_days must be between 1 and 365.', 1;

    IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
        THROW 59004, 'At least one vendor-driven item is required.', 1;

    IF EXISTS (
        SELECT 1
        FROM OPENJSON(@items)
        WHERE TRY_CAST(JSON_VALUE(value, '$.prod_sno') AS INT) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.unit_sno') AS INT) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)) <= 0
           OR TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)) IS NULL
           OR TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)) < 0
           OR NULLIF(JSON_VALUE(value, '$.item_attachment'), '') IS NULL
           OR (
                JSON_VALUE(value, '$.discount_pct') IS NOT NULL
                AND (
                    TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)) IS NULL
                    OR TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)) < 0
                    OR TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)) > 100
                )
           )
    )
        THROW 59005, 'Every vendor-driven item requires product, unit, positive quantity, rate, a verification document, and (if present) a discount_pct between 0 and 100.', 1;

    SELECT
        @workflow_id = wt.workflow_id,
        @workflow_types_id = wt.workflow_types_id
    FROM dbo.workflow_types wt
    INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
    WHERE wt.com_sno = @com_sno
      AND wt.div_sno = @div_sno
      AND wt.brn_sno = @brn_sno
      AND wt.dept_sno = @dept_sno
      AND awm.entity_type = 'VendorDrivenPurchaseRequisition';

    IF @workflow_types_id IS NULL
        THROW 59006, 'No VendorDrivenPurchaseRequisition workflow is configured for this organisation scope.', 1;

    SELECT @first_approver = JSON_VALUE(stage_member.value, '$.approver_ecno')
    FROM dbo.vw_workflow_stages ws
    CROSS APPLY OPENJSON(ws.stages_json) stage_group
    CROSS APPLY OPENJSON(JSON_VALUE(stage_group.value, '$.stage_order_json')) stage_member
    WHERE ws.workflow_types_id = @workflow_types_id
      AND stage_group.[key] = '0'
      AND stage_member.[key] = '0';

    IF @first_approver IS NULL
        THROW 59007, 'The VendorDrivenPurchaseRequisition workflow has no first approver.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        SET @financial_year = dbo.fn_GetFinancialYear(GETDATE());

        SELECT @sequence_number = ISNULL(MAX(TRY_CAST(RIGHT(pr_no, 4) AS INT)), 0) + 1
        FROM dbo.pr_basic_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_no LIKE 'VPR' + @financial_year + '-%';

        SET @pr_no = 'VPR' + @financial_year + '-' + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);

        INSERT INTO dbo.pr_basic_info (
            pr_no, com_sno, div_sno, brn_sno, dept_sno, reg_date, required_date,
            priority_sno, purpose, request_mode, vendor_sno, payment_cycle_days,
            is_active, created_by, created_date, workflow_types_id, current_approver_id, status
        )
        VALUES (
            @pr_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @reg_date, @required_date,
            @priority_sno, @purpose, 'VENDOR_DRIVEN', @vendor_sno, @payment_cycle_days,
            'Y', @created_by, GETDATE(), @workflow_types_id, @first_approver, 'P'
        );

        SET @pr_basic_sno = SCOPE_IDENTITY();

        INSERT INTO dbo.pr_item_details (
            pr_no, pr_basic_sno, prod_sno, qty, unit, est_cost, total_cost,
            remarks, specification, pr_prod_file, item_type, is_active,
            created_by, created_date, item_description, item_rate, gst_pct,
            discount_pct, taxable_amount, gst_amount
        )
        OUTPUT inserted.pr_item_sno, inserted.item_rate, inserted.gst_pct,
               inserted.discount_pct, inserted.taxable_amount, inserted.gst_amount
        INTO @insertedItems
        SELECT
            @pr_no,
            @pr_basic_sno,
            TRY_CAST(JSON_VALUE(value, '$.prod_sno') AS INT),
            TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4)),
            TRY_CAST(JSON_VALUE(value, '$.unit_sno') AS INT),
            TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
            t.taxable_amount + g2.gst_amount,
            NULLIF(JSON_VALUE(value, '$.remarks'), ''),
            NULLIF(JSON_VALUE(value, '$.specification'), ''),
            NULLIF(JSON_VALUE(value, '$.item_attachment'), ''),
            'vendor_driven',
            'Y',
            @created_by,
            GETDATE(),
            NULLIF(JSON_VALUE(value, '$.prod_name'), ''),
            TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
            base.gst_pct_val,
            base.disc_pct,
            t.taxable_amount,
            g2.gst_amount
        FROM OPENJSON(@items)
        CROSS APPLY (
            SELECT
                gross       = TRY_CAST(JSON_VALUE(value, '$.qty') AS DECIMAL(18,4))
                            * TRY_CAST(JSON_VALUE(value, '$.rate') AS DECIMAL(18,4)),
                disc_pct    = COALESCE(TRY_CAST(JSON_VALUE(value, '$.discount_pct') AS DECIMAL(5,2)), 0),
                gst_pct_val = COALESCE(TRY_CAST(JSON_VALUE(value, '$.gst_pct') AS DECIMAL(5,2)), 0)
        ) base
        CROSS APPLY (
            SELECT taxable_amount = ROUND(base.gross * (1 - base.disc_pct / 100), 2)
        ) t
        CROSS APPLY (
            SELECT gst_amount = ROUND(t.taxable_amount * base.gst_pct_val / 100, 2)
        ) g2;

        SET @items_inserted = @@ROWCOUNT;
        IF @items_inserted = 0
            THROW 59008, 'No vendor-driven items were inserted.', 1;

        INSERT INTO dbo.pr_vendor_driven_info (pr_basic_sno, vendor_sno, payment_cycle_days, created_by, created_date)
        VALUES (@pr_basic_sno, @vendor_sno, @payment_cycle_days, @created_by, GETDATE());

        INSERT INTO dbo.pr_vendor_driven_item_details (pr_item_sno, item_rate, gst_pct, discount_pct, taxable_amount, gst_amount)
        SELECT pr_item_sno, item_rate, gst_pct, discount_pct, taxable_amount, gst_amount
        FROM @insertedItems;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT
        @pr_basic_sno AS pr_basic_sno,
        @pr_no AS pr_no,
        @items_inserted AS items_inserted,
        'SUCCESS' AS result;
END;
GO

-- ============================================================
-- sp_nt_GetVendorDrivenApprovedPRs — now sources vendor/rate/gst/discount
-- from the extension tables instead of pr_basic_info/pr_item_details
-- directly. Same output shape as before.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetVendorDrivenApprovedPRs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.pr_basic_sno,
        p.pr_no,
        p.com_sno,
        c.com_name,
        p.div_sno,
        dv.div_name,
        p.brn_sno,
        br.brn_name,
        p.dept_sno,
        dp.dept_name,
        CONVERT(VARCHAR(10), p.reg_date, 120) AS reg_date,
        CONVERT(VARCHAR(10), p.required_date, 120) AS required_date,
        p.priority_sno,
        pm.priority_name,
        p.purpose,
        p.request_mode,
        pvd.vendor_sno,
        k.company_name AS vendor_name,
        pvd.payment_cycle_days,
        p.created_by,
        p.created_date,
        p.status,
        (
            SELECT
                pid.pr_item_sno,
                pid.prod_sno,
                COALESCE(pid.item_description, product.prod_name) AS prod_name,
                pid.qty,
                pid.unit,
                uom.uom_name AS unit_name,
                pvid.item_rate AS rate,
                pvid.gst_pct,
                pvid.discount_pct,
                pvid.taxable_amount,
                pvid.gst_amount,
                pid.total_cost,
                pid.remarks,
                pid.pr_prod_file AS item_attachment
            FROM dbo.pr_item_details pid
            INNER JOIN dbo.pr_vendor_driven_item_details pvid ON pvid.pr_item_sno = pid.pr_item_sno
            LEFT JOIN dbo.product_master product ON product.prod_sno = pid.prod_sno
            LEFT JOIN dbo.uom_master uom ON uom.uom_sno = pid.unit
            WHERE pid.pr_basic_sno = p.pr_basic_sno
              AND pid.is_active = 'Y'
            FOR JSON PATH
        ) AS pr_item_details
    FROM dbo.pr_basic_info p
    INNER JOIN dbo.pr_vendor_driven_info pvd ON pvd.pr_basic_sno = p.pr_basic_sno
    LEFT JOIN dbo.company_master c ON c.com_sno = p.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = p.div_sno
    LEFT JOIN dbo.branch_master br ON br.brn_sno = p.brn_sno
    LEFT JOIN dbo.dept_master dp ON dp.dept_sno = p.dept_sno
    LEFT JOIN dbo.priority_master pm ON pm.priority_sno = p.priority_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = pvd.vendor_sno
    WHERE p.is_active = 'Y'
      AND p.request_mode = 'VENDOR_DRIVEN'
      AND p.status = 'A'
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.po_request_info po
          WHERE po.pr_basic_sno = p.pr_basic_sno
            AND po.is_active = 'Y'
      )
    ORDER BY p.pr_basic_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_CreateVendorDrivenPOFromPR — sources vendor/rate/gst/discount from
-- the extension tables when building the PO. Its final SELECT is extended
-- (was just po_basic_sno/po_no/result) to also return the vendor's contact
-- info, dates, and a FOR JSON PATH item array, so the Node approval path
-- can auto-email the PO to the vendor in one round trip after final
-- approval (see PR.controller.js#approvePr and PRApprovalScreen.tsx).
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateVendorDrivenPOFromPR
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @pr_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT),
        @created_by VARCHAR(20) = NULLIF(JSON_VALUE(@jsonInput, '$.created_by'), ''),
        @vendor_sno INT,
        @com_sno INT,
        @div_sno INT,
        @brn_sno INT,
        @dept_sno INT,
        @required_date DATE,
        @purpose NVARCHAR(500),
        @workflow_types_id INT,
        @po_basic_sno INT,
        @po_no VARCHAR(50),
        @sequence_number INT;

    IF @pr_basic_sno IS NULL OR @created_by IS NULL
        THROW 59020, 'pr_basic_sno and created_by are required.', 1;

    SELECT
        @vendor_sno = pvd.vendor_sno,
        @com_sno = p.com_sno,
        @div_sno = p.div_sno,
        @brn_sno = p.brn_sno,
        @dept_sno = p.dept_sno,
        @required_date = p.required_date,
        @purpose = p.purpose,
        @workflow_types_id = p.workflow_types_id
    FROM dbo.pr_basic_info p WITH (UPDLOCK, HOLDLOCK)
    INNER JOIN dbo.pr_vendor_driven_info pvd ON pvd.pr_basic_sno = p.pr_basic_sno
    WHERE p.pr_basic_sno = @pr_basic_sno
      AND p.request_mode = 'VENDOR_DRIVEN'
      AND p.status = 'A'
      AND p.is_active = 'Y';

    IF @vendor_sno IS NULL
        THROW 59021, 'Vendor-driven PR not found or not finally approved.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        SELECT @po_basic_sno = po_basic_sno, @po_no = po_df_no
        FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
        WHERE pr_basic_sno = @pr_basic_sno
          AND vendor_sno = @vendor_sno
          AND is_active = 'Y';

        IF @po_basic_sno IS NULL
        BEGIN
            SELECT @sequence_number = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
            FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
            WHERE po_df_no LIKE 'VPO-' + CAST(YEAR(GETDATE()) AS VARCHAR(4)) + '-%';

            SET @po_no = 'VPO-' + CAST(YEAR(GETDATE()) AS VARCHAR(4)) + '-'
                + RIGHT('0000' + CAST(@sequence_number AS VARCHAR(4)), 4);

            INSERT INTO dbo.po_request_info (
                vendor_sno, brn_sno, dept_sno, com_sno, div_sno, pr_basic_sno,
                po_date, required_date, purpose, is_active, workflow_types_id,
                current_approver_id, status, po_df_no
            )
            VALUES (
                @vendor_sno, @brn_sno, @dept_sno, @com_sno, @div_sno, @pr_basic_sno,
                CAST(GETDATE() AS DATE), @required_date, @purpose, 'Y', @workflow_types_id,
                NULL, 'A', @po_no
            );

            SET @po_basic_sno = SCOPE_IDENTITY();

            INSERT INTO dbo.po_item_details (
                po_basic_sno, pr_item_sno, prod_sno, prod_name, specification,
                qty, unit, unit_name, agreed_unit_price, total_cost, discount_pct,
                tax_pct, net_cost, remarks, po_section, created_by, created_date, is_active
            )
            SELECT
                @po_basic_sno,
                pid.pr_item_sno,
                pid.prod_sno,
                COALESCE(pid.item_description, product.prod_name),
                pid.specification,
                pid.qty,
                pid.unit,
                uom.uom_name,
                pvid.item_rate,
                pvid.taxable_amount,
                pvid.discount_pct,
                pvid.gst_pct,
                pid.total_cost,
                pid.remarks,
                'MATERIAL',
                @created_by,
                GETDATE(),
                '1'
            FROM dbo.pr_item_details pid
            INNER JOIN dbo.pr_vendor_driven_item_details pvid ON pvid.pr_item_sno = pid.pr_item_sno
            LEFT JOIN dbo.product_master product ON product.prod_sno = pid.prod_sno
            LEFT JOIN dbo.uom_master uom ON uom.uom_sno = pid.unit
            WHERE pid.pr_basic_sno = @pr_basic_sno
              AND pid.is_active = 'Y';

            IF @@ROWCOUNT = 0
                THROW 59022, 'Vendor-driven PR has no active item lines.', 1;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT
        @po_basic_sno AS po_basic_sno,
        @po_no AS po_no,
        'SUCCESS' AS result,
        CONVERT(VARCHAR(10), po.po_date, 120) AS po_date,
        CONVERT(VARCHAR(10), po.required_date, 120) AS required_date,
        po.purpose,
        po.vendor_sno,
        k.company_name,
        k.email,
        (
            SELECT
                poi.prod_name,
                poi.qty,
                poi.unit_name,
                poi.agreed_unit_price AS rate,
                poi.discount_pct,
                poi.tax_pct AS gst_pct,
                poi.net_cost AS total_amount
            FROM dbo.po_item_details poi
            WHERE poi.po_basic_sno = @po_basic_sno
              AND poi.is_active = '1'
            FOR JSON PATH
        ) AS items
    FROM dbo.po_request_info po
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = po.vendor_sno
    WHERE po.po_basic_sno = @po_basic_sno;
END;
GO

-- ============================================================
-- vw_PR_Basic_Info — the approval-queue view every approver's screen reads
-- (via sp_get_pr_details_for_approval). Reproduced from the live
-- OBJECT_DEFINITION() with ONLY the vendor-driven fields re-sourced from
-- the new extension tables via LEFT JOIN, so normal PRs keep returning
-- NULL for them exactly as before and nothing else changes.
-- ============================================================
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

    -- Vendor-Driven fields (additive) — NULL/'NORMAL' for every ordinary PR.
    pbf.request_mode,
    pvd.vendor_sno,
    vk.company_name              AS vendor_name,
    pvd.payment_cycle_days,

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
            pid.pr_no,
            pvid.item_rate                AS rate,
            pvid.gst_pct,
            pvid.discount_pct,
            pvid.taxable_amount,
            pvid.gst_amount,
            pid.pr_prod_file              AS item_attachment
        FROM pr_item_details pid
        LEFT JOIN dbo.pr_vendor_driven_item_details pvid
            ON pvid.pr_item_sno = pid.pr_item_sno
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
LEFT JOIN dbo.pr_vendor_driven_info pvd
    ON pvd.pr_basic_sno = pbf.pr_basic_sno
LEFT JOIN dbo.kyc_basic_info vk
    ON vk.kyc_basic_info_sno = pvd.vendor_sno
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
