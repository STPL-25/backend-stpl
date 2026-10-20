-- ============================================================
-- 135_tds_section_common_master.sql   (Non_trade_Dev)
-- TDS Section moves onto the generic Masters pipeline (DynamicTable) so it looks and behaves like every other master:
--   * tds_section_sno  - surrogate int PK the generic table needs (section_code stays the unique business key)
--   * sp_nt_GetTdsSectionRecords / Create / Update / Delete (Delete = soft, is_active = 'N')
-- Same table as the Payment screen TDS dropdown (grn-service sql/44, 60, 62). Re-runnable.
-- ============================================================
IF COL_LENGTH('dbo.tds_section_master', 'tds_section_sno') IS NULL
    ALTER TABLE dbo.tds_section_master ADD tds_section_sno INT IDENTITY(1,1) NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_tds_section_master_sno' AND object_id = OBJECT_ID('dbo.tds_section_master'))
    CREATE UNIQUE INDEX UX_tds_section_master_sno ON dbo.tds_section_master (tds_section_sno);
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetTdsSectionRecords
AS
BEGIN
    SET NOCOUNT ON;
    SELECT tds_section_sno, section_code, description, applies_to, rate_individual, rate_other, rate_no_pan,
           single_threshold, annual_threshold, excess_only, is_goods_default, is_active
    FROM dbo.tds_section_master
    WHERE is_active = 'Y'
    ORDER BY CASE applies_to WHEN 'Service' THEN 1 WHEN 'Product' THEN 2 ELSE 3 END, section_code;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateTdsSectionRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 50000, N'Invalid JSON payload provided.', 1;
    DECLARE @c VARCHAR(10) = UPPER(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.section_code'))), '')),
            @d NVARCHAR(150) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.description'))), ''),
            @ap VARCHAR(7) = ISNULL(NULLIF(JSON_VALUE(@jsonInput, '$.applies_to'), ''), 'Both'),
            @ri DECIMAL(6,3) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_individual') AS DECIMAL(6,3)),
            @ro DECIMAL(6,3) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_other') AS DECIMAL(6,3)),
            @rn DECIMAL(6,3) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_no_pan') AS DECIMAL(6,3)), 20),
            @st DECIMAL(18,2) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.single_threshold') AS DECIMAL(18,2)), 0),
            @at DECIMAL(18,2) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.annual_threshold') AS DECIMAL(18,2)), 0),
            @ex CHAR(1) = CASE WHEN JSON_VALUE(@jsonInput, '$.excess_only') = 'Y' THEN 'Y' ELSE 'N' END,
            @gd CHAR(1) = CASE WHEN JSON_VALUE(@jsonInput, '$.is_goods_default') = 'Y' THEN 'Y' ELSE 'N' END,
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.created_by');
    IF @c IS NULL OR @d IS NULL OR @ri IS NULL OR @ro IS NULL
        THROW 59001, N'section_code, description, rate_individual and rate_other are required.', 1;
    IF @ap NOT IN ('Service', 'Product', 'Both') THROW 59003, N'applies_to must be Service, Product or Both.', 1;
    IF EXISTS (SELECT 1 FROM dbo.tds_section_master WHERE section_code = @c AND is_active = 'Y')
        THROW 59002, N'A TDS section with this code already exists.', 1;

    IF EXISTS (SELECT 1 FROM dbo.tds_section_master WHERE section_code = @c)   -- previously deleted: bring it back with the new values
    BEGIN
        UPDATE dbo.tds_section_master SET description = @d, applies_to = @ap, rate_individual = @ri, rate_other = @ro, rate_no_pan = @rn,
               single_threshold = @st, annual_threshold = @at, excess_only = @ex, is_active = 'Y', modified_by = @by, modified_at = GETDATE()
        WHERE section_code = @c;
    END
    ELSE
        INSERT INTO dbo.tds_section_master (section_code, description, applies_to, rate_individual, rate_other, rate_no_pan,
                                            single_threshold, annual_threshold, excess_only, is_active, modified_by)
        VALUES (@c, @d, @ap, @ri, @ro, @rn, @st, @at, @ex, 'Y', @by);

    IF @gd = 'Y'
    BEGIN
        UPDATE dbo.tds_section_master SET is_goods_default = 'N' WHERE section_code <> @c AND is_goods_default = 'Y';
        UPDATE dbo.tds_section_master SET is_goods_default = 'Y' WHERE section_code = @c;
    END
    SELECT * FROM dbo.tds_section_master WHERE section_code = @c;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateTdsSectionRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.tds_section_sno') AS INT);
    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.tds_section_master WHERE tds_section_sno = @id)
    BEGIN RAISERROR('TDS section not found.', 16, 1); RETURN; END

    DECLARE @ap VARCHAR(7) = NULLIF(JSON_VALUE(@jsonInput, '$.applies_to'), ''),
            @gd CHAR(1) = CASE WHEN JSON_VALUE(@jsonInput, '$.is_goods_default') IN ('Y', 'N') THEN JSON_VALUE(@jsonInput, '$.is_goods_default') END,
            @ex CHAR(1) = CASE WHEN JSON_VALUE(@jsonInput, '$.excess_only') IN ('Y', 'N') THEN JSON_VALUE(@jsonInput, '$.excess_only') END;
    IF @ap IS NOT NULL AND @ap NOT IN ('Service', 'Product', 'Both') THROW 59003, N'applies_to must be Service, Product or Both.', 1;

    UPDATE dbo.tds_section_master SET
        description      = ISNULL(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.description'))), ''), description),
        applies_to       = ISNULL(@ap, applies_to),
        rate_individual  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_individual') AS DECIMAL(6,3)), rate_individual),
        rate_other       = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_other') AS DECIMAL(6,3)), rate_other),
        rate_no_pan      = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_no_pan') AS DECIMAL(6,3)), rate_no_pan),
        single_threshold = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.single_threshold') AS DECIMAL(18,2)), single_threshold),
        annual_threshold = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.annual_threshold') AS DECIMAL(18,2)), annual_threshold),
        excess_only      = ISNULL(@ex, excess_only),
        modified_by      = JSON_VALUE(@jsonInput, '$.modified_by'),
        modified_at      = GETDATE()
    WHERE tds_section_sno = @id;

    IF @gd = 'Y'
    BEGIN
        UPDATE dbo.tds_section_master SET is_goods_default = 'N' WHERE tds_section_sno <> @id AND is_goods_default = 'Y';
        UPDATE dbo.tds_section_master SET is_goods_default = 'Y' WHERE tds_section_sno = @id;
    END
    ELSE IF @gd = 'N'
        UPDATE dbo.tds_section_master SET is_goods_default = 'N' WHERE tds_section_sno = @id;

    SELECT * FROM dbo.tds_section_master WHERE tds_section_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteTdsSectionRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.tds_section_master WHERE tds_section_sno = @id)
    BEGIN RAISERROR('TDS section not found.', 16, 1); RETURN; END
    -- the goods-default section drives the pending-payment estimate: another section must become the default first
    IF EXISTS (SELECT 1 FROM dbo.tds_section_master WHERE tds_section_sno = @id AND is_goods_default = 'Y')
        THROW 59004, N'This is the default goods section. Make another section the goods default before deleting it.', 1;
    UPDATE dbo.tds_section_master SET is_active = 'N', modified_at = GETDATE() WHERE tds_section_sno = @id;
    SELECT @id AS tds_section_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO
