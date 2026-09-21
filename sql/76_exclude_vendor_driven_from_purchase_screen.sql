-- ============================================================
-- Exclude vendor-driven PRs from the Purchase Team screen
-- Database: Non_trade_Dev (MSSQL)
--
-- sp_nt_GetApprovedPRsForPurchase (predates this repo's sql/ convention —
-- reproduced byte-for-byte from OBJECT_DEFINITION(), same convention as
-- 33_nonstaff_approver_name_display.sql / 63_vw_pr_basic_info_vendor_driven.sql)
-- lists every status='A' PR that has no supplier_quotation_history row yet,
-- with no request_mode filter at all. Vendor-driven PRs never go through
-- the quotation flow, so they never get a supplier_quotation_history row —
-- they were showing up in the Purchase Team screen permanently, even after
-- their PO was already auto-created and emailed to the vendor
-- (sp_nt_CreateVendorDrivenPOFromPR / PR.controller.js#approvePr). Vendor-
-- driven PRs have their own dedicated queue (sp_nt_GetVendorDrivenApprovedPRs)
-- and don't belong here at all, at any stage — a straight request_mode
-- exclusion, not a "has a PO yet" check.
--
-- Only additive change: pbf.request_mode is now selected through the CTE,
-- and the final WHERE excludes it. Every other line is unchanged from the
-- live definition.
-- ============================================================

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
            pbf.request_mode,
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
      AND (p.request_mode IS NULL OR p.request_mode <> 'VENDOR_DRIVEN')
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
