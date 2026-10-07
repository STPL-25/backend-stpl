-- ============================================================
-- ROLLBACK for sql/99_conditional_approval_engine.sql (Non_trade_Dev, applied 2026-09-26)
--
-- Restores sp_get_pr_details_for_approval to its pre-change definition (captured live
-- from Non_trade_Dev immediately before the change) and drops every object the
-- migration created. sp_approve_pr_datas was never modified, so the old approval
-- path works again as soon as the backend is pointed back at it.
--
-- WARNING: dropping approval_instance / approval_action_log deletes the approval
-- audit written since the migration (edit before/after values, forward/send-back
-- history). pr_history_data rows (A / R) are untouched and stay.
-- Run:  node sql/run_sql.mjs sql/backups/pre_conditional_approval_engine_2026-09-26_ROLLBACK.sql
-- ============================================================

IF OBJECT_ID('dbo.trg_pr_basic_info_approval_instance', 'TR') IS NOT NULL
    DROP TRIGGER dbo.trg_pr_basic_info_approval_instance;
GO
-- ── sp_get_pr_details_for_approval — PR approval queue, now hierarchy-scoped ──
CREATE OR ALTER PROCEDURE dbo.sp_get_pr_details_for_approval
    @Ecno           VARCHAR(20),
    @HierarchyJson  NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        SELECT
            vw.*
        FROM dbo.vw_PR_Basic_Info vw
        WHERE vw.current_approver_id = @Ecno
          AND vw.status = 'P'
          AND (
                @HierarchyJson IS NULL
                OR EXISTS (
                    SELECT 1
                    FROM OPENJSON(@HierarchyJson)
                    WITH (
                        com_sno INT '$.com_sno',
                        div_sno INT '$.div_sno',
                        brn_sno INT '$.brn_sno'
                    ) h
                    WHERE h.com_sno = vw.com_sno
                      AND (h.div_sno IS NULL OR h.div_sno = vw.div_sno)
                      AND (h.brn_sno IS NULL OR h.brn_sno = vw.brn_sno)
                )
              )

    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber   INT            = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT            = ERROR_SEVERITY();
        THROW;
    END CATCH
END;
GO
IF OBJECT_ID('dbo.sp_nt_GetApprovalConditionFields', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetApprovalConditionFields;
IF OBJECT_ID('dbo.sp_nt_PrApprovalContext', 'P')  IS NOT NULL DROP PROCEDURE dbo.sp_nt_PrApprovalContext;
IF OBJECT_ID('dbo.sp_nt_PrApprovalAct', 'P')      IS NOT NULL DROP PROCEDURE dbo.sp_nt_PrApprovalAct;
GO
IF OBJECT_ID('dbo.fn_pr_approval_context', 'IF')  IS NOT NULL DROP FUNCTION dbo.fn_pr_approval_context;
IF OBJECT_ID('dbo.fn_approval_next_seq', 'FN')    IS NOT NULL DROP FUNCTION dbo.fn_approval_next_seq;
IF OBJECT_ID('dbo.fn_approval_condition_met', 'FN') IS NOT NULL DROP FUNCTION dbo.fn_approval_condition_met;
GO
IF OBJECT_ID('dbo.approval_condition_field', 'U') IS NOT NULL DROP TABLE dbo.approval_condition_field;
IF OBJECT_ID('dbo.approval_action_log', 'U') IS NOT NULL DROP TABLE dbo.approval_action_log;
IF OBJECT_ID('dbo.approval_instance', 'U')   IS NOT NULL DROP TABLE dbo.approval_instance;
GO
