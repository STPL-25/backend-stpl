-- Rollback of sql/139: puts the UNIQUE constraint on nt_supplier_login.login_email back.
-- Fails if two logins now share an e-mail - change one of them first.
IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.nt_supplier_login') AND name = 'IX_nt_supplier_login_email')
    DROP INDEX IX_nt_supplier_login_email ON dbo.nt_supplier_login;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.nt_supplier_login') AND name = 'UQ_nt_supplier_login_email')
    ALTER TABLE dbo.nt_supplier_login ADD CONSTRAINT UQ_nt_supplier_login_email UNIQUE (login_email);
GO
