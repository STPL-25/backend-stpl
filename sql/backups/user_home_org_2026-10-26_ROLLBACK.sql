-- Rollback for sql/141_user_home_org.sql (Non_trade_Dev).
-- Drops the two procedures and the screen row. Home-org values already saved on nt_sign_up (com_sno/div_sno/brn_sno/dept_sno)
-- are left in place: those columns existed before this change. To clear them too, uncomment the UPDATE at the bottom.

DROP PROCEDURE IF EXISTS dbo.sp_nt_GetUserHomeOrgList;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_SetUserHomeOrg;
GO
-- user permission rows that granted the screen hold its screen_id; remove it from them first if anyone was given it
UPDATE dbo.screens SET is_active = 'N' WHERE comp = 'UserHomeOrgPage';
GO

-- UPDATE dbo.nt_sign_up SET com_sno = NULL, div_sno = NULL, brn_sno = NULL, dept_sno = NULL;
