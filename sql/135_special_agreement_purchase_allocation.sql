-- ============================================================
-- 135_special_agreement_purchase_allocation.sql   (Non_trade_Dev)
--
-- Purchase page <-> Special Agreement.
-- An approved PR line whose product is covered by a live (approved, in-date) Special Agreement can be
-- allocated to the agreement supplier(s) on the Purchase page:
--   * one supplier  -> the whole line goes to that supplier
--   * several       -> the qty is split (e.g. 1000 = 700 + 300), each supplier gets its own PR group
-- Each supplier group becomes its own "PR/<group>" entry (the way PO Approvals + the Purchase list
-- already model split POs: pr_item_details.[group]), and gets a quotation raised from the agreement
-- (Fixed: agreed rate, Unfixed: rate entered by Purchase), with the agreement document attached.
-- The quotation then goes through the normal PO approval - nothing here approves or creates a PO.
--
-- A qty split cannot be stored any other way in this model, so the PR line is cut: the original line
-- keeps the first allocation's qty and a linked child line (split_parent_item_sno) is added for each
-- further supplier. original_qty remembers the qty before the cut; PR history gets an entry.
-- Re-runnable.
-- ============================================================

IF COL_LENGTH('dbo.pr_item_details', 'split_parent_item_sno') IS NULL
    ALTER TABLE dbo.pr_item_details ADD split_parent_item_sno INT NULL;
IF COL_LENGTH('dbo.pr_item_details', 'original_qty') IS NULL
    ALTER TABLE dbo.pr_item_details ADD original_qty DECIMAL(18,4) NULL;
IF COL_LENGTH('dbo.pr_item_details', 'special_agreement_sno') IS NULL
    ALTER TABLE dbo.pr_item_details ADD special_agreement_sno INT NULL;
GO

-- ── which PR lines have a live agreement, and with whom ─────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetSpecialAgreementOptionsForPR
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @pr INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT),
            @grp INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.group') AS INT),
            @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @com INT = (SELECT com_sno FROM dbo.pr_basic_info WHERE pr_basic_sno = @pr);

    SELECT pid.pr_item_sno, pid.prod_sno, pm.prod_name, pm.prod_code, pid.specification, pid.qty, pid.unit,
           um.uom_name, pid.est_cost,
           (
               SELECT sa.special_agreement_sno, sa.agreement_no, sa.agreement_type, sa.vendor_sno,
                      k.company_name AS vendor_name, it.rate_amount, it.max_qty,
                      sa.period_start_date, sa.period_end_date, sa.agreement_doc_url
               FROM dbo.special_agreement_item it
               JOIN dbo.special_agreement sa ON sa.special_agreement_sno = it.special_agreement_sno
               JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno AND k.status = 'A' AND k.is_active = 'Y'
               WHERE it.prod_sno = pid.prod_sno AND it.is_active = 'Y'
                 AND sa.is_active = 'Y' AND sa.status = 'A' AND sa.com_sno = @com
                 AND @today BETWEEN sa.period_start_date AND sa.period_end_date
               ORDER BY k.company_name
               FOR JSON PATH
           ) AS agreements_json
    FROM dbo.pr_item_details pid
    JOIN dbo.product_master pm ON pm.prod_sno = pid.prod_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = pid.unit
    WHERE pid.pr_basic_sno = @pr AND pid.is_active = 'Y'
      AND (pid.[group] = @grp OR (pid.[group] IS NULL AND @grp IS NULL))
      AND NOT EXISTS (SELECT 1 FROM dbo.supplier_quotation_items qi
                      JOIN dbo.supplier_quotation_info q ON q.sq_basic_sno = qi.sq_basic_sno AND q.is_active = 1
                      WHERE qi.pr_item_sno = pid.pr_item_sno)
      AND EXISTS (SELECT 1 FROM dbo.special_agreement_item it
                  JOIN dbo.special_agreement sa ON sa.special_agreement_sno = it.special_agreement_sno
                  JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno AND k.status = 'A' AND k.is_active = 'Y'
                  WHERE it.prod_sno = pid.prod_sno AND it.is_active = 'Y'
                    AND sa.is_active = 'Y' AND sa.status = 'A' AND sa.com_sno = @com
                    AND @today BETWEEN sa.period_start_date AND sa.period_end_date)
    ORDER BY pid.pr_item_sno;
END;
GO

-- ── apply the allocation: cut lines, stamp one PR group per supplier ────────
-- Input: { pr_basic_sno, group, created_by, allocations: [{ pr_item_sno, special_agreement_sno, qty, tax_pct, unit_price }] }
-- Output (1 row): groups_json = [{ group_no, pr_no, vendor_sno, quotation_ref_no, agreement_doc_url, valid_upto,
--                                  com_sno, div_sno, brn_sno, dept_sno, items:[...] }]
CREATE OR ALTER PROCEDURE dbo.sp_nt_ApplySpecialAgreementToPR
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @pr INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT),
                @grp INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.group') AS INT),
                @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.created_by'),
                @today DATE = CAST(GETDATE() AS DATE);

        IF @pr IS NULL OR @by IS NULL THROW 58401, 'pr_basic_sno and created_by are required.', 1;

        DECLARE @pr_no VARCHAR(30), @com INT, @div INT, @brn INT, @dept INT;
        SELECT @pr_no = pr_no, @com = com_sno, @div = div_sno, @brn = brn_sno, @dept = dept_sno
        FROM dbo.pr_basic_info WITH (UPDLOCK) WHERE pr_basic_sno = @pr AND status = 'A' AND is_active = 'Y';
        IF @pr_no IS NULL THROW 58402, 'The requisition is not an approved, active PR.', 1;

        -- the quotations must be creatable afterwards: same workflow lookup sp_nt_CreateSupplierQuotation does
        IF NOT EXISTS (
            SELECT 1 FROM dbo.workflow_types wt
            JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
            WHERE wt.brn_sno = @brn AND wt.dept_sno = @dept AND wt.com_sno = @com AND wt.div_sno = @div
              AND awm.entity_type = dbo.fn_resolve_approval_entity('PurchaseOrder', 'STANDARD')
              AND wt.is_active = 'Y' AND awm.is_active = 'Y'
              AND EXISTS (SELECT 1 FROM dbo.workflow_stage s WHERE s.workflow_types_id = wt.workflow_types_id AND s.is_active = 'Y'))
            THROW 58403, 'No active PO approval workflow is configured for this PR''s branch and department.', 1;

        CREATE TABLE #a (
            idx INT IDENTITY(1,1) PRIMARY KEY, pr_item_sno INT, sa_sno INT, qty DECIMAL(18,4), tax_pct DECIMAL(9,4), price_in DECIMAL(18,4),
            vendor_sno INT, agreement_no VARCHAR(30), agreement_type VARCHAR(10), doc NVARCHAR(500), period_end DATE,
            rate DECIMAL(18,2), max_qty DECIMAL(18,4), unit_price DECIMAL(18,4),
            grp INT NULL, final_item_sno INT NULL
        );
        INSERT INTO #a (pr_item_sno, sa_sno, qty, tax_pct, price_in)
        SELECT TRY_CAST(JSON_VALUE(j.value, '$.pr_item_sno') AS INT), TRY_CAST(JSON_VALUE(j.value, '$.special_agreement_sno') AS INT),
               TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), TRY_CAST(JSON_VALUE(j.value, '$.tax_pct') AS DECIMAL(9,4)),
               TRY_CAST(JSON_VALUE(j.value, '$.unit_price') AS DECIMAL(18,4))
        FROM OPENJSON(@jsonInput, '$.allocations') j;

        IF NOT EXISTS (SELECT 1 FROM #a) THROW 58404, 'Nothing to allocate.', 1;
        IF EXISTS (SELECT 1 FROM #a WHERE pr_item_sno IS NULL OR sa_sno IS NULL OR qty IS NULL OR qty <= 0)
            THROW 58405, 'Every allocation needs a PR line, an agreement and a quantity greater than zero.', 1;
        IF EXISTS (SELECT 1 FROM #a WHERE tax_pct IS NULL OR tax_pct < 0 OR tax_pct > 100)
            THROW 58406, 'Enter the GST % (0-100) for every allocation.', 1;
        IF EXISTS (SELECT pr_item_sno, sa_sno FROM #a GROUP BY pr_item_sno, sa_sno HAVING COUNT(*) > 1)
            THROW 58407, 'The same line is allocated to the same agreement more than once.', 1;

        -- every line: belongs to this PR + group, still active, not quoted yet
        IF EXISTS (
            SELECT 1 FROM (SELECT DISTINCT pr_item_sno FROM #a) x
            WHERE NOT EXISTS (SELECT 1 FROM dbo.pr_item_details pid
                              WHERE pid.pr_item_sno = x.pr_item_sno AND pid.pr_basic_sno = @pr AND pid.is_active = 'Y'
                                AND (pid.[group] = @grp OR (pid.[group] IS NULL AND @grp IS NULL))))
            THROW 58408, 'One or more lines do not belong to this requisition entry (or are no longer active).', 1;
        IF EXISTS (SELECT 1 FROM #a x JOIN dbo.supplier_quotation_items qi ON qi.pr_item_sno = x.pr_item_sno
                   JOIN dbo.supplier_quotation_info q ON q.sq_basic_sno = qi.sq_basic_sno AND q.is_active = 1)
            THROW 58409, 'A quotation already exists for one of these lines - allocate before quoting.', 1;

        -- every agreement: live, covers the line's product, same company, approved supplier
        UPDATE a SET vendor_sno = sa.vendor_sno, agreement_no = sa.agreement_no, agreement_type = sa.agreement_type,
                     doc = sa.agreement_doc_url, period_end = sa.period_end_date, rate = it.rate_amount, max_qty = it.max_qty
        FROM #a a
        JOIN dbo.pr_item_details pid ON pid.pr_item_sno = a.pr_item_sno
        JOIN dbo.special_agreement sa ON sa.special_agreement_sno = a.sa_sno
        JOIN dbo.special_agreement_item it ON it.special_agreement_sno = sa.special_agreement_sno AND it.prod_sno = pid.prod_sno AND it.is_active = 'Y'
        JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno AND k.status = 'A' AND k.is_active = 'Y'
        WHERE sa.is_active = 'Y' AND sa.status = 'A' AND sa.com_sno = @com AND @today BETWEEN sa.period_start_date AND sa.period_end_date;
        IF EXISTS (SELECT 1 FROM #a WHERE vendor_sno IS NULL)
            THROW 58410, 'An agreement is not live for this product (not approved, expired, other company, or the product is not on it).', 1;

        IF EXISTS (SELECT 1 FROM #a WHERE max_qty IS NOT NULL AND qty > max_qty)
            THROW 58411, 'An allocation is above the agreement''s maximum quantity for that product.', 1;

        -- price: Fixed = the agreed rate (never taken from the client); Unfixed = what Purchase entered
        UPDATE #a SET unit_price = CASE WHEN agreement_type = 'FIXED' THEN rate ELSE price_in END;
        IF EXISTS (SELECT 1 FROM #a WHERE unit_price IS NULL OR unit_price <= 0)
            THROW 58412, 'Enter a rate greater than zero for every Unfixed-agreement allocation.', 1;

        -- each line must be allocated in full (the split must add up to the PR qty)
        IF EXISTS (SELECT 1 FROM (SELECT pr_item_sno, SUM(qty) q FROM #a GROUP BY pr_item_sno) s
                   JOIN dbo.pr_item_details pid ON pid.pr_item_sno = s.pr_item_sno
                   WHERE ABS(s.q - pid.qty) > 0.0001)
            THROW 58413, 'The allocated quantities must add up to the PR quantity for each line.', 1;

        -- one PR group per supplier, numbered after the PR's existing groups
        DECLARE @next_group INT = (SELECT ISNULL(MAX([group]), 0) FROM dbo.pr_item_details WITH (UPDLOCK, HOLDLOCK) WHERE pr_basic_sno = @pr);
        CREATE TABLE #g (vendor_sno INT PRIMARY KEY, grp INT);
        INSERT INTO #g (vendor_sno, grp)
        SELECT vendor_sno, @next_group + ROW_NUMBER() OVER (ORDER BY MIN(idx)) FROM #a GROUP BY vendor_sno;
        UPDATE a SET grp = g.grp FROM #a a JOIN #g g ON g.vendor_sno = a.vendor_sno;

        -- cut the lines. The first allocation of a line keeps the original row, further ones become linked child rows.
        DECLARE @history NVARCHAR(MAX) = N'';
        DECLARE @idx INT, @item INT, @qty DECIMAL(18,4), @g INT, @sa INT, @orig_qty DECIMAL(18,4), @first BIT, @new_item INT;
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT idx, pr_item_sno, qty, grp, sa_sno FROM #a ORDER BY pr_item_sno, idx;
        OPEN c;
        DECLARE @prev_item INT = NULL;
        FETCH NEXT FROM c INTO @idx, @item, @qty, @g, @sa;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @prev_item IS NULL OR @prev_item <> @item
            BEGIN
                SET @first = 1;
                SELECT @orig_qty = ISNULL(original_qty, qty) FROM dbo.pr_item_details WHERE pr_item_sno = @item;
                SET @history = @history + N'Line ' + CAST(@item AS NVARCHAR(20)) + N' (qty ' + CAST(CAST(@orig_qty AS DECIMAL(18,2)) AS NVARCHAR(30)) + N'): ';
            END
            ELSE SET @first = 0;

            IF @first = 1
            BEGIN
                UPDATE dbo.pr_item_details
                SET qty = @qty, total_cost = CASE WHEN est_cost IS NULL THEN total_cost ELSE est_cost * @qty END,
                    [group] = @g, original_qty = @orig_qty, special_agreement_sno = @sa, modified_by = @by, modified_date = GETDATE()
                WHERE pr_item_sno = @item;
                UPDATE #a SET final_item_sno = @item WHERE idx = @idx;
            END
            ELSE
            BEGIN
                INSERT INTO dbo.pr_item_details (pr_basic_sno, prod_sno, specification, qty, unit, est_cost, total_cost, remarks,
                       created_by, created_date, is_active, pr_no, pr_prod_file, item_type, [group], service_sno, agreement_sno,
                       item_description, item_rate, gst_pct, discount_pct, taxable_amount, gst_amount,
                       split_parent_item_sno, original_qty, special_agreement_sno)
                SELECT pr_basic_sno, prod_sno, specification, @qty, unit, est_cost, CASE WHEN est_cost IS NULL THEN total_cost ELSE est_cost * @qty END, remarks,
                       @by, GETDATE(), 'Y', pr_no, pr_prod_file, item_type, @g, service_sno, agreement_sno,
                       item_description, item_rate, gst_pct, discount_pct, taxable_amount, gst_amount,
                       @item, @orig_qty, @sa
                FROM dbo.pr_item_details WHERE pr_item_sno = @item;
                SET @new_item = SCOPE_IDENTITY();
                UPDATE #a SET final_item_sno = @new_item WHERE idx = @idx;
            END
            SET @history = @history + CAST(CAST(@qty AS DECIMAL(18,2)) AS NVARCHAR(30)) + N' -> group ' + CAST(@g AS NVARCHAR(10)) + N'; ';
            SET @prev_item = @item;
            FETCH NEXT FROM c INTO @idx, @item, @qty, @g, @sa;
        END
        CLOSE c; DEALLOCATE c;

        INSERT INTO dbo.pr_history_data (pr_basic_sno, pr_edit_data, is_active, approver_ecno, status, status_by, status_date, commends, pr_no)
        VALUES (@pr, NULL, 'Y', @by, 'A', @by, GETDATE(),
                LEFT(N'ALLOCATED TO SPECIAL AGREEMENT SUPPLIERS. ' + @history, 4000), @pr_no);

        -- display pr_no of an entry: base/<group> once the PR has more than one group, same rule as the Purchase list
        DECLARE @group_count INT = (SELECT COUNT(*) FROM (SELECT [group] FROM dbo.pr_item_details WHERE pr_basic_sno = @pr AND is_active = 'Y' GROUP BY [group]) z);

        COMMIT TRANSACTION;

        SELECT 'SUCCESS' AS result,
        (
            SELECT g.grp AS group_no,
                   CASE WHEN @group_count > 1 THEN @pr_no + '/' + CAST(g.grp AS VARCHAR(10)) ELSE @pr_no END AS pr_no,
                   g.vendor_sno,
                   (SELECT STRING_AGG(x.agreement_no, ', ') FROM (SELECT DISTINCT agreement_no FROM #a WHERE vendor_sno = g.vendor_sno) x) AS quotation_ref_no,
                   (SELECT TOP 1 doc FROM #a WHERE vendor_sno = g.vendor_sno AND doc IS NOT NULL ORDER BY idx) AS agreement_doc_url,
                   (SELECT MIN(period_end) FROM #a WHERE vendor_sno = g.vendor_sno) AS valid_upto,
                   @com AS com_sno, @div AS div_sno, @brn AS brn_sno, @dept AS dept_sno,
                   (
                       SELECT a.final_item_sno AS pr_item_sno, pid.prod_sno, pid.specification, a.qty, pid.unit,
                              a.unit_price, CAST(0 AS DECIMAL(9,4)) AS discount_pct, a.tax_pct,
                              CAST(ROUND(a.qty * a.unit_price * (1 + a.tax_pct / 100.0), 4) AS DECIMAL(18,4)) AS total_amount,
                              a.agreement_no AS remarks
                       FROM #a a JOIN dbo.pr_item_details pid ON pid.pr_item_sno = a.final_item_sno
                       WHERE a.vendor_sno = g.vendor_sno ORDER BY a.idx
                       FOR JSON PATH
                   ) AS items
            FROM #g g ORDER BY g.grp
            FOR JSON PATH
        ) AS groups_json;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
