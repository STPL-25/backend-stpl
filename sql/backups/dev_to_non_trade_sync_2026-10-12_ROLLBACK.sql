-- Rollback for the 2026-10-12 Dev -> Non_Trade sync (run against Non_Trade)
DROP PROCEDURE IF EXISTS dbo.sp_kyc_verification_find_valid;
DROP PROCEDURE IF EXISTS dbo.sp_kyc_verification_save;
DROP PROCEDURE IF EXISTS dbo.sp_kyc_verification_link_to_kyc;
DROP PROCEDURE IF EXISTS dbo.sp_kyc_verification_sync_basic_info;
DROP PROCEDURE IF EXISTS dbo.sp_kyc_verification_find_live_kyc;
DROP PROCEDURE IF EXISTS dbo.sp_kyc_verification_latest_certificate_url;
DROP PROCEDURE IF EXISTS dbo.sp_kyc_verification_get_by_kyc;
GO
ALTER TABLE dbo.subcategory_master DROP CONSTRAINT CK_subcategory_master_stock_type;
ALTER TABLE dbo.subcategory_master WITH CHECK ADD CONSTRAINT CK_subcategory_master_stock_type CHECK ([subcat_stock_type]='Non-Regular' OR [subcat_stock_type]='Regular');
