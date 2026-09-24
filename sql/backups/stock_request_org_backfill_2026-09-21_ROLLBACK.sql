-- ROLLBACK for grn-service/sql/36_backfill_stock_request_org.sql (Non_Trade, 2026-09-21).
-- All 30 rows below were com/div/brn/dept = NULL before the backfill (all Source = 'Manual').
UPDATE dbo.nt_stock_requests
SET com_sno = NULL, div_sno = NULL, brn_sno = NULL, dept_sno = NULL
WHERE source_type = 'Manual'
  AND request_sno IN (1,2,3,4,5,6,7,8,9,10,11,12,13,15,102,103,104,105,106,107,108,109,111,112,113,114,115,116,117,118);
-- Note: undoing this re-hides these rows from the Store Issue page (org filter).
