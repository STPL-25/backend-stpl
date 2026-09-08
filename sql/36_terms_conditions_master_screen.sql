-- ============================================================
-- Terms & Conditions Master — sidebar registration
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : nt-frontend-stpl SideBar.tsx (reads comp/comp_img/group_id to
--            build the menu) — makes the new TermsConditionsMaster.tsx
--            screen (registered in ComponentsDatas.tsx) reachable via menu
--            navigation and grantable through the Permission Manager.
--
-- VERIFIED LIVE (2026-09-01) against 10.0.21.8/Non_Trade before writing this:
--   SELECT screen_id, screen_name, screen_code, display_order, group_id, comp, comp_img
--   FROM dbo.screens WHERE comp IN ('masters','RoleApproval','ApprovalWorkflowPage');
-- 'masters' (the generic lookup-masters grid) is group_id=1 ("Masters"),
-- screen_code='S5'. This screen lives in that same group since it's a
-- master, just with its own bespoke page instead of the generic grid.
-- Highest existing display_order at verification time was 23.
-- ============================================================

DECLARE @group_id       INT           = 1;
DECLARE @screen_code    VARCHAR(10)   = N'S5';
DECLARE @display_order  INT           = 24;
DECLARE @comp_img_value NVARCHAR(100) = N'FileText';

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'TermsConditionsMaster')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Terms & Conditions Master', @screen_code, 'TermsConditionsMaster', @comp_img_value, @group_id, @display_order, 'Y');
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.screens WHERE comp = 'TermsConditionsMaster';
--
-- This does NOT grant the screen to anyone — sp_nt_GrantScreenToUser
-- already exists (see sql/14_service_agreement_screens.sql) and requires an
-- explicit ecno + permission_ids, matching this repo's convention of never
-- guessing which users should get a new grant. Per user who needs access:
--   SELECT screen_id FROM dbo.screens WHERE comp = 'TermsConditionsMaster';
--   SELECT permission_id, permission_name FROM dbo.permissions;
--   EXEC dbo.sp_nt_GrantScreenToUser
--     @jsonInput = N'{"ecno":"<ECNO>","screen_id":<id>,"permission_ids":[<ids>]}';
-- Or grant it to a role/user through the Permission Manager UI itself once
-- this row exists (Role Approval → the new screen will now be listed).
-- ============================================================
