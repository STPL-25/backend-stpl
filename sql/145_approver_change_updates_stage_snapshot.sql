-- ============================================================
-- 145: Approver change must also move the approval ENGINE's stage snapshot (fix for sql/115).
-- Database: Non_trade_Dev. Re-runnable.
--
-- Bug: after an approver was replaced in a workflow, the NEW approver opened the PR (or Payment) and saw
--   * "Approval Path" still naming the OLD approver, and
--   * no Approve / Reject / Forward / Send back buttons.
-- Cause: sql/115 re-pointed pr_basic_info.current_approver_id (so the item showed up in the new approver's
--   list) but the conditional approval engine (sql/99, also used by Payment) works from
--   approval_instance.stages_json - a SNAPSHOT of the stage chain taken when the item was raised.
--   sp_nt_PrApprovalContext / sp_nt_PrApprovalAct (and the Payment equivalents) read the primary approver
--   and alternates from that snapshot, so the new approver was "NONE" for the stage and the screen
--   drew the old name.
--
-- Fix:
--   1. fn_approval_stages_swap(stages, old, new): rewrites approver_ecno / next_approver_ecno / alternates.
--   2. The reassign trigger now also rewrites stages_json of every PENDING approval_instance of that workflow
--      type, and moves payment_info.current_approver_id for pending Payments.
--   3. Backfill: pending PR instances already reassigned by the old trigger (approver_reassignment_log) are
--      repaired with the swap that was logged for that very item.
-- ============================================================

CREATE OR ALTER FUNCTION dbo.fn_approval_stages_swap
(
    @stages NVARCHAR(MAX),
    @old    VARCHAR(50),
    @new    VARCHAR(50)
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    IF @stages IS NULL OR ISJSON(@stages) = 0 OR @old IS NULL OR @new IS NULL OR @old = @new RETURN @stages;

    RETURN ISNULL((
        SELECT '[' + STRING_AGG(c.v3, ',') WITHIN GROUP (ORDER BY CAST(x.[key] AS INT)) + ']'
        FROM OPENJSON(@stages) x
        CROSS APPLY (SELECT CASE WHEN JSON_VALUE(x.value, '$.approver_ecno') COLLATE DATABASE_DEFAULT = @old
                                 THEN JSON_MODIFY(x.value, '$.approver_ecno', @new) ELSE x.value END AS v1) a
        CROSS APPLY (SELECT CASE WHEN JSON_VALUE(a.v1, '$.next_approver_ecno') COLLATE DATABASE_DEFAULT = @old
                                 THEN JSON_MODIFY(a.v1, '$.next_approver_ecno', @new) ELSE a.v1 END AS v2) b
        CROSS APPLY (SELECT CASE WHEN EXISTS (SELECT 1 FROM OPENJSON(b.v2, '$.alternates') z WHERE z.value COLLATE DATABASE_DEFAULT = @old)
                                 THEN JSON_MODIFY(b.v2, '$.alternates', JSON_QUERY((
                                          SELECT '[' + STRING_AGG('"' + STRING_ESCAPE(CASE WHEN z.value COLLATE DATABASE_DEFAULT = @old THEN @new ELSE z.value END, 'json') + '"', ',') + ']'
                                          FROM OPENJSON(b.v2, '$.alternates') z)))
                                 ELSE b.v2 END AS v3) c
    ), @stages);
END
GO

CREATE OR ALTER TRIGGER dbo.trg_workflow_stage_reassign_approvers
ON dbo.workflow_stage
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(stage_order_json) RETURN;

    BEGIN TRY
        CREATE TABLE #old (wf INT, pos INT, ecno VARCHAR(50) COLLATE DATABASE_DEFAULT);
        CREATE TABLE #new (wf INT, pos INT, ecno VARCHAR(50) COLLATE DATABASE_DEFAULT);

        INSERT INTO #old
        SELECT d.workflow_types_id, TRY_CAST(j.[key] AS INT), NULLIF(LTRIM(RTRIM(JSON_VALUE(j.value, '$.approver_ecno'))), '')
        FROM deleted d CROSS APPLY OPENJSON(d.stage_order_json) j
        WHERE ISJSON(d.stage_order_json) = 1 AND d.is_active = 'Y';

        INSERT INTO #new
        SELECT i.workflow_types_id, TRY_CAST(j.[key] AS INT), NULLIF(LTRIM(RTRIM(JSON_VALUE(j.value, '$.approver_ecno'))), '')
        FROM inserted i CROSS APPLY OPENJSON(i.stage_order_json) j
        WHERE ISJSON(i.stage_order_json) = 1 AND i.is_active = 'Y';

        -- approvers that left / joined (by workflow), numbered in stage order
        CREATE TABLE #removed (wf INT, n INT, ecno VARCHAR(50) COLLATE DATABASE_DEFAULT);
        CREATE TABLE #added   (wf INT, n INT, ecno VARCHAR(50) COLLATE DATABASE_DEFAULT);

        INSERT INTO #removed
        SELECT wf, ROW_NUMBER() OVER (PARTITION BY wf ORDER BY MIN(pos)), ecno
        FROM #old o WHERE ecno IS NOT NULL AND NOT EXISTS (SELECT 1 FROM #new n WHERE n.wf = o.wf AND n.ecno = o.ecno)
        GROUP BY wf, ecno;

        INSERT INTO #added
        SELECT wf, ROW_NUMBER() OVER (PARTITION BY wf ORDER BY MIN(pos)), ecno
        FROM #new n WHERE ecno IS NOT NULL AND NOT EXISTS (SELECT 1 FROM #old o WHERE o.wf = n.wf AND o.ecno = n.ecno)
        GROUP BY wf, ecno;

        CREATE TABLE #map (wf INT, old_ecno VARCHAR(50) COLLATE DATABASE_DEFAULT, new_ecno VARCHAR(50) COLLATE DATABASE_DEFAULT);
        -- 1) same stage position: the person standing in stage N was swapped for a new person
        --    (still works when the same save also adds/removes other stages)
        INSERT INTO #map
        SELECT o.wf, o.ecno, n.ecno
        FROM #old o
        JOIN #new n ON n.wf = o.wf AND n.pos = o.pos
        WHERE o.ecno IS NOT NULL AND n.ecno IS NOT NULL AND o.ecno <> n.ecno
          AND EXISTS (SELECT 1 FROM #removed r WHERE r.wf = o.wf AND r.ecno = o.ecno)
          AND EXISTS (SELECT 1 FROM #added   a WHERE a.wf = n.wf AND a.ecno = n.ecno)
        GROUP BY o.wf, o.ecno, n.ecno;

        -- 2) stages were reordered: pair what is left in stage order, only when the counts match
        INSERT INTO #map
        SELECT r.wf, r.ecno, a.ecno
        FROM (SELECT wf, ecno, ROW_NUMBER() OVER (PARTITION BY wf ORDER BY n) k FROM #removed rr
              WHERE NOT EXISTS (SELECT 1 FROM #map m WHERE m.wf = rr.wf AND m.old_ecno = rr.ecno)) r
        JOIN (SELECT wf, ecno, ROW_NUMBER() OVER (PARTITION BY wf ORDER BY n) k FROM #added aa
              WHERE NOT EXISTS (SELECT 1 FROM #map m WHERE m.wf = aa.wf AND m.new_ecno = aa.ecno)) a ON a.wf = r.wf AND a.k = r.k
        WHERE (SELECT COUNT(*) FROM #removed x WHERE x.wf = r.wf AND NOT EXISTS (SELECT 1 FROM #map m WHERE m.wf = x.wf AND m.old_ecno = x.ecno))
            = (SELECT COUNT(*) FROM #added y WHERE y.wf = r.wf AND NOT EXISTS (SELECT 1 FROM #map m WHERE m.wf = y.wf AND m.new_ecno = y.ecno));

        IF NOT EXISTS (SELECT 1 FROM #map) RETURN;

        -- The approval engine reads the approver from the stage snapshot taken when the item was raised
        -- (approval_instance.stages_json: PR + Payment). Swap the person there too, or the new approver sees
        -- the old name on the Approval Path and gets no action buttons.
        CREATE TABLE #mapk (k INT PRIMARY KEY, wf INT, old_ecno VARCHAR(50) COLLATE DATABASE_DEFAULT, new_ecno VARCHAR(50) COLLATE DATABASE_DEFAULT);
        INSERT INTO #mapk SELECT ROW_NUMBER() OVER (ORDER BY wf, old_ecno), wf, old_ecno, new_ecno FROM #map;
        DECLARE @k INT = 1, @kmax INT = (SELECT COUNT(*) FROM #mapk);
        WHILE @k <= @kmax
        BEGIN
            UPDATE ai SET stages_json = dbo.fn_approval_stages_swap(ai.stages_json, m.old_ecno, m.new_ecno), updated_at = GETDATE()
            FROM dbo.approval_instance ai JOIN #mapk m ON m.k = @k AND m.wf = ai.workflow_types_id
            WHERE ai.status = 'P' AND ai.stages_json LIKE N'%"' + m.old_ecno + N'"%';
            SET @k += 1;
        END;

        CREATE TABLE #moved (entity_type VARCHAR(40) COLLATE DATABASE_DEFAULT, entity_id INT, label NVARCHAR(200) COLLATE DATABASE_DEFAULT,
                             wf INT, old_ecno VARCHAR(50) COLLATE DATABASE_DEFAULT, new_ecno VARCHAR(50) COLLATE DATABASE_DEFAULT);

        UPDATE t SET current_approver_id = m.new_ecno
        OUTPUT 'PurchaseRequisition', inserted.pr_basic_sno, N'PR ' + inserted.pr_no, m.wf, m.old_ecno, m.new_ecno INTO #moved
        FROM dbo.pr_basic_info t JOIN #map m ON m.wf = t.workflow_types_id AND m.old_ecno = t.current_approver_id
        WHERE t.status = 'P';

        UPDATE t SET current_approver_id = m.new_ecno
        OUTPUT 'PurchaseOrder', inserted.po_basic_sno, N'PO ' + ISNULL(inserted.po_df_no, CAST(inserted.po_basic_sno AS VARCHAR(20))), m.wf, m.old_ecno, m.new_ecno INTO #moved
        FROM dbo.po_request_info t JOIN #map m ON m.wf = t.workflow_types_id AND m.old_ecno = t.current_approver_id
        WHERE t.status = 'P';

        UPDATE t SET approver_ecno = m.new_ecno
        OUTPUT 'Quotation', inserted.sq_basic_sno, N'Quotation ' + ISNULL(inserted.quotation_ref_no, inserted.pr_no), m.wf, m.old_ecno, m.new_ecno INTO #moved
        FROM dbo.supplier_quotation_info t JOIN #map m ON m.wf = t.workflow_types_id AND m.old_ecno = t.approver_ecno
        WHERE t.status = 'P';

        -- a quotation forwarded to / from the replaced approver keeps pointing at them otherwise
        UPDATE t SET transferred_to = m.new_ecno
        FROM dbo.supplier_quotation_info t JOIN #map m ON m.wf = t.workflow_types_id AND m.old_ecno = t.transferred_to
        WHERE t.status = 'P' AND t.is_active = 1;
        UPDATE t SET transferred_from = m.new_ecno
        FROM dbo.supplier_quotation_info t JOIN #map m ON m.wf = t.workflow_types_id AND m.old_ecno = t.transferred_from
        WHERE t.status = 'P' AND t.is_active = 1;

        UPDATE t SET approver_ecno = m.new_ecno
        OUTPUT 'KYC', inserted.kyc_basic_info_sno, N'KYC ' + ISNULL(inserted.company_name, ''), m.wf, m.old_ecno, m.new_ecno INTO #moved
        FROM dbo.kyc_basic_info t JOIN #map m ON m.wf = t.workflow_types_id AND m.old_ecno = t.approver_ecno
        WHERE t.status = 'P';

        UPDATE t SET current_approver_id = m.new_ecno
        OUTPUT 'ServiceAgreement', inserted.agreement_sno, N'Service Agreement ' + inserted.agreement_no, m.wf, m.old_ecno, m.new_ecno INTO #moved
        FROM dbo.service_agreement t JOIN #map m ON m.wf = t.workflow_types_id AND m.old_ecno = t.current_approver_id
        WHERE t.status = 'P';

        UPDATE c SET current_approver_id = m.new_ecno
        OUTPUT 'ServicePO', inserted.cycle_sno, N'Service PO ' + inserted.pr_no, m.wf, m.old_ecno, m.new_ecno INTO #moved
        FROM dbo.service_po_cycle c JOIN #map m ON m.wf = c.workflow_types_id AND m.old_ecno = c.current_approver_id
        WHERE c.status = 'PENDING_APPROVAL';

        IF OBJECT_ID('dbo.payment_info', 'U') IS NOT NULL
        BEGIN
            UPDATE t SET current_approver_id = m.new_ecno
            OUTPUT 'Payment', inserted.payment_sno, N'Payment ' + inserted.payment_no, m.wf, m.old_ecno, m.new_ecno INTO #moved
            FROM dbo.payment_info t JOIN #map m ON m.wf = t.workflow_types_id AND m.old_ecno = t.current_approver_id
            WHERE t.status = 'Pending Approval';
        END;

        IF NOT EXISTS (SELECT 1 FROM #moved) RETURN;

        INSERT INTO dbo.approver_reassignment_log (entity_type, entity_id, label, workflow_types_id, old_ecno, new_ecno, recipient_ecno, recipient_role)
        SELECT entity_type, entity_id, label, wf, old_ecno, new_ecno, old_ecno, 'OLD' FROM #moved
        UNION ALL
        SELECT entity_type, entity_id, label, wf, old_ecno, new_ecno, new_ecno, 'NEW' FROM #moved;

        -- the new approver gets the specific "reassigned to you" message, not a second generic one
        INSERT INTO dbo.approval_notice_log (entity_type, entity_id, approver_ecno, status)
        SELECT mv.entity_type, mv.entity_id, mv.new_ecno, 'SENT'
        FROM #moved mv
        WHERE NOT EXISTS (SELECT 1 FROM dbo.approval_notice_log l
                          WHERE l.entity_type = mv.entity_type AND l.entity_id = mv.entity_id AND l.approver_ecno = mv.new_ecno);
    END TRY
    BEGIN CATCH
        -- never block saving a workflow because the follow-up reassignment failed; the stage edit itself stands
        DECLARE @msg NVARCHAR(500) = LEFT(ERROR_MESSAGE(), 500);
        IF XACT_STATE() = -1 THROW;
        PRINT N'trg_workflow_stage_reassign_approvers: ' + @msg;
    END CATCH
END;
GO

-- ── Backfill: pending PRs already reassigned by the old trigger still carry the old name in their snapshot ──
-- Replays, per item and in the order logged, the exact swap sql/115 recorded for that item.
DECLARE @fix TABLE (k INT IDENTITY(1,1) PRIMARY KEY, entity_id INT, old_ecno VARCHAR(50), new_ecno VARCHAR(50));
INSERT INTO @fix (entity_id, old_ecno, new_ecno)
SELECT l.entity_id, l.old_ecno, l.new_ecno
FROM dbo.approver_reassignment_log l
WHERE l.recipient_role = 'NEW' AND l.entity_type = 'PurchaseRequisition'
ORDER BY l.notice_sno;

DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @fix);
WHILE @i <= @n
BEGIN
    UPDATE ai SET stages_json = dbo.fn_approval_stages_swap(ai.stages_json, f.old_ecno, f.new_ecno), updated_at = GETDATE()
    FROM dbo.approval_instance ai JOIN @fix f ON f.k = @i
    WHERE ai.entity_type = 'PurchaseRequisition' AND ai.entity_ref_id = f.entity_id AND ai.status = 'P'
      AND ai.stages_json LIKE N'%"' + f.old_ecno + N'"%';
    SET @i += 1;
END;
GO
