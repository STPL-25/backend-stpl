-- ============================================================
-- ROLLBACK for backend-stpl 138_payment_bank_master.sql   (Non_trade_Dev)
-- Drops the four procedures of the Payment Bank master (list, create, update, delete). The table payment_bank_master is LEFT IN PLACE:
-- it holds the company's bank accounts - drop it by hand only when they are no longer wanted.
-- The master stays registered in the app code (CommonMasterRepo.js, masterValidation.js, FieldDatas/Data.tsx); with the procedures gone
-- its Masters tile shows an error until that code is taken out as well.
-- Run grn-service sql/backups/payment_bank_file_2026-10-22_ROLLBACK.sql FIRST (the run procedures read this table).
-- Run: cd backend-stpl && node sql/run_sql.mjs sql/backups/payment_bank_master_2026-10-22_ROLLBACK.sql
-- ============================================================
GO

DROP PROCEDURE IF EXISTS dbo.sp_nt_GetPaymentBankRecords;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_CreatePaymentBankRecords;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_UpdatePaymentBankRecords;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_DeletePaymentBankRecords;
GO
