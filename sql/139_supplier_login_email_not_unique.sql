-- sql/139: a supplier portal login must not need a unique e-mail.
--
-- The supplier signs in with the supplier CODE (sp_nt_SupplierLoginByCode); login_email is only where the invite goes. But
-- nt_supplier_login.login_email carried a UNIQUE constraint, so when a second supplier shared a contact e-mail with one that already
-- had a login (one accounts person for several companies), sp_nt_CreateSupplierLogin failed on the final KYC approval. The invite
-- step swallows its errors (an approval is already committed), so the supplier got a code but no login and nobody was told.
--
-- Drops that constraint (whatever name it has in this database) and keeps a plain index for look-ups. One login per supplier stays
-- (UNIQUE kyc_basic_info_sno). Re-runnable.  Rollback: sql/backups/supplier_login_email_2026-10-24_ROLLBACK.sql (only works while no
-- two logins share an e-mail).
DECLARE @uq SYSNAME = (
    SELECT TOP 1 i.name
    FROM sys.indexes i
    JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
    JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE i.object_id = OBJECT_ID('dbo.nt_supplier_login') AND i.is_unique = 1 AND i.is_primary_key = 0 AND c.name = 'login_email'
      AND (SELECT COUNT(*) FROM sys.index_columns x WHERE x.object_id = i.object_id AND x.index_id = i.index_id) = 1);
IF @uq IS NOT NULL
BEGIN
    DECLARE @sql NVARCHAR(400) = N'ALTER TABLE dbo.nt_supplier_login DROP CONSTRAINT ' + QUOTENAME(@uq);
    EXEC (@sql);
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.nt_supplier_login') AND name = 'IX_nt_supplier_login_email')
    CREATE INDEX IX_nt_supplier_login_email ON dbo.nt_supplier_login (login_email);
GO
