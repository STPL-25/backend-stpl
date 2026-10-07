-- ============================================================================
-- 118_uom_class_master.sql
--
-- UOM Class master (uom_class_master).
--
-- uom_master.uom_class has always been a free VARCHAR(30) holding one of
-- MASS / VOLUME / LENGTH / AREA / QUANTITY, with the list hard-coded in the
-- frontend (UOM_CLASS_OPTIONS in nt-frontend-stpl/src/FieldDatas/Data.tsx).
-- This gives the classes a real master so they can be maintained from the
-- Masters screen, and the UOM form's dropdown reads from it.
--
-- uom_master.uom_class is DELIBERATELY left as the class *code* string (no new
-- FK column): Product Master's same-class conversion-unit picker and the
-- grn-service unit conversion both compare that string, so nothing downstream
-- changes. Consistency is enforced instead in the procedures:
--   * sp_nt_CreateUomRecords / sp_nt_UpdateUomRecords reject a class that is
--     not an active uom_class_master code.
--   * sp_nt_UpdateUomClassRecords cascades a renamed class code onto
--     uom_master so no unit is orphaned.
--   * sp_nt_DeleteUomClassRecords (soft delete) refuses while an active UOM
--     still uses the class.
--
-- Registered as master key "UomClassMaster". Safe to re-run.
-- ============================================================================

IF OBJECT_ID('dbo.uom_class_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.uom_class_master (
        uom_class_sno  INT IDENTITY(1,1) PRIMARY KEY,
        uom_class_code VARCHAR(30)   NOT NULL,
        uom_class_name NVARCHAR(100) NOT NULL,
        is_active      CHAR(1)       NOT NULL DEFAULT 'Y',
        created_by     VARCHAR(20)   NULL,
        created_at     DATETIME      NOT NULL DEFAULT GETDATE(),
        modified_by    VARCHAR(20)   NULL,
        modified_at    DATETIME      NULL,
        CONSTRAINT UQ_uom_class_master_code UNIQUE (uom_class_code),
        CONSTRAINT UQ_uom_class_master_name UNIQUE (uom_class_name)
    );
END;
GO

-- Seed the five classes already in live use, plus any other distinct class a
-- uom_master row carries (so no existing unit is left pointing at a class that
-- is missing from the master).
IF NOT EXISTS (SELECT 1 FROM dbo.uom_class_master)
BEGIN
    INSERT INTO dbo.uom_class_master (uom_class_code, uom_class_name, created_by)
    VALUES (N'MASS',     N'Mass / Weight',   N'system'),
           (N'VOLUME',   N'Volume',          N'system'),
           (N'LENGTH',   N'Length',          N'system'),
           (N'AREA',     N'Area',            N'system'),
           (N'QUANTITY', N'Quantity / Count', N'system');

    INSERT INTO dbo.uom_class_master (uom_class_code, uom_class_name, created_by)
    SELECT DISTINCT LTRIM(RTRIM(u.uom_class)), LTRIM(RTRIM(u.uom_class)), N'system'
    FROM dbo.uom_master u
    WHERE u.uom_class IS NOT NULL AND LTRIM(RTRIM(u.uom_class)) <> ''
      AND NOT EXISTS (SELECT 1 FROM dbo.uom_class_master c WHERE c.uom_class_code = LTRIM(RTRIM(u.uom_class)));
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetUomClassRecords
AS
BEGIN
    SET NOCOUNT ON;
    SELECT uom_class_sno, uom_class_code, uom_class_name, is_active
    FROM dbo.uom_class_master
    WHERE is_active = 'Y'
    ORDER BY uom_class_sno;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateUomClassRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (uom_class_code NVARCHAR(30) '$.uom_class_code', uom_class_name NVARCHAR(100) '$.uom_class_name')
        WHERE LTRIM(RTRIM(ISNULL(uom_class_code, N''))) = N'' OR LTRIM(RTRIM(ISNULL(uom_class_name, N''))) = N''
    )
        THROW 50002, N'uom_class_code and uom_class_name are required for every row.', 1;

    -- Codes are stored upper-case: they are compared as plain strings by
    -- Product Master / GRN unit conversion.
    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (uom_class_code NVARCHAR(30) '$.uom_class_code') j
        JOIN dbo.uom_class_master m ON m.uom_class_code = UPPER(LTRIM(RTRIM(j.uom_class_code)))
    )
        THROW 50003, N'A UOM class with this code already exists.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (uom_class_name NVARCHAR(100) '$.uom_class_name') j
        JOIN dbo.uom_class_master m ON m.uom_class_name = LTRIM(RTRIM(j.uom_class_name))
    )
        THROW 50004, N'A UOM class with this name already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (uom_class_sno INT);

        INSERT INTO dbo.uom_class_master (uom_class_code, uom_class_name, is_active, created_by)
        OUTPUT INSERTED.uom_class_sno INTO @Inserted
        SELECT UPPER(LTRIM(RTRIM(uom_class_code))), LTRIM(RTRIM(uom_class_name)), 'Y', created_by
        FROM OPENJSON(@json)
        WITH (
            uom_class_code NVARCHAR(30)  '$.uom_class_code',
            uom_class_name NVARCHAR(100) '$.uom_class_name',
            created_by     VARCHAR(20)   '$.created_by'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.uom_class_master t JOIN @Inserted i ON i.uom_class_sno = t.uom_class_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateUomClassRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.uom_class_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.uom_class_master WHERE uom_class_sno = @id)
        THROW 50005, N'UOM class not found.', 1;

    DECLARE @oldCode VARCHAR(30) = (SELECT uom_class_code FROM dbo.uom_class_master WHERE uom_class_sno = @id);
    DECLARE @newCode VARCHAR(30) = UPPER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.uom_class_code'))));
    DECLARE @newName NVARCHAR(100) = LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.uom_class_name')));

    IF @newCode = '' SET @newCode = NULL;
    IF @newName = N'' SET @newName = NULL;

    IF @newCode IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.uom_class_master WHERE uom_class_code = @newCode AND uom_class_sno <> @id)
        THROW 50003, N'A UOM class with this code already exists.', 1;
    IF @newName IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.uom_class_master WHERE uom_class_name = @newName AND uom_class_sno <> @id)
        THROW 50004, N'A UOM class with this name already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.uom_class_master
        SET uom_class_code = ISNULL(@newCode, uom_class_code),
            uom_class_name = ISNULL(@newName, uom_class_name),
            modified_by    = JSON_VALUE(@jsonInput, '$.modified_by'),
            modified_at    = GETDATE()
        WHERE uom_class_sno = @id;

        -- uom_master stores the class code as a string — carry a rename across.
        IF @newCode IS NOT NULL AND @newCode <> @oldCode
            UPDATE dbo.uom_master SET uom_class = @newCode WHERE uom_class = @oldCode;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT * FROM dbo.uom_class_master WHERE uom_class_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteUomClassRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.uom_class_master WHERE uom_class_sno = @id)
        THROW 50005, N'UOM class not found.', 1;

    IF EXISTS (
        SELECT 1 FROM dbo.uom_master u
        JOIN dbo.uom_class_master c ON c.uom_class_code = u.uom_class
        WHERE c.uom_class_sno = @id AND u.is_active = 'Y'
    )
        THROW 50006, N'This UOM class is still used by active units of measurement — move or remove them first.', 1;

    UPDATE dbo.uom_class_master SET is_active = 'N', modified_at = GETDATE() WHERE uom_class_sno = @id;
    SELECT @id AS uom_class_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO

-- ── UOM procedures: only accept a class that exists in the master ───────────
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateUomRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (uom_code VARCHAR(5) '$.uom_code')
        WHERE uom_code IS NULL OR LTRIM(RTRIM(uom_code)) = ''
    )
        THROW 50001, N'uom_code is required for every row.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (uom_class VARCHAR(30) '$.uom_class') j
        WHERE NOT EXISTS (SELECT 1 FROM dbo.uom_class_master c
                          WHERE c.uom_class_code = LTRIM(RTRIM(j.uom_class)) AND c.is_active = 'Y')
    )
        THROW 50007, N'uom_class must be an active code from the UOM Class master.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (uom_sno INT);

        INSERT INTO dbo.uom_master (uom_code, uom_name, uom_class, uom_base_uom_flag, uom_con_factor, is_active, created_date)
        OUTPUT INSERTED.uom_sno INTO @Inserted
        SELECT LTRIM(RTRIM(uom_code)), LTRIM(RTRIM(uom_name)), LTRIM(RTRIM(uom_class)), LTRIM(RTRIM(uom_base_uom_flag)), uom_con_factor, 'Y', GETDATE()
        FROM OPENJSON(@json)
        WITH (
            uom_code CHAR(5) '$.uom_code',
            uom_name VARCHAR(50) '$.uom_name',
            uom_class VARCHAR(30) '$.uom_class',
            uom_base_uom_flag CHAR(1) '$.uom_base_uom_flag',
            uom_con_factor DECIMAL(18,6) '$.uom_con_factor'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.uom_master t JOIN @Inserted i ON i.uom_sno = t.uom_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateUomRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.uom_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.uom_master WHERE uom_sno = @id)
    BEGIN
        RAISERROR('UOM not found.', 16, 1);
        RETURN;
    END

    DECLARE @class VARCHAR(30) = LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.uom_class')));
    -- Unchanged class is allowed even if it has since been retired from the
    -- master; only a *new* class value has to exist there.
    IF @class IS NOT NULL AND @class <> ''
       AND @class <> ISNULL((SELECT uom_class FROM dbo.uom_master WHERE uom_sno = @id), '')
       AND NOT EXISTS (SELECT 1 FROM dbo.uom_class_master WHERE uom_class_code = @class AND is_active = 'Y')
        THROW 50007, N'uom_class must be an active code from the UOM Class master.', 1;

    UPDATE dbo.uom_master
    SET uom_code           = ISNULL(JSON_VALUE(@jsonInput, '$.uom_code'), uom_code),
        uom_name           = ISNULL(JSON_VALUE(@jsonInput, '$.uom_name'), uom_name),
        uom_class          = ISNULL(JSON_VALUE(@jsonInput, '$.uom_class'), uom_class),
        uom_base_uom_flag  = ISNULL(JSON_VALUE(@jsonInput, '$.uom_base_uom_flag'), uom_base_uom_flag),
        uom_con_factor     = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.uom_con_factor') AS DECIMAL(18,6)), uom_con_factor)
    WHERE uom_sno = @id;

    SELECT * FROM dbo.uom_master WHERE uom_sno = @id;
END
GO
