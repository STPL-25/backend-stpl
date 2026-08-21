-- ============================================================
-- vw_PR_Basic_Info v2 — surface service lines in the PR approval screen
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : sp_get_pr_details_for_approval (PR.repository.js:getPrRecords),
--            the data source for PRApprovalScreen.tsx / PurchaseRequisitionReview.tsx
--
-- Why this is needed
-- ------------------
-- Found while smoke-testing 06_usp_InsertPurchaseRequest_v2.sql: this view's
-- item-details subquery does `INNER JOIN product_master pm ON pid.prod_sno =
-- pm.prod_sno` and `INNER JOIN uom_master uom ON uom.uom_sno = pid.unit`.
-- Now that pr_item_details.prod_sno/unit can legitimately be NULL on a
-- service line, those INNER JOINs would silently drop every service line
-- from the JSON array this view returns — an approver opening the PR would
-- never see the service lines at all, even though they saved correctly.
--
-- Fix: both become LEFT JOINs, plus a LEFT JOIN to service_master so service
-- lines carry their own name/code the same way product lines do. This is a
-- pure widening — every existing PR's item list (all product_sno NOT NULL
-- today) returns byte-for-byte the same rows as before; only newly-possible
-- service rows start appearing.
--
-- Everything outside the item-details subquery is preserved unchanged from
-- the live definition.
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
    -- v2: LEFT JOIN product_master/uom_master (was INNER — excluded service
    -- lines) + LEFT JOIN service_master so both line types are combined into
    -- one list instead of showing only products.
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
            phd.status_by, vve.ename, phd.status_date, phd.commends, phd.pr_edit_data
        FROM pr_history_data phd
        INNER JOIN vw_verified_employees vve
            ON phd.status_by = vve.ecno
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
-- After running, confirm:
--   SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID('dbo.vw_PR_Basic_Info');
--   -- Any existing product-only PR should return an identical item list to before.
-- ============================================================
