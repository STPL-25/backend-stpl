-- ============================================================
-- 115: When a workflow's approver changes, every item still waiting on the OLD approver under
--      that workflow type moves to the NEW approver in real time, and both people are notified.
-- Database: Non_trade_Dev. Re-runnable.
--
-- Why: approvals snapshot the approver on the item (pr_basic_info.current_approver_id,
-- po_request_info.current_approver_id, supplier_quotation_info.approver_ecno, ...). Editing the workflow
-- (Approval Workflow Manager -> sp_nt_UpdateWorkflowStage) only affected items created afterwards, so a
-- pending PO/quotation stayed with the replaced approver, who could still see it but could not approve
-- ("Current approver is not part of the approval workflow") while the new approver never saw it.
--
-- How:
--  * trg_workflow_stage_reassign_approvers (AFTER UPDATE on workflow_stage) compares the stage list before
--    and after. Approvers that disappeared are paired, in stage order, with approvers that appeared; it only
--    acts when the counts match (a pure replacement), so adding/removing a stage never guesses.
--  * For each pair, every PENDING item of that workflow_types_id whose current approver is the old person is
--    re-pointed to the new person: PR, PO, quotation, KYC, Service Agreement, Service PO cycle, loan voucher.
--  * Each move writes two rows to approver_reassignment_log (one per person, OLD / NEW). The 60 s sweep
--    (and an immediate sweep from the workflow-save endpoints) turns them into bell notifications.
--  * The new approver's generic "Approval pending" notice is pre-marked SENT so they get one, specific message.
-- ============================================================

IF OBJECT_ID('dbo.approver_reassignment_log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.approver_reassignment_log (
        notice_sno        INT IDENTITY(1,1) PRIMARY KEY,
        entity_type       VARCHAR(40)   NOT NULL,
        entity_id         INT           NOT NULL,
        label             NVARCHAR(200) NULL,
        workflow_types_id INT           NULL,
        old_ecno          VARCHAR(50)   NOT NULL,
        new_ecno          VARCHAR(50)   NOT NULL,
        recipient_ecno    VARCHAR(50)   NOT NULL,
        recipient_role    VARCHAR(3)    NOT NULL,            -- OLD | NEW
        status            VARCHAR(10)   NOT NULL DEFAULT 'PENDING',   -- PENDING | CLAIMED | SENT | FAILED
        error_message     NVARCHAR(500) NULL,
        created_at        DATETIME      NOT NULL DEFAULT GETDATE(),
        modified_at       DATETIME      NULL,
        CONSTRAINT CK_approver_reassign_role   CHECK (recipient_role IN ('OLD','NEW')),
        CONSTRAINT CK_approver_reassign_status CHECK (status IN ('PENDING','CLAIMED','SENT','FAILED'))
    );
END;
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

        UPDATE t SET current_approver_id = m.new_ecno
        OUTPUT 'BankPaymentVoucher', inserted.voucher_sno, N'Loan Voucher ' + ISNULL(inserted.voucher_no, ''), m.wf, m.old_ecno, m.new_ecno INTO #moved
        FROM dbo.bank_payment_voucher t JOIN #map m ON m.wf = t.workflow_types_id AND m.old_ecno = t.current_approver_id
        WHERE t.status = 'PENDING';

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

-- Claims reassignment notices that still have to be delivered (PENDING / FAILED) and returns them with
-- display names and the screen the NEW approver's bell should open.
CREATE OR ALTER PROCEDURE dbo.sp_nt_ClaimApproverChangeNotices
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @claimed TABLE (notice_sno INT PRIMARY KEY);

    UPDATE dbo.approver_reassignment_log
    SET status = 'CLAIMED', modified_at = GETDATE()
    OUTPUT inserted.notice_sno INTO @claimed
    WHERE status IN ('PENDING', 'FAILED');

    SELECT l.notice_sno, l.entity_type, l.entity_id, l.label, l.recipient_ecno, l.recipient_role,
           l.old_ecno, l.new_ecno,
           COALESCE(oe.ename, ons.full_name, l.old_ecno) AS old_name,
           COALESCE(ne.ename, nns.full_name, l.new_ecno) AS new_name,
           CASE l.entity_type
                WHEN 'PurchaseRequisition' THEN 'PRApprovalScreen'
                WHEN 'PurchaseOrder'       THEN 'POApprovalScreen'
                WHEN 'Quotation'           THEN 'POApprovalScreen'
                WHEN 'KYC'                 THEN 'KYCApprovalScreen'
                WHEN 'ServiceAgreement'    THEN 'ServiceAgreementApprovalScreen'
                WHEN 'ServicePO'           THEN 'ServicePoApprovalScreen'
                WHEN 'BankPaymentVoucher'  THEN 'LoanVoucherApprovalScreen'
           END AS screen
    FROM @claimed c
    JOIN dbo.approver_reassignment_log l ON l.notice_sno = c.notice_sno
    LEFT JOIN dbo.vw_verified_employees oe ON oe.ecno = l.old_ecno
    LEFT JOIN dbo.nt_nonstaff_login ons ON ons.login_id = l.old_ecno
    LEFT JOIN dbo.vw_verified_employees ne ON ne.ecno = l.new_ecno
    LEFT JOIN dbo.nt_nonstaff_login nns ON nns.login_id = l.new_ecno
    ORDER BY l.notice_sno;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_MarkApproverChangeNoticeSent
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.approver_reassignment_log
    SET status = CASE WHEN JSON_VALUE(@jsonInput, '$.status') = 'SENT' THEN 'SENT' ELSE 'FAILED' END,
        error_message = LEFT(JSON_VALUE(@jsonInput, '$.error_message'), 500),
        modified_at = GETDATE()
    WHERE notice_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.notice_sno') AS INT);
END;
GO
