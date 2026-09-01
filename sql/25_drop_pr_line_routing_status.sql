-- ============================================================
-- Drops sp_nt_GetPrLineRoutingStatus (added in 19_pr_line_routing_status.sql).
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- The "Line Routing Status" panel it backed was removed from the Purchase
-- Team page (PurchaseTeamPage.tsx) along with the GET
-- /api/pr/getPrLineRoutingStatus/:pr_basic_sno route/controller/service/
-- repository method in backend-stpl/src/PR/ — nothing calls this SP anymore.
-- ============================================================

IF OBJECT_ID('dbo.sp_nt_GetPrLineRoutingStatus', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPrLineRoutingStatus;
GO
