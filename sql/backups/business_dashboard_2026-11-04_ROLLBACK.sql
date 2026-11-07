-- Rollback for sql/153_business_dashboard.sql: the migration only adds one read-only procedure, so rolling back is dropping it.
-- (The Dashboard then shows an error on its "Business overview" tab until the procedure is back; the "Organisation & access" tab is unaffected.)
DROP PROCEDURE IF EXISTS dbo.sp_nt_GetBusinessDashboard;
