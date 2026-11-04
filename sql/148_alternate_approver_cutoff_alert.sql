-- ============================================================
-- 148: Bell alert to the ALTERNATE approver once a stage's cut-off (escalation_hours) has passed.
-- Database: Non_trade_Dev. Re-runnable.
-- Rollback: DROP PROCEDURE dbo.sp_nt_ClaimAlternateApproverNotices, dbo.sp_nt_MarkAlternateApproverNoticeSent;
--           DROP TABLE dbo.approval_alternate_notice_log;
--
-- Why: after the cut-off the alternate may approve (the item stays with the primary approver too, by
--   design), but nobody told the alternate - e.g. PR26270093 waited with KTM1004 past its 1 hour cut-off
--   and ED001 did not know it could act.
-- What: every 60s sweep (backend runAlternateApproverNoticeSweep) claims, per pending approval-engine
--   stage visit (instance + cycle + stage + the time it reached that stage), one notice per alternate whose
--   cut-off has passed. PurchaseRequisition + Payment (the two entity types on the engine).
--   A send back / return / restart gives the stage a new current_since, so the alternate is told again then.
-- ============================================================

IF OBJECT_ID('dbo.approval_alternate_notice_log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.approval_alternate_notice_log (
        notice_sno      INT IDENTITY(1,1) PRIMARY KEY,
        instance_id     INT          NOT NULL,
        entity_type     VARCHAR(40)  NOT NULL,
        entity_id       INT          NOT NULL,
        cycle_no        INT          NOT NULL,
        stage_seq       INT          NOT NULL,
        stage_since     DATETIME     NOT NULL,
        alternate_ecno  VARCHAR(50)  NOT NULL,
        status          VARCHAR(10)  NOT NULL CONSTRAINT DF_alt_notice_status DEFAULT 'PENDING',  -- PENDING | SENT | FAILED
        error_message   NVARCHAR(500) NULL,
        created_at      DATETIME     NOT NULL CONSTRAINT DF_alt_notice_created DEFAULT GETDATE(),
        modified_at     DATETIME     NULL,
        CONSTRAINT UQ_alt_notice UNIQUE (instance_id, cycle_no, stage_seq, stage_since, alternate_ecno)
    );
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_ClaimAlternateApproverNotices
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #due (
        instance_id INT, entity_type VARCHAR(40) COLLATE DATABASE_DEFAULT, entity_id INT, cycle_no INT, stage_seq INT,
        stage_since DATETIME, alternate_ecno VARCHAR(50) COLLATE DATABASE_DEFAULT, primary_ecno VARCHAR(50) COLLATE DATABASE_DEFAULT,
        stage_name NVARCHAR(200) COLLATE DATABASE_DEFAULT, escalation_hours INT,
        label NVARCHAR(200) COLLATE DATABASE_DEFAULT, screen VARCHAR(60) COLLATE DATABASE_DEFAULT
    );

    ;WITH cur AS (
        SELECT i.instance_id, i.entity_type, i.entity_ref_id, i.cycle_no, i.current_seq, i.current_since,
               st.value AS stage_json,
               JSON_VALUE(st.value, '$.approver_ecno') AS primary_ecno,
               ISNULL(TRY_CAST(JSON_VALUE(st.value, '$.escalation_hours') AS INT), 24) AS esc_h
        FROM dbo.approval_instance i
        CROSS APPLY OPENJSON(i.stages_json) st
        WHERE i.status = 'P' AND i.awaiting_requester = 0 AND i.current_seq IS NOT NULL AND i.current_since IS NOT NULL
          AND i.entity_type IN ('PurchaseRequisition', 'Payment')
          AND ISJSON(i.stages_json) = 1
          AND st.[key] = CAST(i.current_seq AS NVARCHAR(10))
    )
    INSERT INTO #due
    SELECT c.instance_id, c.entity_type, c.entity_ref_id, c.cycle_no, c.current_seq, c.current_since,
           LTRIM(RTRIM(a.value)), c.primary_ecno, JSON_VALUE(c.stage_json, '$.stage'), c.esc_h,
           CASE c.entity_type WHEN 'PurchaseRequisition' THEN N'PR ' + pr.pr_no ELSE N'Payment ' + ISNULL(pay.payment_no, CAST(pay.payment_sno AS VARCHAR(20))) END,
           CASE c.entity_type WHEN 'PurchaseRequisition' THEN 'PRApprovalScreen' ELSE 'PaymentApprovalScreen' END
    FROM cur c
    CROSS APPLY OPENJSON(c.stage_json, '$.alternates') a
    LEFT JOIN dbo.pr_basic_info pr ON c.entity_type = 'PurchaseRequisition' AND pr.pr_basic_sno = c.entity_ref_id
    LEFT JOIN dbo.payment_info pay ON c.entity_type = 'Payment' AND pay.payment_sno = c.entity_ref_id
    WHERE NULLIF(LTRIM(RTRIM(a.value)), '') IS NOT NULL
      AND LTRIM(RTRIM(a.value)) COLLATE DATABASE_DEFAULT <> ISNULL(c.primary_ecno, '') COLLATE DATABASE_DEFAULT
      AND DATEDIFF(MINUTE, c.current_since, GETDATE()) >= c.esc_h * 60
      AND (   (c.entity_type = 'PurchaseRequisition' AND pr.status = 'P' AND pr.is_active = 'Y')
           OR (c.entity_type = 'Payment' AND pay.status = 'Pending Approval' AND pay.is_active = 'Y'));

    CREATE TABLE #claimed (notice_sno INT PRIMARY KEY);

    -- retry the ones whose send failed, while the stage is still waiting
    UPDATE l SET status = 'PENDING', error_message = NULL, modified_at = GETDATE()
    OUTPUT inserted.notice_sno INTO #claimed (notice_sno)
    FROM dbo.approval_alternate_notice_log l
    JOIN #due d ON d.instance_id = l.instance_id AND d.cycle_no = l.cycle_no AND d.stage_seq = l.stage_seq
               AND d.stage_since = l.stage_since AND d.alternate_ecno = l.alternate_ecno
    WHERE l.status = 'FAILED';

    BEGIN TRY
        INSERT INTO dbo.approval_alternate_notice_log (instance_id, entity_type, entity_id, cycle_no, stage_seq, stage_since, alternate_ecno, status)
        OUTPUT inserted.notice_sno INTO #claimed (notice_sno)
        SELECT d.instance_id, d.entity_type, d.entity_id, d.cycle_no, d.stage_seq, d.stage_since, d.alternate_ecno, 'PENDING'
        FROM #due d
        WHERE NOT EXISTS (SELECT 1 FROM dbo.approval_alternate_notice_log l
                          WHERE l.instance_id = d.instance_id AND l.cycle_no = d.cycle_no AND l.stage_seq = d.stage_seq
                            AND l.stage_since = d.stage_since AND l.alternate_ecno = d.alternate_ecno);
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (2601, 2627) THROW;   -- a concurrent sweep owns those rows
    END CATCH

    SELECT l.notice_sno, l.entity_type, l.entity_id, l.alternate_ecno AS recipient_ecno,
           d.label, d.screen, d.stage_name, d.escalation_hours, d.stage_since,
           d.primary_ecno, COALESCE(NULLIF(LTRIM(RTRIM(e.ename)), ''), ns.full_name, d.primary_ecno) AS primary_name
    FROM #claimed c
    JOIN dbo.approval_alternate_notice_log l ON l.notice_sno = c.notice_sno
    JOIN #due d ON d.instance_id = l.instance_id AND d.cycle_no = l.cycle_no AND d.stage_seq = l.stage_seq
               AND d.stage_since = l.stage_since AND d.alternate_ecno = l.alternate_ecno
    OUTER APPLY (SELECT TOP 1 ename FROM dbo.vw_verified_employees WHERE ecno = d.primary_ecno) e
    OUTER APPLY (SELECT TOP 1 full_name FROM dbo.nt_nonstaff_login WHERE login_id = d.primary_ecno) ns
    ORDER BY l.notice_sno;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_MarkAlternateApproverNoticeSent
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.approval_alternate_notice_log
    SET status = CASE WHEN JSON_VALUE(@jsonInput, '$.status') = 'SENT' THEN 'SENT' ELSE 'FAILED' END,
        error_message = LEFT(JSON_VALUE(@jsonInput, '$.error_message'), 500),
        modified_at = GETDATE()
    WHERE notice_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.notice_sno') AS INT);
END;
GO
