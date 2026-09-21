-- ============================================================
-- 85_service_po_dispatch_info.sql
--
-- backend-stpl/src/ServiceAgreement/services/ServicePoDispatch.service.js's
-- dispatchServicePo() — now also called from the new
-- sp_nt_ApproveServicePoCycle final-stage path (sql/83) — depends on
-- sp_nt_GetServicePoDispatchInfo, which was only ever introduced in
-- sql/81_service_agreement_dispatch_grn.sql. That file was never applied
-- live (confirmed), so the proc doesn't exist and dispatch has been
-- silently no-op-ing (caught by dispatchServicePo's own try/catch, logged
-- to console only) for every Service PO issued so far, old flow and new.
--
-- This adds a minimal version scoped to just what's needed now — email the
-- supplier, like a regular product PO. Deliberately NOT bringing in
-- dispatch_type/incharge_ecno routing (that's sql/81's Incharge path, out
-- of scope here) — dispatch_type is hardcoded 'S' and incharge_ecno NULL,
-- so dispatchServicePo's existing "Supplier path (default / dispatch_type
-- === 'S')" branch always runs. If dispatch_type is ever added for real
-- (sql/81 applied), this proc should be updated to read it instead of
-- hardcoding — flagging that here so it isn't missed.
--
-- agreement_sno is recovered via po_request_info.pr_basic_sno ->
-- pr_item_details.agreement_sno (set by sp_nt_IssueRecurringServicePOCycle,
-- sql/73/83) — po_request_info itself has no agreement_sno column.
-- qty/rate_amount come from po_item_details (the PO's actual line, correct
-- for both Fixed and Unfixed — for Unfixed this is the real entered value,
-- not the agreement's original approximate one).
--
-- Idempotent — safe to re-run.
-- ============================================================

IF OBJECT_ID('dbo.sp_nt_GetServicePoDispatchInfo', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetServicePoDispatchInfo;
GO
CREATE PROCEDURE dbo.sp_nt_GetServicePoDispatchInfo
    @po_basic_sno INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1
        'S' AS dispatch_type, CAST(NULL AS VARCHAR(30)) AS incharge_ecno,
        po.po_basic_sno, po.po_df_no AS po_no, po.po_date, po.required_date,
        pid.qty, pid.agreed_unit_price AS rate_amount, pid.service_sno, sm.service_name,
        sa.agreement_sno, sa.agreement_no, sa.created_by,
        k.company_name AS vendor_name, k.email AS vendor_email
    FROM dbo.po_request_info po
    JOIN dbo.po_item_details pid ON pid.po_basic_sno = po.po_basic_sno AND pid.is_active = '1'
    JOIN dbo.service_master sm ON sm.service_sno = pid.service_sno
    LEFT JOIN dbo.pr_item_details prd ON prd.pr_basic_sno = po.pr_basic_sno AND prd.agreement_sno IS NOT NULL
    LEFT JOIN dbo.service_agreement sa ON sa.agreement_sno = prd.agreement_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = po.vendor_sno
    WHERE po.po_basic_sno = @po_basic_sno;
END;
GO
