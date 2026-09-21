-- ============================================================
-- vw_PR_Basic_Info: surface vendor-driven fields
-- Database: Non_trade_Dev (MSSQL)
--
-- sp_get_pr_details_for_approval (the PR approval queue every approver's
-- screen calls) does `SELECT vw.* FROM vw_PR_Basic_Info vw ...` — so a
-- Vendor-Driven PR's supplier/rate/GST/discount/payment-cycle/attachment
-- fields were invisible to the approval screen even though they're stored
-- (confirmed live: this view had none of them). Reproduced byte-for-byte
-- from OBJECT_DEFINITION() (same convention as
-- 33_nonstaff_approver_name_display.sql) with ONLY the additive fields
-- below — request_mode/vendor_sno/vendor_name/payment_cycle_days on the
-- header, and rate/gst_pct/discount_pct/taxable_amount/gst_amount/
-- item_attachment inside the existing pr_item_details JSON subselect.
-- Nothing else changed; every existing consumer keeps every existing field.
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
    pbf.vendor_sno,
    vk.company_name              AS vendor_name,
    pbf.payment_cycle_days,

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
            pid.item_rate                AS rate,
            pid.gst_pct,
            pid.discount_pct,
            pid.taxable_amount,
            pid.gst_amount,
            pid.pr_prod_file              AS item_attachment
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
LEFT JOIN dbo.kyc_basic_info vk
    ON vk.kyc_basic_info_sno = pbf.vendor_sno
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
