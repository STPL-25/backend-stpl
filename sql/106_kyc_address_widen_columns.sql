-- GST additional places of business carry long unit names/addresses that
-- overflowed the NVARCHAR(50) address columns. Widen them (all nullable, no
-- indexes on them; the insert procs read JSON via JSON_VALUE so need no change).
ALTER TABLE dbo.kyc_address_info ALTER COLUMN door_no NVARCHAR(300) NULL;
GO
ALTER TABLE dbo.kyc_address_info ALTER COLUMN street  NVARCHAR(200) NULL;
GO
ALTER TABLE dbo.kyc_address_info ALTER COLUMN area    NVARCHAR(200) NULL;
GO
ALTER TABLE dbo.kyc_address_info ALTER COLUMN taluk   NVARCHAR(200) NULL;
GO
ALTER TABLE dbo.kyc_address_info ALTER COLUMN city    NVARCHAR(200) NULL;
GO
ALTER TABLE dbo.kyc_address_info ALTER COLUMN state   NVARCHAR(200) NULL;
GO
-- Views selecting from the table keep stale column metadata otherwise (see 101).
EXEC sp_refreshview 'dbo.vw_get_all_kyc_info';
GO
EXEC sp_refreshview 'dbo.vw_get_kyc';
GO
