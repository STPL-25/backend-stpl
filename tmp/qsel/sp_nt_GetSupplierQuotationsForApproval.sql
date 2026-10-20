CREATE   PROCEDURE dbo.sp_nt_GetSupplierQuotationsForApproval
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
            CASE
                WHEN g.grp IS NOT NULL AND gc.group_count > 1
                    THEN pbf.pr_no + '/' + CAST(g.grp AS varchar(10))
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
            SELECT COUNT(DISTINCT pid2.[group]) AS group_count
            FROM pr_item_details pid2
            WHERE pid2.pr_basic_sno = pbf.pr_basic_sno
              AND pid2.is_active = 'Y'
        ) gc
        WHERE pbf.is_active = 'Y'
          AND pbf.status = 'A'
    )

    SELECT
        sq.sq_basic_sno,
        sq.pr_basic_sno,
        pg.split_pr_no AS pr_no,
        pg.base_pr_no,
        pg.grp AS [group],

        pg.brn_sno,
        pg.brn_name,
        pg.brn_prefix,
        pg.dept_name,
        pg.div_prefix,
        pg.div_name,
        pg.div_sno,
        pg.com_name,
        pg.com_sno,
        pg.dept_sno,

        pg.reg_date,
        pg.required_date,
        pg.priority_sno,
        pg.purpose,

        pg.pr_created_by_name,
        pg.created_by AS pr_created_by,
        pg.created_date AS pr_created_date,

        sq.vendor_sno,
        vm.company_name,
        sq.quotation_ref_no,
        sq.quotation_date,
        sq.valid_upto,
        sq.currency_code,
        sq.payment_terms,
        sq.delivery_days,
        sq.remarks,

        CAST(CASE WHEN ISNULL(sq.is_selected, 0) = 1 THEN 1 ELSE 0 END AS bit) AS is_selected,

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

        appr.ename AS approver_name,
        sqcr.ename AS quotation_created_by_name,

        JSON_QUERY(
        (
            SELECT
                pg.pr_basic_sno,
                pg.split_pr_no AS pr_no,
                pg.base_pr_no,
                pg.grp AS [group],
                pg.reg_date,
                pg.required_date,
                pg.priority_sno,
                pg.purpose,
                pg.brn_name,
                pg.dept_name,
                pg.div_name,
                pg.com_name
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        )) AS pr_header,

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
                        THEN pg.base_pr_no + '/' + CAST(pid.[group] AS varchar(10))
                    ELSE pg.base_pr_no
                END AS pr_no
            FROM pr_item_details pid
            INNER JOIN product_master pm
                ON pm.prod_sno = pid.prod_sno
            INNER JOIN uom_master uom
                ON uom.uom_sno = pid.unit
            WHERE pid.pr_basic_sno = pg.pr_basic_sno
              AND pid.is_active = 'Y'
              AND (
                    (pid.[group] = pg.grp)
                    OR (pid.[group] IS NULL AND pg.grp IS NULL)
                  )
            FOR JSON PATH
        )) AS original_pr_item_details,

        JSON_QUERY(
        (
            SELECT
                sid.sq_item_sno,
                sid.sq_basic_sno,
                sid.pr_item_sno,
                sid.prod_sno,
                pm.prod_name,
                pm.prod_code,
                sid.specification,
                sid.qty,
                sid.unit,
                uom.uom_name,
                uom.uom_code,
                sid.unit_price,
                sid.discount_pct,
                sid.tax_pct,
                sid.total_amount,
                sid.delivery_days,
                sid.remarks,
                pid.est_cost AS pr_est_cost,
                pid.total_cost AS pr_total_cost,
                pid.qty AS pr_qty
            FROM supplier_quotation_items sid
            INNER JOIN product_master pm
                ON pm.prod_sno = sid.prod_sno
            INNER JOIN uom_master uom
                ON uom.uom_sno = sid.unit
            LEFT JOIN pr_item_details pid
                ON pid.pr_item_sno = sid.pr_item_sno
            WHERE sid.sq_basic_sno = sq.sq_basic_sno
              AND sid.is_active = 1
            FOR JSON PATH
        )) AS quotation_item_details,

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

        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM supplier_quotation_history sh
                WHERE sh.sq_basic_sno = sq.sq_basic_sno
                  AND sh.is_active = 1
            )
            THEN JSON_QUERY(
            (
                SELECT
                    sh.sq_history_sno,
                    sh.sq_basic_sno,
                    sh.status,
                    sh.status_by,
                    ve.ename AS status_by_name,
                    sh.comment,
                    sh.action_type,
                    sh.pr_basic_sno,
                    sh.selected_by,
                    sh.pr_no,
                    sh.transferred_from,
                    sh.transferred_to,
                    sh.sq_edit_data
                FROM supplier_quotation_history sh
                LEFT JOIN vw_verified_employees ve
                    ON ve.ecno = sh.status_by
                WHERE sh.sq_basic_sno = sq.sq_basic_sno
                  AND sh.is_active = 1
                FOR JSON PATH
            ))
            ELSE NULL
        END AS quotation_history,

        (
            SELECT TOP 1 ws.stage_order_json
            FROM workflow_stage ws
            WHERE ws.workflow_types_id = sq.workflow_types_id
              AND ws.is_active = 'Y'
        ) AS stage_order_json

    FROM supplier_quotation_info sq
    INNER JOIN pr_groups pg
        ON pg.pr_basic_sno = sq.pr_basic_sno
       AND pg.split_pr_no = sq.pr_no
    LEFT JOIN kyc_basic_info vm
        ON vm.kyc_basic_info_sno = sq.vendor_sno
    LEFT JOIN vw_verified_employees appr
        ON appr.ecno = sq.approver_ecno
    LEFT JOIN vw_verified_employees sqcr
        ON sqcr.ecno = sq.created_by
    WHERE sq.is_active = 1
      AND sq.status IN ('P','A')
    ORDER BY
        sq.pr_basic_sno,
        pg.grp,
        CAST(CASE WHEN ISNULL(sq.is_selected, 0) = 1 THEN 1 ELSE 0 END AS bit) DESC,
        sq.sq_basic_sno;

END TRY
BEGIN CATCH
    DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE(),
            @ErrorSeverity INT = ERROR_SEVERITY(),
            @ErrorState INT = ERROR_STATE();

    RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
END CATCH;
