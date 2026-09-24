-- ROLLBACK for grn-service/sql/36_backfill_stock_request_org.sql on Non_trade_Dev (2026-09-21).
-- All 29 rows below were com/div/brn/dept = NULL before the backfill (all Source = 'Manual').
-- The pre-fix sp_nt_CreateStockRequest was identical to the Non_Trade one:
--   see pre_stock_request_org_fix_2026-09-21_ROLLBACK_sp_nt_CreateStockRequest.sql
UPDATE dbo.nt_stock_requests
SET com_sno = NULL, div_sno = NULL, brn_sno = NULL, dept_sno = NULL
WHERE source_type = 'Manual'
  AND request_sno IN (3,4,5,6,7,8,9,10,11,12,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32);
