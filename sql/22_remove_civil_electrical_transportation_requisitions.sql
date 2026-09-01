-- ============================================================
-- Remove Civil / Electrical / Transportation requisition entry screens
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Reverses : sql/17_pr_entry_screens_activation.sql (Civil/Electrical/
--            Transportation portions only — Routine is intentionally left
--            active, it was not part of this request).
--
-- Why
-- ---
-- Product decision: there is no need for separate Civil Works / Electrical
-- Works / Transportation requisition entry points. All of those requisitions
-- go through the single PurchaseRequisitionPage instead. The three wrapper
-- pages (CivilWorksRequisitionPage.tsx, ElectricalWorksRequisitionPage.tsx,
-- TransportationRequisitionPage.tsx) and their ComponentDatas.tsx
-- registrations are being deleted from nt-frontend-stpl in the same change.
--
-- VERIFIED LIVE (2026-08-21) before writing this:
--   screen_id=26 CivilWorksRequisitionPage         is_active=Y (activated by 17)
--   screen_id=27 RoutineRequisitionPage             is_active=Y (kept active)
--   screen_id=45 ElectricalWorksRequisitionPage     is_active=Y (inserted by 17)
--   screen_id=46 TransportationRequisitionPage      is_active=Y (inserted by 17)
--   All 3 granted to KTM1148 via sp_nt_GrantScreenToUser.
--   One live PR already exists against this: pr_basic_sno=23, pr_no=PR26270011,
--   category='CIVIL', created 2026-08-21. That row (and the pr_basic_info
--   `category` column / CHECK constraint / usp_InsertPurchaseRequest mapping
--   added in 18_pr_category_and_source_invoice.sql) is left untouched here —
--   it's real submitted data, not part of "remove the entry screens".
--
-- What this does
-- ---------------
-- Deactivates (is_active='N') the 3 screen rows so they drop out of
-- sp_nt_GetUserScreensAndPermissionsJson's `scn.is_active = 'Y'` join —
-- that alone fully revokes menu visibility/access for every user (including
-- KTM1148's existing grants) without needing a separate revoke proc or
-- touching nt_user_permissions_json.screens_json. Rows are deactivated, not
-- deleted, so this is trivially reversible if the decision changes again.
-- ============================================================

UPDATE dbo.screens
SET is_active = 'N'
WHERE comp IN (
    'CivilWorksRequisitionPage',
    'ElectricalWorksRequisitionPage',
    'TransportationRequisitionPage'
)
AND is_active = 'Y';
GO

-- ============================================================
-- After running, confirm:
--   SELECT screen_id, comp, is_active FROM dbo.screens
--   WHERE comp IN ('CivilWorksRequisitionPage','ElectricalWorksRequisitionPage',
--                   'TransportationRequisitionPage','RoutineRequisitionPage');
--   -- expect the first 3 is_active='N', RoutineRequisitionPage unchanged ('Y').
-- ============================================================
