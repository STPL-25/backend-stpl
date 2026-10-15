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