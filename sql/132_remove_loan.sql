-- sql/132: remove the Loan feature (Loan Payments / Bank Payment Voucher / loan details & rates).
-- Backup of dropped data + definitions: sql/backups/remove_loan_2026-10-16/ (data_*.json,
-- dropped_module_definitions.sql). Rollback = re-run sql/89 + sql/92 then re-import the JSON.
-- service_agreement_statutory and the 8 existing Statutory agreements are KEPT (data preserved);
-- the Statutory service type/services are only deactivated so nothing new can be created.

-- 1. Procs/trigger that referenced the loan objects, with those branches removed
CREATE OR ALTER PROCEDURE dbo.sp_nt_ClaimApprovalNotices
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #pending (
        entity_type VARCHAR(40) COLLATE DATABASE_DEFAULT, entity_id INT, approver_ecno VARCHAR(50) COLLATE DATABASE_DEFAULT,
        label NVARCHAR(200) COLLATE DATABASE_DEFAULT, screen VARCHAR(60) COLLATE DATABASE_DEFAULT
    );

    INSERT INTO #pending
    SELECT 'PurchaseRequisition', pr_basic_sno, current_approver_id, N'PR ' + pr_no, 'PRApprovalScreen'
    FROM dbo.pr_basic_info WHERE status = 'P' AND current_approver_id IS NOT NULL;

    INSERT INTO #pending
    SELECT 'PurchaseOrder', po_basic_sno, current_approver_id, N'PO ' + ISNULL(po_df_no, CAST(po_basic_sno AS VARCHAR(20))), 'POApprovalScreen'
    FROM dbo.po_request_info WHERE status = 'P' AND current_approver_id IS NOT NULL;

    INSERT INTO #pending
    SELECT 'Quotation', sq_basic_sno, approver_ecno, N'Quotation ' + ISNULL(quotation_ref_no, pr_no), 'POApprovalScreen'
    FROM dbo.supplier_quotation_info WHERE status = 'P' AND approver_ecno IS NOT NULL;

    INSERT INTO #pending
    SELECT 'KYC', kyc_basic_info_sno, approver_ecno, N'KYC ' + ISNULL(company_name, ''), 'KYCApprovalScreen'
    FROM dbo.kyc_basic_info WHERE status = 'P' AND approver_ecno IS NOT NULL;

    INSERT INTO #pending
    SELECT 'ServiceAgreement', agreement_sno, current_approver_id, N'Service Agreement ' + agreement_no, 'ServiceAgreementApprovalScreen'
    FROM dbo.service_agreement WHERE status = 'P' AND current_approver_id IS NOT NULL;

    INSERT INTO #pending
    SELECT 'ServicePO', c.cycle_sno, c.current_approver_id, N'Service PO ' + c.pr_no + N' (' + sa.agreement_no + N')', 'ServicePoApprovalScreen'
    FROM dbo.service_po_cycle c JOIN dbo.service_agreement sa ON sa.agreement_sno = c.agreement_sno
    WHERE c.status = 'PENDING_APPROVAL' AND c.current_approver_id IS NOT NULL;

    CREATE TABLE #claimed (notice_sno INT PRIMARY KEY);

    UPDATE l SET status = 'PENDING', error_message = NULL, modified_at = GETDATE()
    OUTPUT inserted.notice_sno INTO #claimed (notice_sno)
    FROM dbo.approval_notice_log l
    JOIN #pending p ON p.entity_type = l.entity_type AND p.entity_id = l.entity_id AND p.approver_ecno = l.approver_ecno
    WHERE l.status = 'FAILED';

    BEGIN TRY
        INSERT INTO dbo.approval_notice_log (entity_type, entity_id, approver_ecno, status)
        OUTPUT inserted.notice_sno INTO #claimed (notice_sno)
        SELECT p.entity_type, p.entity_id, p.approver_ecno, 'PENDING'
        FROM #pending p
        WHERE NOT EXISTS (SELECT 1 FROM dbo.approval_notice_log l
                          WHERE l.entity_type = p.entity_type AND l.entity_id = p.entity_id AND l.approver_ecno = p.approver_ecno);
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (2601, 2627) THROW;   -- a concurrent sweep owns those rows
    END CATCH

    SELECT l.notice_sno, l.entity_type, l.entity_id, l.approver_ecno AS recipient_ecno, p.label, p.screen
    FROM #claimed c
    JOIN dbo.approval_notice_log l ON l.notice_sno = c.notice_sno
    JOIN #pending p ON p.entity_type = l.entity_type AND p.entity_id = l.entity_id AND p.approver_ecno = l.approver_ecno
    ORDER BY l.notice_sno;
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
CREATE OR ALTER PROCEDURE dbo.sp_nt_SaveServiceAgreementStatutory
    @agreement_sno INT,
    @service_type_code VARCHAR(30),
    @statutory_json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF @service_type_code <> 'STATUTORY'
    BEGIN
        DELETE FROM dbo.service_agreement_statutory WHERE agreement_sno = @agreement_sno;
        RETURN;
    END

    IF @statutory_json IS NULL OR ISJSON(@statutory_json) = 0
        THROW 58160, 'Loan details (type, sanctioned amount, interest rate, disbursement date, interest payment day) are required for a Statutory agreement.', 1;

    DECLARE @facility_type   VARCHAR(15)   = UPPER(LTRIM(RTRIM(JSON_VALUE(@statutory_json, '$.facility_type')))),
            @facility_ref_no NVARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@statutory_json, '$.facility_ref_no'))), ''),
            @sanctioned      DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@statutory_json, '$.sanctioned_amount') AS DECIMAL(18,2)),
            @drawing_power   DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@statutory_json, '$.drawing_power') AS DECIMAL(18,2)),
            @rate_type       VARCHAR(10)   = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(JSON_VALUE(@statutory_json, '$.rate_type'))), ''), 'FIXED')),
            @benchmark       DECIMAL(7,3)  = TRY_CAST(JSON_VALUE(@statutory_json, '$.benchmark_rate_pct') AS DECIMAL(7,3)),
            @spread          DECIMAL(7,3)  = TRY_CAST(JSON_VALUE(@statutory_json, '$.spread_pct') AS DECIMAL(7,3)),
            @interest        DECIMAL(7,3)  = TRY_CAST(JSON_VALUE(@statutory_json, '$.interest_rate_pct') AS DECIMAL(7,3)),
            @benchmark_name  VARCHAR(30)   = NULLIF(LTRIM(RTRIM(JSON_VALUE(@statutory_json, '$.benchmark_name'))), ''),
            @disbursed       DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@statutory_json, '$.disbursed_amount') AS DECIMAL(18,2)),
            @disb_date       DATE          = TRY_CAST(JSON_VALUE(@statutory_json, '$.disbursement_date') AS DATE),
            @pay_day         INT           = TRY_CAST(JSON_VALUE(@statutory_json, '$.interest_payment_day') AS INT),
            @basis           INT           = ISNULL(TRY_CAST(JSON_VALUE(@statutory_json, '$.day_count_basis') AS INT), 365);

    IF @facility_type IS NULL OR @facility_type NOT IN ('LOAN', 'REPO', 'CASH_CREDIT')
        THROW 58161, 'facility_type must be LOAN, REPO or CASH_CREDIT.', 1;
    IF @sanctioned IS NULL OR @sanctioned <= 0
        THROW 58162, 'sanctioned_amount (loan amount / limit) must be a positive amount.', 1;
    IF @rate_type NOT IN ('FIXED', 'FLOATING')
        THROW 58163, 'rate_type must be FIXED or FLOATING.', 1;

    IF @rate_type = 'FLOATING'
    BEGIN
        IF @benchmark IS NULL OR @spread IS NULL
            THROW 58164, 'A floating-rate facility needs both the benchmark (e.g. repo) rate and the spread.', 1;
        SET @interest = @benchmark + @spread;
        SET @benchmark_name = ISNULL(@benchmark_name, 'Repo');
    END
    ELSE
    BEGIN
        IF @interest IS NULL
            THROW 58165, 'interest_rate_pct is required for a fixed-rate facility.', 1;
        SET @benchmark = NULL;
        SET @spread = NULL;
        SET @benchmark_name = NULL;
    END

    IF @interest < 0 OR @interest > 100
        THROW 58166, 'The effective interest rate must be between 0 and 100 percent.', 1;

    IF @facility_type <> 'CASH_CREDIT'
        SET @drawing_power = NULL;
    ELSE IF @drawing_power IS NOT NULL AND (@drawing_power <= 0 OR @drawing_power > @sanctioned)
        THROW 58167, 'drawing_power must be positive and not more than the sanctioned limit.', 1;

    -- Loan details (sql/89)
    DECLARE @period_start DATE, @period_end DATE;
    SELECT @period_start = period_start_date, @period_end = period_end_date
    FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno;

    IF @disb_date IS NULL
        THROW 58168, 'The disbursement date (when interest starts) is required.', 1;
    IF @disb_date < @period_start OR @disb_date >= @period_end
        THROW 58169, 'The disbursement date must fall within the loan term (Duration From - Duration To).', 1;
    IF @pay_day IS NULL OR @pay_day NOT BETWEEN 1 AND 31
        THROW 58171, 'The interest payment day of the month (1-31) is required.', 1;
    IF @basis NOT IN (360, 365)
        THROW 58172, 'day_count_basis must be 365 or 360.', 1;

    IF @disbursed IS NULL
        SET @disbursed = CASE WHEN @facility_type = 'CASH_CREDIT' THEN 0 ELSE @sanctioned END;
    IF @disbursed < 0 OR @disbursed > @sanctioned
        THROW 58173, 'The disbursed amount must be between 0 and the sanctioned amount.', 1;
    IF @facility_type <> 'CASH_CREDIT' AND @disbursed = 0
        THROW 58174, 'The disbursed amount must be greater than zero (only a cash-credit limit can start at nil).', 1;

    UPDATE dbo.service_agreement_statutory
    SET facility_type = @facility_type, facility_ref_no = @facility_ref_no, sanctioned_amount = @sanctioned,
        drawing_power = @drawing_power, rate_type = @rate_type, benchmark_rate_pct = @benchmark,
        spread_pct = @spread, interest_rate_pct = @interest,
        benchmark_name = @benchmark_name, disbursed_amount = @disbursed, disbursement_date = @disb_date,
        interest_payment_day = @pay_day, day_count_basis = @basis, modified_at = GETDATE()
    WHERE agreement_sno = @agreement_sno;

    IF @@ROWCOUNT = 0
        INSERT INTO dbo.service_agreement_statutory (
            agreement_sno, facility_type, facility_ref_no, sanctioned_amount, drawing_power,
            rate_type, benchmark_rate_pct, spread_pct, interest_rate_pct,
            benchmark_name, disbursed_amount, disbursement_date, interest_payment_day, day_count_basis
        )
        VALUES (
            @agreement_sno, @facility_type, @facility_ref_no, @sanctioned, @drawing_power,
            @rate_type, @benchmark, @spread, @interest,
            @benchmark_name, @disbursed, @disb_date, @pay_day, @basis
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

-- 2. Drop loan-only procs, functions and tables (children before parents)
DROP PROCEDURE IF EXISTS dbo.sp_nt_ResolveBankVoucherWorkflow;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_CalcLoanVoucher;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_PreviewLoanInterest;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_CreateBankPaymentVoucher;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_ApproveBankPaymentVoucher;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_MarkBankPaymentVoucherPaid;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_AddLoanRatePeriod;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_DeleteLoanRatePeriod;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_AddLoanPrincipalTxn;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_DeleteLoanPrincipalTxn;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_GetLoanAccounts;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_GetBankPaymentVouchers;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_GetBankPaymentVoucher;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_GetBankPaymentVouchersForApproval;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_GetLoanDetail;
GO
DROP FUNCTION IF EXISTS dbo.fn_LoanBilledThrough;
GO
DROP FUNCTION IF EXISTS dbo.fn_LoanLockedThrough;
GO
DROP FUNCTION IF EXISTS dbo.fn_LoanInterestSegments;
GO
DROP FUNCTION IF EXISTS dbo.fn_LoanRateAt;
GO
DROP FUNCTION IF EXISTS dbo.fn_LoanNextDueDate;
GO
DROP FUNCTION IF EXISTS dbo.fn_LoanPrincipalAt;
GO
DROP TABLE IF EXISTS dbo.loan_principal_txn;
GO
DROP TABLE IF EXISTS dbo.bank_payment_voucher_history;
GO
DROP TABLE IF EXISTS dbo.bank_payment_voucher;
GO
DROP TABLE IF EXISTS dbo.loan_rate_period;
GO

-- 3. Stop new Statutory agreements being created (soft, reversible)
UPDATE dbo.service_master SET is_active = 'N' WHERE service_type_sno = (SELECT service_type_sno FROM dbo.service_type_master WHERE service_type_code = 'STATUTORY');
UPDATE dbo.service_type_master SET is_active = 'N' WHERE service_type_code = 'STATUTORY';
GO
