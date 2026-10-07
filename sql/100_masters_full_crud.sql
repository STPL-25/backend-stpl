-- ============================================================================
-- 100_masters_full_crud.sql
--
-- Masters screen (generic DynamicTable + /api/common_master pipeline) had
-- three compounding bugs across every visible master (Company, Division,
-- Branch, Dept, GST State, Screen, Screen Permission, Workflow, Priority,
-- Product Category, Product Sub Category, Product, UOM, Transporter, Bank
-- Account Type, Warehouse Location, Designation, Supplier Category, Payment
-- Mode, Service Type, Service, Recurrence Cadence):
--
--   1. Edit/Delete never reached a stored procedure at all (frontend URL bug,
--      fixed in nt-frontend-stpl, not this file).
--   2. `updateProcedureMap`/`deleteProcedureMap` in CommonMasterRepo.js only
--      resolved for TransportMaster — every other master had no Update/Delete
--      procedure to call in the first place. This file adds them.
--   3. Excel bulk import posts a JSON ARRAY of rows to the same create
--      endpoint used for single Add. Most create procedures extracted fields
--      with JSON_VALUE(@jsonInput, '$.field'), which only works against a
--      single JSON *object* — given an array it reads back NULL for every
--      field, so bulk import either THROWs "field is required" (most
--      masters) or, for the few using an OPENJSON bulk INSERT...SELECT
--      pattern guarded by the same single-object pre-check, silently inserts
--      zero rows while still reporting success (UomMaster, GSTStateCodeMaster,
--      AcYearMaster, ScreenMaster, ScreenPermission). This file rewrites every
--      affected create procedure to normalize a single object into a
--      1-element array up front (the pattern already used correctly by
--      sp_nt_CreateProductRecord, which is untouched here) and to return the
--      real inserted row(s) instead of a synthetic {Status,Message} wrapper,
--      so the frontend can append real data instead of corrupting its table
--      state until the next socket refetch quietly fixes it.
--
-- Convention followed throughout (matches the pre-existing
-- sp_nt_UpdateTransportRecords/sp_nt_DeleteTransportRecords, the only master
-- that already had working Update/Delete):
--   - Update resolves @id from $.id (always present — CommonMasterController
--     injects it from the URL's :id) and does a partial
--     `col = ISNULL(JSON_VALUE(...), col)` update, then SELECTs the full
--     current row back.
--   - Delete is a SOFT delete (flips the table's active-flag column to 'N')
--     — every visible master's GET procedure already filters
--     `WHERE is_active/cat_active/subcat_active/prod_active = 'Y'`, and a
--     soft delete avoids FK-cascade risk on rows other masters reference.
--   - Create normalizes @jsonInput into an array, validates every row
--     set-based (OPENJSON, not a root-level JSON_VALUE), bulk-inserts with
--     OUTPUT, and returns the real inserted rows.
--
-- Safe to re-run: every object uses CREATE OR ALTER.
-- ============================================================================


-- ============================================================================
-- UomMaster (uom_master: uom_sno PK, is_active)
-- ============================================================================
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

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteUomRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.uom_master WHERE uom_sno = @id)
    BEGIN
        RAISERROR('UOM not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.uom_master SET is_active = 'N' WHERE uom_sno = @id;
    SELECT @id AS uom_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- GSTStateCodeMaster (gst_master: gst_sno PK, is_active)
-- ============================================================================
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateGstStateRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (gst_state_un_name VARCHAR(50) '$.gst_state_un_name')
        WHERE gst_state_un_name IS NULL OR LTRIM(RTRIM(gst_state_un_name)) = ''
    )
        THROW 50001, N'State/Un name is required for every row.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (gst_sno INT);

        INSERT INTO dbo.gst_master (gst_state_un_name, gst_code, is_active, created_date, gst_alpha_code)
        OUTPUT INSERTED.gst_sno INTO @Inserted
        SELECT LTRIM(RTRIM(gst_state_un_name)), LTRIM(RTRIM(gst_code)), 'Y', GETDATE(), LTRIM(RTRIM(gst_alpha_code))
        FROM OPENJSON(@json)
        WITH (
            gst_state_un_name VARCHAR(50) '$.gst_state_un_name',
            gst_code VARCHAR(10) '$.gst_code',
            gst_alpha_code VARCHAR(5) '$.gst_alpha_code'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.gst_master t JOIN @Inserted i ON i.gst_sno = t.gst_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateGstStateRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.gst_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.gst_master WHERE gst_sno = @id)
    BEGIN
        RAISERROR('GST State record not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.gst_master
    SET gst_state_un_name = ISNULL(JSON_VALUE(@jsonInput, '$.gst_state_un_name'), gst_state_un_name),
        gst_code           = ISNULL(JSON_VALUE(@jsonInput, '$.gst_code'), gst_code),
        gst_alpha_code     = ISNULL(JSON_VALUE(@jsonInput, '$.gst_alpha_code'), gst_alpha_code)
    WHERE gst_sno = @id;

    SELECT * FROM dbo.gst_master WHERE gst_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteGstStateRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.gst_master WHERE gst_sno = @id)
    BEGIN
        RAISERROR('GST State record not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.gst_master SET is_active = 'N' WHERE gst_sno = @id;
    SELECT @id AS gst_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- PriorityMaster (priority_master: priority_sno PK, is_active)
-- Create was already bulk-safe (no root-level pre-check) — only needs to
-- return real rows instead of the Status/Message wrapper.
-- ============================================================================
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreatePriorityRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (priority_name VARCHAR(50) '$.priority_name')
        WHERE priority_name IS NULL OR LTRIM(RTRIM(priority_name)) = ''
    )
        THROW 50001, N'priority_name is required for every row.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (priority_sno INT);

        INSERT INTO dbo.priority_master (priority_name, priority_desc, is_active)
        OUTPUT INSERTED.priority_sno INTO @Inserted
        SELECT LTRIM(RTRIM(priority_name)), LTRIM(RTRIM(priority_desc)), 'Y'
        FROM OPENJSON(@json)
        WITH (
            priority_name VARCHAR(50) '$.priority_name',
            priority_desc VARCHAR(50) '$.priority_desc'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.priority_master t JOIN @Inserted i ON i.priority_sno = t.priority_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdatePriorityRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.priority_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.priority_master WHERE priority_sno = @id)
    BEGIN
        RAISERROR('Priority not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.priority_master
    SET priority_name = ISNULL(JSON_VALUE(@jsonInput, '$.priority_name'), priority_name),
        priority_desc = ISNULL(JSON_VALUE(@jsonInput, '$.priority_desc'), priority_desc)
    WHERE priority_sno = @id;

    SELECT * FROM dbo.priority_master WHERE priority_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeletePriorityRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.priority_master WHERE priority_sno = @id)
    BEGIN
        RAISERROR('Priority not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.priority_master SET is_active = 'N' WHERE priority_sno = @id;
    SELECT @id AS priority_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- ScreenMaster (screens: screen_id PK, is_active). screen_code stays
-- auto-generated ('S'+seq) and is not editable from Update.
-- ============================================================================
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateScreenRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (screen_name VARCHAR(100) '$.screen_name')
        WHERE screen_name IS NULL OR LTRIM(RTRIM(screen_name)) = ''
    )
        THROW 50001, N'Screen name is required for every row.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @NextScreenNo INT;
        SELECT @NextScreenNo = ISNULL(MAX(CAST(SUBSTRING(screen_code, 2, LEN(screen_code)) AS INT)), 0)
        FROM dbo.screens
        WHERE LEFT(screen_code, 1) = 'S' AND ISNUMERIC(SUBSTRING(screen_code, 2, LEN(screen_code))) = 1;

        DECLARE @Rows TABLE (rn INT IDENTITY(1,1), screen_name VARCHAR(100), screen_code VARCHAR(10), parent_screen_id INT, display_order INT);
        INSERT INTO @Rows (screen_name, screen_code, parent_screen_id, display_order)
        SELECT
            LTRIM(RTRIM(screen_name)),
            CASE WHEN screen_code IS NULL OR LTRIM(RTRIM(screen_code)) = '' THEN NULL ELSE LTRIM(RTRIM(screen_code)) END,
            parent_screen_id,
            display_order
        FROM OPENJSON(@json)
        WITH (
            screen_name VARCHAR(100) '$.screen_name',
            screen_code VARCHAR(10) '$.screen_code',
            parent_screen_id INT '$.parent_screen_id',
            display_order INT '$.display_order'
        );

        UPDATE @Rows
        SET screen_code = 'S' + CAST(@NextScreenNo + rn AS VARCHAR(10))
        WHERE screen_code IS NULL;

        DECLARE @Inserted TABLE (screen_id INT);

        INSERT INTO dbo.screens (screen_name, screen_code, parent_screen_id, is_active, created_date, display_order)
        OUTPUT INSERTED.screen_id INTO @Inserted
        SELECT screen_name, screen_code, parent_screen_id, 'Y', GETDATE(), display_order
        FROM @Rows
        ORDER BY rn;

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.screens t JOIN @Inserted i ON i.screen_id = t.screen_id;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateScreenRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.screen_id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.screens WHERE screen_id = @id)
    BEGIN
        RAISERROR('Screen not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.screens
    SET screen_name      = ISNULL(JSON_VALUE(@jsonInput, '$.screen_name'), screen_name),
        parent_screen_id = TRY_CAST(JSON_VALUE(@jsonInput, '$.parent_screen_id') AS INT),
        display_order    = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.display_order') AS INT), display_order)
    WHERE screen_id = @id;

    SELECT * FROM dbo.screens WHERE screen_id = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteScreenRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.screens WHERE screen_id = @id)
    BEGIN
        RAISERROR('Screen not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.screens SET is_active = 'N' WHERE screen_id = @id;
    SELECT @id AS screen_id, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- ScreenPermission (permissions: permission_id PK, is_active). permission_code
-- stays auto-generated ('P'+seq) and is not editable from Update.
-- ============================================================================
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreatePermissionRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (permission_name NVARCHAR(255) '$.permission_name')
        WHERE permission_name IS NULL OR LTRIM(RTRIM(permission_name)) = ''
    )
        THROW 50001, N'permission_name is required for every row.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @NextPermNo INT;
        SELECT @NextPermNo = ISNULL(MAX(TRY_CAST(SUBSTRING(permission_code, 2, LEN(permission_code)) AS INT)), 0)
        FROM dbo.permissions
        WHERE LEFT(permission_code, 1) = 'P' AND ISNUMERIC(SUBSTRING(permission_code, 2, LEN(permission_code))) = 1;

        DECLARE @Rows TABLE (rn INT IDENTITY(1,1), permission_name NVARCHAR(255), permission_code VARCHAR(20), permission_description NVARCHAR(MAX));
        INSERT INTO @Rows (permission_name, permission_code, permission_description)
        SELECT
            LTRIM(RTRIM(permission_name)),
            CASE WHEN permission_code IS NULL OR LTRIM(RTRIM(permission_code)) = '' THEN NULL ELSE LTRIM(RTRIM(permission_code)) END,
            permission_description
        FROM OPENJSON(@json)
        WITH (
            permission_name NVARCHAR(255) '$.permission_name',
            permission_code NVARCHAR(50) '$.permission_code',
            permission_description NVARCHAR(MAX) '$.permission_description'
        );

        UPDATE @Rows
        SET permission_code = 'P' + CAST(@NextPermNo + rn AS VARCHAR(10))
        WHERE permission_code IS NULL;

        DECLARE @Inserted TABLE (permission_id INT);

        INSERT INTO dbo.permissions (permission_name, permission_code, permission_description, is_active)
        OUTPUT INSERTED.permission_id INTO @Inserted
        SELECT permission_name, permission_code, permission_description, 'Y'
        FROM @Rows
        ORDER BY rn;

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.permissions t JOIN @Inserted i ON i.permission_id = t.permission_id;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdatePermissionRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.permission_id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.permissions WHERE permission_id = @id)
    BEGIN
        RAISERROR('Permission not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.permissions
    SET permission_name        = ISNULL(JSON_VALUE(@jsonInput, '$.permission_name'), permission_name),
        permission_description = ISNULL(JSON_VALUE(@jsonInput, '$.permission_description'), permission_description)
    WHERE permission_id = @id;

    SELECT * FROM dbo.permissions WHERE permission_id = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeletePermissionRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.permissions WHERE permission_id = @id)
    BEGIN
        RAISERROR('Permission not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.permissions SET is_active = 'N' WHERE permission_id = @id;
    SELECT @id AS permission_id, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- WorkflowMaster (approval_workflow_master: workflow_id PK, is_active).
-- Create was already bulk-safe — only needs to return real rows.
-- ============================================================================
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateWorkflowMaster]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (workflow_name VARCHAR(200) '$.workflow_name')
        WHERE workflow_name IS NULL OR LTRIM(RTRIM(workflow_name)) = ''
    )
        THROW 50001, N'workflow_name is required for every row.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (workflow_id INT);

        INSERT INTO dbo.approval_workflow_master (workflow_name, workflow_code, entity_type, [description], is_active, created_by, created_at)
        OUTPUT INSERTED.workflow_id INTO @Inserted
        SELECT
            LTRIM(RTRIM(workflow_name)),
            LTRIM(RTRIM(workflow_code)),
            LTRIM(RTRIM(entity_type)),
            [description],
            ISNULL(is_active, 'Y'),
            created_by,
            ISNULL(created_at, GETDATE())
        FROM OPENJSON(@json)
        WITH (
            workflow_name  VARCHAR(200) '$.workflow_name',
            workflow_code  VARCHAR(100) '$.workflow_code',
            entity_type    VARCHAR(100) '$.entity_type',
            [description]  NVARCHAR(MAX) '$.description',
            is_active      CHAR(1)       '$.is_active',
            created_by     INT           '$.created_by',
            created_at     DATETIME      '$.created_at'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.approval_workflow_master t JOIN @Inserted i ON i.workflow_id = t.workflow_id;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateWorkflowMaster
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.workflow_id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.approval_workflow_master WHERE workflow_id = @id)
    BEGIN
        RAISERROR('Workflow not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.approval_workflow_master
    SET workflow_name = ISNULL(JSON_VALUE(@jsonInput, '$.workflow_name'), workflow_name),
        workflow_code = ISNULL(JSON_VALUE(@jsonInput, '$.workflow_code'), workflow_code),
        entity_type   = ISNULL(JSON_VALUE(@jsonInput, '$.entity_type'), entity_type),
        [description] = ISNULL(JSON_VALUE(@jsonInput, '$.description'), [description]),
        modified_by   = JSON_VALUE(@jsonInput, '$.modified_by'),
        modified_at   = GETDATE()
    WHERE workflow_id = @id;

    SELECT * FROM dbo.approval_workflow_master WHERE workflow_id = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteWorkflowMaster
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.approval_workflow_master WHERE workflow_id = @id)
    BEGIN
        RAISERROR('Workflow not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.approval_workflow_master SET is_active = 'N', modified_at = GETDATE() WHERE workflow_id = @id;
    SELECT @id AS workflow_id, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- ProductCategoryMaster (category_master: cat_sno PK, cat_active)
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (cat_name NVARCHAR(50) '$.cat_name', cat_notes NVARCHAR(500) '$.cat_notes')
        WHERE cat_name IS NULL OR LTRIM(RTRIM(cat_name)) = '' OR cat_notes IS NULL OR LTRIM(RTRIM(cat_notes)) = ''
    )
        THROW 50001, N'cat_name and cat_notes (product code prefix) are required for every row.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (cat_name NVARCHAR(50) '$.cat_name') j
        JOIN dbo.category_master m ON m.cat_name = j.cat_name AND m.cat_active = 'Y'
    )
        THROW 50002, N'A category with this name already exists.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (cat_notes NVARCHAR(500) '$.cat_notes') j
        JOIN dbo.category_master m ON m.cat_notes = j.cat_notes AND m.cat_active = 'Y'
    )
        THROW 50003, N'A category with this code prefix already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (cat_sno INT);

        INSERT INTO dbo.category_master (cat_name, cat_description, cat_notes, cat_active, cat_created_date, cat_created_by)
        OUTPUT INSERTED.cat_sno INTO @Inserted
        SELECT cat_name, cat_description, cat_notes, 'Y', GETDATE(), created_by
        FROM OPENJSON(@json)
        WITH (
            cat_name        NVARCHAR(50)  '$.cat_name',
            cat_description NVARCHAR(100) '$.cat_description',
            cat_notes       NVARCHAR(500) '$.cat_notes',
            created_by      VARCHAR(20)   '$.created_by'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.category_master t JOIN @Inserted i ON i.cat_sno = t.cat_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.cat_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.category_master WHERE cat_sno = @id)
    BEGIN
        RAISERROR('Category not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.category_master
    SET cat_name          = ISNULL(JSON_VALUE(@jsonInput, '$.cat_name'), cat_name),
        cat_notes         = ISNULL(JSON_VALUE(@jsonInput, '$.cat_notes'), cat_notes),
        cat_description   = ISNULL(JSON_VALUE(@jsonInput, '$.cat_description'), cat_description),
        cat_modified_date = GETDATE(),
        cat_modified_by   = JSON_VALUE(@jsonInput, '$.modified_by')
    WHERE cat_sno = @id;

    SELECT * FROM dbo.category_master WHERE cat_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.category_master WHERE cat_sno = @id)
    BEGIN
        RAISERROR('Category not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.category_master SET cat_active = 'N', cat_modified_date = GETDATE() WHERE cat_sno = @id;
    SELECT @id AS cat_sno, 'N' AS cat_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- ProductSubCategoryMaster (subcategory_master: subcat_sno PK, subcat_active)
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateSubCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (cat_sno INT '$.cat_sno', subcat_name NVARCHAR(50) '$.subcat_name')
        WHERE cat_sno IS NULL OR subcat_name IS NULL OR LTRIM(RTRIM(subcat_name)) = ''
    )
        THROW 50002, N'cat_sno and subcat_name are required for every row.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json)
        WITH (subcat_stock_type VARCHAR(20) '$.subcat_stock_type')
        WHERE ISNULL(NULLIF(subcat_stock_type, ''), 'Regular') NOT IN ('Regular', 'Non-Regular', 'Perishable')
    )
        THROW 50005, N'subcat_stock_type must be Regular, Non-Regular or Perishable.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json)
        WITH (subcat_stock_type VARCHAR(20) '$.subcat_stock_type', perishable_days INT '$.perishable_days')
        WHERE ISNULL(NULLIF(subcat_stock_type, ''), 'Regular') = 'Perishable' AND (perishable_days IS NULL OR perishable_days <= 0)
    )
        THROW 50006, N'perishable_days is required and must be greater than zero when subcat_stock_type is Perishable.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (cat_sno INT '$.cat_sno') j
        LEFT JOIN dbo.category_master cm ON cm.cat_sno = j.cat_sno AND cm.cat_active = 'Y'
        WHERE cm.cat_sno IS NULL
    )
        THROW 50003, N'Category not found.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (cat_sno INT '$.cat_sno', subcat_name NVARCHAR(50) '$.subcat_name') j
        JOIN dbo.subcategory_master m ON m.cat_sno = j.cat_sno AND m.subcat_name = j.subcat_name AND m.subcat_active = 'Y'
    )
        THROW 50004, N'A sub category with this name already exists under the selected category.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (subcat_sno INT);

        INSERT INTO dbo.subcategory_master (cat_sno, subcat_name, subcat_description, subcat_notes, subcat_stock_type, perishable_days, subcat_active, subcat_created_date, subcat_created_by)
        OUTPUT INSERTED.subcat_sno INTO @Inserted
        SELECT
            cat_sno, subcat_name, subcat_description, subcat_notes,
            ISNULL(NULLIF(subcat_stock_type, ''), 'Regular'),
            CASE WHEN ISNULL(NULLIF(subcat_stock_type, ''), 'Regular') = 'Perishable' THEN perishable_days ELSE NULL END,
            'Y', GETDATE(), created_by
        FROM OPENJSON(@json)
        WITH (
            cat_sno            INT           '$.cat_sno',
            subcat_name        NVARCHAR(50)  '$.subcat_name',
            subcat_description NVARCHAR(100) '$.subcat_description',
            subcat_notes       NVARCHAR(500) '$.subcat_notes',
            subcat_stock_type  VARCHAR(20)   '$.subcat_stock_type',
            perishable_days    INT           '$.perishable_days',
            created_by         VARCHAR(20)   '$.created_by'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.subcategory_master t JOIN @Inserted i ON i.subcat_sno = t.subcat_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateSubCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.subcat_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.subcategory_master WHERE subcat_sno = @id)
    BEGIN
        RAISERROR('Sub category not found.', 16, 1);
        RETURN;
    END

    DECLARE @stock_type VARCHAR(20) = ISNULL(JSON_VALUE(@jsonInput, '$.subcat_stock_type'), (SELECT subcat_stock_type FROM dbo.subcategory_master WHERE subcat_sno = @id));
    DECLARE @perishable_days INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.perishable_days') AS INT);

    UPDATE dbo.subcategory_master
    SET cat_sno             = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.cat_sno') AS INT), cat_sno),
        subcat_name         = ISNULL(JSON_VALUE(@jsonInput, '$.subcat_name'), subcat_name),
        subcat_description  = ISNULL(JSON_VALUE(@jsonInput, '$.subcat_description'), subcat_description),
        subcat_notes        = ISNULL(JSON_VALUE(@jsonInput, '$.subcat_notes'), subcat_notes),
        subcat_stock_type   = @stock_type,
        perishable_days     = CASE WHEN @stock_type = 'Perishable' THEN ISNULL(@perishable_days, perishable_days) ELSE NULL END,
        subcat_modified_date = GETDATE(),
        subcat_modified_by   = JSON_VALUE(@jsonInput, '$.modified_by')
    WHERE subcat_sno = @id;

    SELECT * FROM dbo.subcategory_master WHERE subcat_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteSubCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.subcategory_master WHERE subcat_sno = @id)
    BEGIN
        RAISERROR('Sub category not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.subcategory_master SET subcat_active = 'N', subcat_modified_date = GETDATE() WHERE subcat_sno = @id;
    SELECT @id AS subcat_sno, 'N' AS subcat_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- ProductMaster (product_master: prod_sno PK, prod_active). Create SP
-- (sp_nt_CreateProductRecord) is already bulk-safe and untouched — only
-- Update/Delete are new. Category/product-code regeneration on category
-- change is intentionally out of scope; Update only touches the columns the
-- Edit form actually exposes.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateProductRecord
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.prod_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.product_master WHERE prod_sno = @id)
    BEGIN
        RAISERROR('Product not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.product_master
    SET cat_sno              = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.cat_sno') AS INT), cat_sno),
        subcat_sno           = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.subcat_sno') AS INT), subcat_sno),
        prod_name            = ISNULL(JSON_VALUE(@jsonInput, '$.prod_name'), prod_name),
        prod_description     = ISNULL(JSON_VALUE(@jsonInput, '$.prod_description'), prod_description),
        prod_hsn_code        = ISNULL(JSON_VALUE(@jsonInput, '$.hsn_code'), prod_hsn_code),
        uom_sno              = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.uom_sno') AS INT), uom_sno),
        prod_uom_con_factor  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.prod_uom_con_factor') AS DECIMAL(18,6)), prod_uom_con_factor),
        prod_uom_con_uom_sno = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.prod_uom_con_uom_sno') AS INT), prod_uom_con_uom_sno),
        prod_modified_date   = GETDATE(),
        prod_modified_by     = JSON_VALUE(@jsonInput, '$.modified_by')
    WHERE prod_sno = @id;

    SELECT * FROM dbo.product_master WHERE prod_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteProductRecord
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.product_master WHERE prod_sno = @id)
    BEGIN
        RAISERROR('Product not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.product_master SET prod_active = 'N', prod_modified_date = GETDATE() WHERE prod_sno = @id;
    SELECT @id AS prod_sno, 'N' AS prod_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- TransportMaster (nt_transport_master). Update/Delete already exist and are
-- correct (sp_nt_UpdateTransportRecords / sp_nt_DeleteTransportRecords) —
-- only Create is rewritten here, to be bulk-safe.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateTransportRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (transport_name VARCHAR(255) '$.transport_name')
        WHERE transport_name IS NULL OR LTRIM(RTRIM(transport_name)) = ''
    )
        THROW 50001, N'transport_name is required for every row.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (transport_name VARCHAR(255) '$.transport_name') j
        JOIN dbo.nt_transport_master m ON m.transport_name = j.transport_name AND m.is_active = 'Y'
    )
        THROW 50002, N'A transporter with this name already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @NextSeq INT = ISNULL((SELECT MAX(transport_sno) FROM dbo.nt_transport_master), 0);

        DECLARE @Rows TABLE (rn INT IDENTITY(1,1), transport_code VARCHAR(50), transport_name VARCHAR(255), contact_person VARCHAR(100), phone_no VARCHAR(20), gst_no VARCHAR(20), address VARCHAR(255), created_by VARCHAR(20));
        INSERT INTO @Rows (transport_code, transport_name, contact_person, phone_no, gst_no, address, created_by)
        SELECT
            CASE WHEN transport_code IS NULL OR LTRIM(RTRIM(transport_code)) = '' THEN NULL ELSE LTRIM(RTRIM(transport_code)) END,
            transport_name, contact_person, phone_no, gst_no, address, created_by
        FROM OPENJSON(@json)
        WITH (
            transport_code VARCHAR(50)  '$.transport_code',
            transport_name VARCHAR(255) '$.transport_name',
            contact_person VARCHAR(100) '$.contact_person',
            phone_no       VARCHAR(20)  '$.phone_no',
            gst_no         VARCHAR(20)  '$.gst_no',
            address        VARCHAR(255) '$.address',
            created_by     VARCHAR(20)  '$.created_by'
        );

        UPDATE @Rows
        SET transport_code = 'TRN-' + RIGHT('0000' + CAST(@NextSeq + rn AS VARCHAR(4)), 4)
        WHERE transport_code IS NULL;

        DECLARE @Inserted TABLE (transport_sno INT);

        INSERT INTO dbo.nt_transport_master (transport_code, transport_name, contact_person, phone_no, gst_no, address, is_active, created_by)
        OUTPUT INSERTED.transport_sno INTO @Inserted
        SELECT transport_code, transport_name, contact_person, phone_no, gst_no, address, 'Y', created_by
        FROM @Rows
        ORDER BY rn;

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.nt_transport_master t JOIN @Inserted i ON i.transport_sno = t.transport_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO


-- ============================================================================
-- BankAccountTypeMaster (bank_account_type_master: bank_account_type_sno PK, is_active)
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateBankAccountTypeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (account_type_code NVARCHAR(30) '$.account_type_code', account_type_name NVARCHAR(100) '$.account_type_name')
        WHERE account_type_code IS NULL OR account_type_name IS NULL
    )
        THROW 50002, N'account_type_code and account_type_name are required for every row.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (account_type_code NVARCHAR(30) '$.account_type_code') j
        JOIN dbo.bank_account_type_master m ON m.account_type_code = j.account_type_code
    )
        THROW 50003, N'A bank account type with this code already exists.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (account_type_name NVARCHAR(100) '$.account_type_name') j
        JOIN dbo.bank_account_type_master m ON m.account_type_name = j.account_type_name
    )
        THROW 50004, N'A bank account type with this name already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (bank_account_type_sno INT);

        INSERT INTO dbo.bank_account_type_master (account_type_code, account_type_name, is_active, created_by)
        OUTPUT INSERTED.bank_account_type_sno INTO @Inserted
        SELECT account_type_code, account_type_name, 'Y', created_by
        FROM OPENJSON(@json)
        WITH (
            account_type_code NVARCHAR(30)  '$.account_type_code',
            account_type_name NVARCHAR(100) '$.account_type_name',
            created_by        VARCHAR(20)   '$.created_by'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.bank_account_type_master t JOIN @Inserted i ON i.bank_account_type_sno = t.bank_account_type_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateBankAccountTypeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.bank_account_type_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.bank_account_type_master WHERE bank_account_type_sno = @id)
    BEGIN
        RAISERROR('Bank account type not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.bank_account_type_master
    SET account_type_code = ISNULL(JSON_VALUE(@jsonInput, '$.account_type_code'), account_type_code),
        account_type_name = ISNULL(JSON_VALUE(@jsonInput, '$.account_type_name'), account_type_name),
        modified_by       = JSON_VALUE(@jsonInput, '$.modified_by'),
        modified_at       = GETDATE()
    WHERE bank_account_type_sno = @id;

    SELECT * FROM dbo.bank_account_type_master WHERE bank_account_type_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteBankAccountTypeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.bank_account_type_master WHERE bank_account_type_sno = @id)
    BEGIN
        RAISERROR('Bank account type not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.bank_account_type_master SET is_active = 'N', modified_at = GETDATE() WHERE bank_account_type_sno = @id;
    SELECT @id AS bank_account_type_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- WarehouseLocationMaster (warehouse_location_master: location_sno PK, is_active)
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateWarehouseLocationRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (location_code NVARCHAR(30) '$.location_code', location_name NVARCHAR(150) '$.location_name')
        WHERE location_code IS NULL OR location_name IS NULL
    )
        THROW 50002, N'location_code and location_name are required for every row.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (com_snos NVARCHAR(MAX) '$.com_snos' AS JSON)
        WHERE com_snos IS NULL OR ISJSON(com_snos) = 0 OR NOT EXISTS (SELECT 1 FROM OPENJSON(com_snos))
    )
        THROW 50003, N'At least one company must be selected for every row.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (location_code NVARCHAR(30) '$.location_code') j
        JOIN dbo.warehouse_location_master m ON m.location_code = j.location_code
    )
        THROW 50005, N'A warehouse location with this code already exists.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (location_name NVARCHAR(150) '$.location_name') j
        JOIN dbo.warehouse_location_master m ON m.location_name = j.location_name
    )
        THROW 50006, N'A warehouse location with this name already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (location_sno INT);

        INSERT INTO dbo.warehouse_location_master (location_code, location_name, description, com_snos, div_snos, brn_snos, is_active, created_by)
        OUTPUT INSERTED.location_sno INTO @Inserted
        SELECT
            location_code, location_name, description,
            com_snos,
            ISNULL(div_snos, N'[]'),
            ISNULL(brn_snos, N'[]'),
            'Y', created_by
        FROM OPENJSON(@json)
        WITH (
            location_code NVARCHAR(30)  '$.location_code',
            location_name NVARCHAR(150) '$.location_name',
            description   NVARCHAR(255) '$.description',
            com_snos      NVARCHAR(MAX) '$.com_snos' AS JSON,
            div_snos      NVARCHAR(MAX) '$.div_snos' AS JSON,
            brn_snos      NVARCHAR(MAX) '$.brn_snos' AS JSON,
            created_by    VARCHAR(20)   '$.created_by'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.warehouse_location_master t JOIN @Inserted i ON i.location_sno = t.location_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateWarehouseLocationRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.location_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.warehouse_location_master WHERE location_sno = @id)
    BEGIN
        RAISERROR('Warehouse location not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.warehouse_location_master
    SET location_code = ISNULL(JSON_VALUE(@jsonInput, '$.location_code'), location_code),
        location_name = ISNULL(JSON_VALUE(@jsonInput, '$.location_name'), location_name),
        description   = ISNULL(JSON_VALUE(@jsonInput, '$.description'), description),
        com_snos      = ISNULL(JSON_QUERY(@jsonInput, '$.com_snos'), com_snos),
        div_snos      = ISNULL(JSON_QUERY(@jsonInput, '$.div_snos'), div_snos),
        brn_snos      = ISNULL(JSON_QUERY(@jsonInput, '$.brn_snos'), brn_snos),
        modified_by   = JSON_VALUE(@jsonInput, '$.modified_by'),
        modified_at   = GETDATE()
    WHERE location_sno = @id;

    SELECT * FROM dbo.warehouse_location_master WHERE location_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteWarehouseLocationRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.warehouse_location_master WHERE location_sno = @id)
    BEGIN
        RAISERROR('Warehouse location not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.warehouse_location_master SET is_active = 'N', modified_at = GETDATE() WHERE location_sno = @id;
    SELECT @id AS location_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- DesignationMaster (designation_master: designation_sno PK, is_active)
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateDesignationRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (designation_code NVARCHAR(30) '$.designation_code', designation_name NVARCHAR(100) '$.designation_name')
        WHERE designation_code IS NULL OR designation_name IS NULL
    )
        THROW 51002, N'designation_code and designation_name are required for every row.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (designation_code NVARCHAR(30) '$.designation_code') j
        JOIN dbo.designation_master m ON m.designation_code = j.designation_code
    )
        THROW 51003, N'A designation with this code already exists.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (designation_name NVARCHAR(100) '$.designation_name') j
        JOIN dbo.designation_master m ON m.designation_name = j.designation_name
    )
        THROW 51004, N'A designation with this name already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (designation_sno INT);

        INSERT INTO dbo.designation_master (designation_code, designation_name, is_active, created_by)
        OUTPUT INSERTED.designation_sno INTO @Inserted
        SELECT designation_code, designation_name, 'Y', created_by
        FROM OPENJSON(@json)
        WITH (
            designation_code NVARCHAR(30)  '$.designation_code',
            designation_name NVARCHAR(100) '$.designation_name',
            created_by        VARCHAR(20)  '$.created_by'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.designation_master t JOIN @Inserted i ON i.designation_sno = t.designation_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateDesignationRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.designation_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.designation_master WHERE designation_sno = @id)
    BEGIN
        RAISERROR('Designation not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.designation_master
    SET designation_code = ISNULL(JSON_VALUE(@jsonInput, '$.designation_code'), designation_code),
        designation_name = ISNULL(JSON_VALUE(@jsonInput, '$.designation_name'), designation_name),
        modified_by       = JSON_VALUE(@jsonInput, '$.modified_by'),
        modified_at       = GETDATE()
    WHERE designation_sno = @id;

    SELECT * FROM dbo.designation_master WHERE designation_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteDesignationRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.designation_master WHERE designation_sno = @id)
    BEGIN
        RAISERROR('Designation not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.designation_master SET is_active = 'N', modified_at = GETDATE() WHERE designation_sno = @id;
    SELECT @id AS designation_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- SupplierCatagoryMaster (supplier_category: supp_cat_sno PK, is_active)
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateSupplierCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (supp_cat_name NVARCHAR(50) '$.supp_cat_name')
        WHERE supp_cat_name IS NULL OR LTRIM(RTRIM(supp_cat_name)) = ''
    )
        THROW 50002, N'supp_cat_name is required for every row.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (supp_cat_name NVARCHAR(50) '$.supp_cat_name') j
        JOIN dbo.supplier_category m ON m.supp_cat_name = j.supp_cat_name AND m.is_active = 'Y'
    )
        THROW 50004, N'A supplier category with this name already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (supp_cat_sno INT);

        INSERT INTO dbo.supplier_category (supp_cat_name, supp_cat_code, is_active, created_date, created_by)
        OUTPUT INSERTED.supp_cat_sno INTO @Inserted
        SELECT supp_cat_name, supp_cat_code, 'Y', GETDATE(), created_by
        FROM OPENJSON(@json)
        WITH (
            supp_cat_name NVARCHAR(50)  '$.supp_cat_name',
            supp_cat_code NVARCHAR(100) '$.supp_cat_code',
            created_by    VARCHAR(20)   '$.created_by'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.supplier_category t JOIN @Inserted i ON i.supp_cat_sno = t.supp_cat_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateSupplierCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.supp_cat_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.supplier_category WHERE supp_cat_sno = @id)
    BEGIN
        RAISERROR('Supplier category not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.supplier_category
    SET supp_cat_name = ISNULL(JSON_VALUE(@jsonInput, '$.supp_cat_name'), supp_cat_name),
        supp_cat_code = ISNULL(JSON_VALUE(@jsonInput, '$.supp_cat_code'), supp_cat_code),
        modified_date = GETDATE(),
        modified_by   = JSON_VALUE(@jsonInput, '$.modified_by')
    WHERE supp_cat_sno = @id;

    SELECT * FROM dbo.supplier_category WHERE supp_cat_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteSupplierCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.supplier_category WHERE supp_cat_sno = @id)
    BEGIN
        RAISERROR('Supplier category not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.supplier_category SET is_active = 'N', modified_date = GETDATE() WHERE supp_cat_sno = @id;
    SELECT @id AS supp_cat_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- PaymentModeMaster (payment_mode_master: payment_mode_sno PK, is_active)
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreatePaymentModeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (payment_mode_code NVARCHAR(20) '$.payment_mode_code', payment_mode_name NVARCHAR(50) '$.payment_mode_name')
        WHERE payment_mode_code IS NULL OR LTRIM(RTRIM(payment_mode_code)) = '' OR payment_mode_name IS NULL OR LTRIM(RTRIM(payment_mode_name)) = ''
    )
        THROW 59001, N'payment_mode_code and payment_mode_name are required for every row.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (payment_mode_code NVARCHAR(20) '$.payment_mode_code') j
        JOIN dbo.payment_mode_master m ON m.payment_mode_code = UPPER(j.payment_mode_code)
    )
        THROW 59002, N'A payment mode with this code already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (payment_mode_sno INT);

        INSERT INTO dbo.payment_mode_master (payment_mode_code, payment_mode_name, is_active, created_by)
        OUTPUT INSERTED.payment_mode_sno INTO @Inserted
        SELECT UPPER(payment_mode_code), payment_mode_name, 'Y', created_by
        FROM OPENJSON(@json)
        WITH (
            payment_mode_code NVARCHAR(20) '$.payment_mode_code',
            payment_mode_name NVARCHAR(50) '$.payment_mode_name',
            created_by         VARCHAR(20) '$.created_by'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.payment_mode_master t JOIN @Inserted i ON i.payment_mode_sno = t.payment_mode_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdatePaymentModeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_mode_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.payment_mode_master WHERE payment_mode_sno = @id)
    BEGIN
        RAISERROR('Payment mode not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.payment_mode_master
    SET payment_mode_code = ISNULL(UPPER(JSON_VALUE(@jsonInput, '$.payment_mode_code')), payment_mode_code),
        payment_mode_name = ISNULL(JSON_VALUE(@jsonInput, '$.payment_mode_name'), payment_mode_name),
        modified_date     = GETDATE(),
        modified_by       = JSON_VALUE(@jsonInput, '$.modified_by')
    WHERE payment_mode_sno = @id;

    SELECT * FROM dbo.payment_mode_master WHERE payment_mode_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeletePaymentModeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.payment_mode_master WHERE payment_mode_sno = @id)
    BEGIN
        RAISERROR('Payment mode not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.payment_mode_master SET is_active = 'N', modified_date = GETDATE() WHERE payment_mode_sno = @id;
    SELECT @id AS payment_mode_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- ServiceTypeMaster (service_type_master: service_type_sno PK, is_active)
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateServiceTypeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 58001, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (service_type_code VARCHAR(30) '$.service_type_code', service_type_name NVARCHAR(100) '$.service_type_name')
        WHERE service_type_code IS NULL OR service_type_name IS NULL
    )
        THROW 58002, N'service_type_code and service_type_name are required for every row.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (service_type_code VARCHAR(30) '$.service_type_code') j
        JOIN dbo.service_type_master m ON m.service_type_code = j.service_type_code
    )
        THROW 58003, N'A service type with this code already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (service_type_sno INT);

        INSERT INTO dbo.service_type_master (service_type_code, service_type_name, is_active, created_by)
        OUTPUT INSERTED.service_type_sno INTO @Inserted
        SELECT service_type_code, service_type_name, 'Y', created_by
        FROM OPENJSON(@json)
        WITH (
            service_type_code VARCHAR(30)   '$.service_type_code',
            service_type_name NVARCHAR(100) '$.service_type_name',
            created_by        VARCHAR(20)   '$.created_by'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.service_type_master t JOIN @Inserted i ON i.service_type_sno = t.service_type_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateServiceTypeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_type_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.service_type_master WHERE service_type_sno = @id)
    BEGIN
        RAISERROR('Service type not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.service_type_master
    SET service_type_code = ISNULL(JSON_VALUE(@jsonInput, '$.service_type_code'), service_type_code),
        service_type_name = ISNULL(JSON_VALUE(@jsonInput, '$.service_type_name'), service_type_name),
        modified_by       = JSON_VALUE(@jsonInput, '$.modified_by'),
        modified_at       = GETDATE()
    WHERE service_type_sno = @id;

    SELECT * FROM dbo.service_type_master WHERE service_type_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteServiceTypeRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.service_type_master WHERE service_type_sno = @id)
    BEGIN
        RAISERROR('Service type not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.service_type_master SET is_active = 'N', modified_at = GETDATE() WHERE service_type_sno = @id;
    SELECT @id AS service_type_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- ServiceMaster (service_master: service_sno PK, is_active). Note:
-- incharge_ecno is collected by the frontend form but has no column on
-- service_master and is not persisted by the existing create SP either —
-- that gap predates this migration and is left untouched (out of scope).
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateServiceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 58004, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (service_name NVARCHAR(150) '$.service_name', service_code VARCHAR(50) '$.service_code', service_type_sno INT '$.service_type_sno')
        WHERE service_name IS NULL OR service_code IS NULL OR service_type_sno IS NULL
    )
        THROW 58005, N'service_name, service_code and service_type_sno are required for every row.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (service_type_sno INT '$.service_type_sno') j
        LEFT JOIN dbo.service_type_master st ON st.service_type_sno = j.service_type_sno AND st.is_active = 'Y'
        WHERE st.service_type_sno IS NULL
    )
        THROW 58006, N'service_type_sno does not reference an active service type.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (service_code VARCHAR(50) '$.service_code') j
        JOIN dbo.service_master m ON m.service_code = j.service_code
    )
        THROW 58007, N'A service with this code already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (service_sno INT);

        INSERT INTO dbo.service_master (service_name, service_code, service_type_sno, default_uom_sno, description, is_active, created_by)
        OUTPUT INSERTED.service_sno INTO @Inserted
        SELECT service_name, service_code, service_type_sno, default_uom_sno, description, 'Y', created_by
        FROM OPENJSON(@json)
        WITH (
            service_name     NVARCHAR(150) '$.service_name',
            service_code     VARCHAR(50)   '$.service_code',
            service_type_sno INT           '$.service_type_sno',
            default_uom_sno  INT           '$.default_uom_sno',
            description      NVARCHAR(500) '$.description',
            created_by       VARCHAR(20)   '$.created_by'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.service_master t JOIN @Inserted i ON i.service_sno = t.service_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateServiceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.service_master WHERE service_sno = @id)
    BEGIN
        RAISERROR('Service not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.service_master
    SET service_name     = ISNULL(JSON_VALUE(@jsonInput, '$.service_name'), service_name),
        service_code     = ISNULL(JSON_VALUE(@jsonInput, '$.service_code'), service_code),
        service_type_sno = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.service_type_sno') AS INT), service_type_sno),
        default_uom_sno  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.default_uom_sno') AS INT), default_uom_sno),
        description      = ISNULL(JSON_VALUE(@jsonInput, '$.description'), description),
        modified_by      = JSON_VALUE(@jsonInput, '$.modified_by'),
        modified_at      = GETDATE()
    WHERE service_sno = @id;

    SELECT * FROM dbo.service_master WHERE service_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteServiceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.service_master WHERE service_sno = @id)
    BEGIN
        RAISERROR('Service not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.service_master SET is_active = 'N', modified_at = GETDATE() WHERE service_sno = @id;
    SELECT @id AS service_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- RecurrenceCadenceMaster (recurrence_cadence_master: recurrence_cadence_sno PK, is_active)
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateRecurrenceCadenceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 58008, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json)
        WITH (cadence_code VARCHAR(30) '$.cadence_code', cadence_name NVARCHAR(100) '$.cadence_name',
              interval_unit VARCHAR(10) '$.interval_unit', interval_value INT '$.interval_value')
        WHERE cadence_code IS NULL OR cadence_name IS NULL OR interval_unit IS NULL OR interval_value IS NULL
    )
        THROW 58009, N'cadence_code, cadence_name, interval_unit and interval_value are required for every row.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (interval_unit VARCHAR(10) '$.interval_unit')
        WHERE UPPER(interval_unit) NOT IN ('DAY', 'MONTH')
    )
        THROW 58010, N'interval_unit must be DAY or MONTH.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (interval_value INT '$.interval_value')
        WHERE interval_value <= 0
    )
        THROW 58011, N'interval_value must be positive.', 1;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (cadence_code VARCHAR(30) '$.cadence_code') j
        JOIN dbo.recurrence_cadence_master m ON m.cadence_code = j.cadence_code
    )
        THROW 58012, N'A recurrence cadence with this code already exists.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (recurrence_cadence_sno INT);

        INSERT INTO dbo.recurrence_cadence_master (cadence_code, cadence_name, interval_unit, interval_value, description, is_active, created_by)
        OUTPUT INSERTED.recurrence_cadence_sno INTO @Inserted
        SELECT cadence_code, cadence_name, UPPER(interval_unit), interval_value, description, 'Y', created_by
        FROM OPENJSON(@json)
        WITH (
            cadence_code   VARCHAR(30)   '$.cadence_code',
            cadence_name   NVARCHAR(100) '$.cadence_name',
            interval_unit  VARCHAR(10)   '$.interval_unit',
            interval_value INT           '$.interval_value',
            description    NVARCHAR(200) '$.description',
            created_by     VARCHAR(20)   '$.created_by'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.recurrence_cadence_master t JOIN @Inserted i ON i.recurrence_cadence_sno = t.recurrence_cadence_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateRecurrenceCadenceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.recurrence_cadence_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.recurrence_cadence_master WHERE recurrence_cadence_sno = @id)
    BEGIN
        RAISERROR('Recurrence cadence not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.recurrence_cadence_master
    SET cadence_code   = ISNULL(JSON_VALUE(@jsonInput, '$.cadence_code'), cadence_code),
        cadence_name   = ISNULL(JSON_VALUE(@jsonInput, '$.cadence_name'), cadence_name),
        interval_unit  = ISNULL(UPPER(JSON_VALUE(@jsonInput, '$.interval_unit')), interval_unit),
        interval_value = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.interval_value') AS INT), interval_value),
        description    = ISNULL(JSON_VALUE(@jsonInput, '$.description'), description),
        modified_by    = JSON_VALUE(@jsonInput, '$.modified_by'),
        modified_at    = GETDATE()
    WHERE recurrence_cadence_sno = @id;

    SELECT * FROM dbo.recurrence_cadence_master WHERE recurrence_cadence_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteRecurrenceCadenceRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.recurrence_cadence_master WHERE recurrence_cadence_sno = @id)
    BEGIN
        RAISERROR('Recurrence cadence not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.recurrence_cadence_master SET is_active = 'N', modified_at = GETDATE() WHERE recurrence_cadence_sno = @id;
    SELECT @id AS recurrence_cadence_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- DivisionMaster (division_master: div_sno PK, is_active)
-- ============================================================================
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateDivRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (div_name VARCHAR(100) '$.div_name', com_sno INT '$.com_sno')
        WHERE div_name IS NULL OR LTRIM(RTRIM(div_name)) = '' OR com_sno IS NULL
    )
        THROW 50001, N'div_name and com_sno are required for every row.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (div_sno INT);

        INSERT INTO dbo.division_master (div_name, div_prefix, div_type, com_sno, is_active, created_date)
        OUTPUT INSERTED.div_sno INTO @Inserted
        SELECT LTRIM(RTRIM(div_name)), LTRIM(RTRIM(div_prefix)), LTRIM(RTRIM(div_type)), com_sno, 'Y', GETDATE()
        FROM OPENJSON(@json)
        WITH (
            div_name   VARCHAR(100) '$.div_name',
            div_prefix VARCHAR(10)  '$.div_prefix',
            div_type   VARCHAR(10)  '$.div_type',
            com_sno    INT          '$.com_sno'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.division_master t JOIN @Inserted i ON i.div_sno = t.div_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateDivRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.division_master WHERE div_sno = @id)
    BEGIN
        RAISERROR('Division not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.division_master
    SET div_name   = ISNULL(JSON_VALUE(@jsonInput, '$.div_name'), div_name),
        div_prefix = ISNULL(JSON_VALUE(@jsonInput, '$.div_prefix'), div_prefix),
        div_type   = ISNULL(JSON_VALUE(@jsonInput, '$.div_type'), div_type),
        com_sno    = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT), com_sno)
    WHERE div_sno = @id;

    SELECT * FROM dbo.division_master WHERE div_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteDivRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.division_master WHERE div_sno = @id)
    BEGIN
        RAISERROR('Division not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.division_master SET is_active = 'N' WHERE div_sno = @id;
    SELECT @id AS div_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- DeptMaster (dept_master: dept_sno PK, is_active)
-- ============================================================================
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateDeptRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json)
        WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno', dept_name VARCHAR(50) '$.dept_name')
        WHERE com_sno IS NULL OR div_sno IS NULL OR brn_sno IS NULL OR dept_name IS NULL OR LTRIM(RTRIM(dept_name)) = ''
    )
        THROW 50001, N'com_sno, div_sno, brn_sno and dept_name are required for every row.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Inserted TABLE (dept_sno INT);

        INSERT INTO dbo.dept_master (com_sno, div_sno, brn_sno, dept_name, is_active, created_date, dept_code)
        OUTPUT INSERTED.dept_sno INTO @Inserted
        SELECT com_sno, div_sno, brn_sno, dept_name, 'Y', GETDATE(), dept_code
        FROM OPENJSON(@json)
        WITH (
            com_sno   INT         '$.com_sno',
            div_sno   INT         '$.div_sno',
            brn_sno   INT         '$.brn_sno',
            dept_name VARCHAR(50) '$.dept_name',
            dept_code VARCHAR(50) '$.dept_code'
        );

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.dept_master t JOIN @Inserted i ON i.dept_sno = t.dept_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateDeptRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.dept_master WHERE dept_sno = @id)
    BEGIN
        RAISERROR('Department not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.dept_master
    SET com_sno   = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT), com_sno),
        div_sno   = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT), div_sno),
        brn_sno   = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT), brn_sno),
        dept_name = ISNULL(JSON_VALUE(@jsonInput, '$.dept_name'), dept_name),
        dept_code = ISNULL(JSON_VALUE(@jsonInput, '$.dept_code'), dept_code)
    WHERE dept_sno = @id;

    SELECT * FROM dbo.dept_master WHERE dept_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteDeptRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.dept_master WHERE dept_sno = @id)
    BEGIN
        RAISERROR('Department not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.dept_master SET is_active = 'N' WHERE dept_sno = @id;
    SELECT @id AS dept_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- CompanyMaster (company_master: com_sno PK, is_active + linked address_master
-- row via add_sno). Bulk create inserts one address_master row per company
-- row (matching each JSON element by array position via ROW_NUMBER, since
-- there is no natural join key before both rows exist).
-- ============================================================================
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateCompanyRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (com_name VARCHAR(100) '$.com_name')
        WHERE com_name IS NULL OR LTRIM(RTRIM(com_name)) = ''
    )
        THROW 50001, N'com_name is required for every row.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Rows TABLE (
            rn INT IDENTITY(1,1),
            com_name VARCHAR(100), com_prefix VARCHAR(10),
            add_door_no VARCHAR(50), add_street VARCHAR(100), add_city VARCHAR(50), add_state VARCHAR(50),
            add_state_code VARCHAR(10), add_pin_code VARCHAR(10),
            add_reg_door_no VARCHAR(50), add_reg_street VARCHAR(100), add_reg_city VARCHAR(50),
            add_reg_state VARCHAR(50), add_reg_pincode VARCHAR(10),
            add_pan VARCHAR(10), is_gst_applicable VARCHAR(1), add_gst VARCHAR(15), add_tan VARCHAR(10), add_cin VARCHAR(21),
            add_sno INT NULL, com_sno INT NULL
        );

        INSERT INTO @Rows (com_name, com_prefix, add_door_no, add_street, add_city, add_state, add_state_code, add_pin_code,
                            add_reg_door_no, add_reg_street, add_reg_city, add_reg_state, add_reg_pincode,
                            add_pan, is_gst_applicable, add_gst, add_tan, add_cin)
        SELECT com_name, com_prefix, add_door_no, add_street, add_city, add_state, add_state_code, add_pin_code,
               add_reg_door_no, add_reg_street, add_reg_city, add_reg_state, add_reg_pincode,
               add_pan, is_gst_applicable, add_gst, add_tan, add_cin
        FROM OPENJSON(@json)
        WITH (
            com_name          VARCHAR(100) '$.com_name',
            com_prefix        VARCHAR(10)  '$.com_prefix',
            add_door_no       VARCHAR(50)  '$.add_door_no',
            add_street        VARCHAR(100) '$.add_street',
            add_city          VARCHAR(50)  '$.add_city',
            add_state         VARCHAR(50)  '$.add_state',
            add_state_code    VARCHAR(10)  '$.add_state_code',
            add_pin_code      VARCHAR(10)  '$.add_pin_code',
            add_reg_door_no   VARCHAR(50)  '$.add_reg_door_no',
            add_reg_street    VARCHAR(100) '$.add_reg_street',
            add_reg_city      VARCHAR(50)  '$.add_reg_city',
            add_reg_state     VARCHAR(50)  '$.add_reg_state',
            add_reg_pincode   VARCHAR(10)  '$.add_reg_pincode',
            add_pan           VARCHAR(10)  '$.add_pan',
            is_gst_applicable VARCHAR(1)   '$.is_gst_applicable',
            add_gst           VARCHAR(15)  '$.add_gst',
            add_tan           VARCHAR(10)  '$.add_tan',
            add_cin           VARCHAR(21)  '$.add_cin'
        );

        DECLARE @rn INT, @maxRn INT = (SELECT MAX(rn) FROM @Rows);
        SET @rn = 1;
        WHILE @rn <= @maxRn
        BEGIN
            DECLARE @addSno INT, @comSno INT;

            INSERT INTO dbo.address_master (
                add_door_no, add_street, add_city, add_state, add_state_code, add_pin_code,
                add_reg_door_no, add_reg_street, add_reg_city, add_reg_state, add_reg_pincode,
                add_pan, is_gst_applicable, add_gst, add_tan, add_cin
            )
            SELECT add_door_no, add_street, add_city, add_state, add_state_code, add_pin_code,
                   add_reg_door_no, add_reg_street, add_reg_city, add_reg_state, add_reg_pincode,
                   add_pan, is_gst_applicable, add_gst, add_tan, add_cin
            FROM @Rows WHERE rn = @rn;
            SET @addSno = SCOPE_IDENTITY();

            INSERT INTO dbo.company_master (com_name, com_prefix, is_active, created_date, add_sno)
            SELECT com_name, com_prefix, 'Y', GETDATE(), @addSno
            FROM @Rows WHERE rn = @rn;
            SET @comSno = SCOPE_IDENTITY();

            UPDATE @Rows SET add_sno = @addSno, com_sno = @comSno WHERE rn = @rn;
            SET @rn += 1;
        END

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.company_master t JOIN @Rows r ON r.com_sno = t.com_sno ORDER BY r.rn;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateCompanyRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.company_master WHERE com_sno = @id)
    BEGIN
        RAISERROR('Company not found.', 16, 1);
        RETURN;
    END

    DECLARE @addSno INT = (SELECT add_sno FROM dbo.company_master WHERE com_sno = @id);

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.company_master
        SET com_name   = ISNULL(JSON_VALUE(@jsonInput, '$.com_name'), com_name),
            com_prefix = ISNULL(JSON_VALUE(@jsonInput, '$.com_prefix'), com_prefix)
        WHERE com_sno = @id;

        IF @addSno IS NOT NULL
        BEGIN
            UPDATE dbo.address_master
            SET add_pan           = ISNULL(JSON_VALUE(@jsonInput, '$.add_pan'), add_pan),
                is_gst_applicable = ISNULL(JSON_VALUE(@jsonInput, '$.is_gst_applicable'), is_gst_applicable),
                add_gst           = ISNULL(JSON_VALUE(@jsonInput, '$.add_gst'), add_gst),
                add_tan           = ISNULL(JSON_VALUE(@jsonInput, '$.add_tan'), add_tan),
                add_cin           = ISNULL(JSON_VALUE(@jsonInput, '$.add_cin'), add_cin),
                add_door_no       = ISNULL(JSON_VALUE(@jsonInput, '$.add_door_no'), add_door_no),
                add_street        = ISNULL(JSON_VALUE(@jsonInput, '$.add_street'), add_street),
                add_city          = ISNULL(JSON_VALUE(@jsonInput, '$.add_city'), add_city),
                add_state         = ISNULL(JSON_VALUE(@jsonInput, '$.add_state'), add_state),
                add_state_code    = ISNULL(JSON_VALUE(@jsonInput, '$.add_state_code'), add_state_code),
                add_pin_code      = ISNULL(JSON_VALUE(@jsonInput, '$.add_pin_code'), add_pin_code),
                add_reg_door_no   = ISNULL(JSON_VALUE(@jsonInput, '$.add_reg_door_no'), add_reg_door_no),
                add_reg_street    = ISNULL(JSON_VALUE(@jsonInput, '$.add_reg_street'), add_reg_street),
                add_reg_city      = ISNULL(JSON_VALUE(@jsonInput, '$.add_reg_city'), add_reg_city),
                add_reg_state     = ISNULL(JSON_VALUE(@jsonInput, '$.add_reg_state'), add_reg_state),
                add_reg_pincode   = ISNULL(JSON_VALUE(@jsonInput, '$.add_reg_pincode'), add_reg_pincode)
            WHERE add_sno = @addSno;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT c.*, a.add_pan, a.is_gst_applicable, a.add_gst, a.add_tan, a.add_cin,
           a.add_door_no, a.add_street, a.add_city, a.add_state, a.add_state_code, a.add_pin_code,
           a.add_reg_door_no, a.add_reg_street, a.add_reg_city, a.add_reg_state, a.add_reg_pincode
    FROM dbo.company_master c
    LEFT JOIN dbo.address_master a ON a.add_sno = c.add_sno
    WHERE c.com_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteCompanyRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.company_master WHERE com_sno = @id)
    BEGIN
        RAISERROR('Company not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.company_master SET is_active = 'N' WHERE com_sno = @id;
    SELECT @id AS com_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO


-- ============================================================================
-- BranchMaster (branch_master: brn_sno PK, is_active + linked address_master
-- row via add_sno). Same bulk pattern as CompanyMaster.
-- ============================================================================
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateBranchRecords]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0
        THROW 50000, N'Invalid JSON payload provided.', 1;

    DECLARE @json NVARCHAR(MAX) = CASE WHEN LEFT(LTRIM(@jsonInput), 1) = '[' THEN @jsonInput ELSE '[' + @jsonInput + ']' END;

    IF EXISTS (
        SELECT 1 FROM OPENJSON(@json) WITH (brn_name VARCHAR(100) '$.brn_name', com_sno INT '$.com_sno', div_sno INT '$.div_sno')
        WHERE brn_name IS NULL OR LTRIM(RTRIM(brn_name)) = '' OR com_sno IS NULL OR div_sno IS NULL
    )
        THROW 50001, N'brn_name, com_sno and div_sno are required for every row.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Rows TABLE (
            rn INT IDENTITY(1,1),
            brn_name VARCHAR(100), brn_prefix VARCHAR(10), com_sno INT, div_sno INT,
            add_door_no VARCHAR(50), add_street VARCHAR(100), add_city VARCHAR(50), add_state VARCHAR(50),
            add_state_code VARCHAR(10), add_pin_code VARCHAR(10),
            add_pan VARCHAR(10), is_gst_applicable VARCHAR(1), add_gst VARCHAR(15), add_tan VARCHAR(10), add_cin VARCHAR(21),
            add_sno INT NULL, brn_sno_out INT NULL
        );

        INSERT INTO @Rows (brn_name, brn_prefix, com_sno, div_sno, add_door_no, add_street, add_city, add_state, add_state_code, add_pin_code,
                            add_pan, is_gst_applicable, add_gst, add_tan, add_cin)
        SELECT brn_name, brn_prefix, com_sno, div_sno, add_door_no, add_street, add_city, add_state, add_state_code, add_pin_code,
               add_pan, is_gst_applicable, add_gst, add_tan, add_cin
        FROM OPENJSON(@json)
        WITH (
            brn_name          VARCHAR(100) '$.brn_name',
            brn_prefix        VARCHAR(10)  '$.brn_prefix',
            com_sno           INT          '$.com_sno',
            div_sno           INT          '$.div_sno',
            add_door_no       VARCHAR(50)  '$.add_door_no',
            add_street        VARCHAR(100) '$.add_street',
            add_city          VARCHAR(50)  '$.add_city',
            add_state         VARCHAR(50)  '$.add_state',
            add_state_code    VARCHAR(10)  '$.add_state_code',
            add_pin_code      VARCHAR(10)  '$.add_pin_code',
            add_pan           VARCHAR(10)  '$.add_pan',
            is_gst_applicable VARCHAR(1)   '$.is_gst_applicable',
            add_gst           VARCHAR(15)  '$.add_gst',
            add_tan           VARCHAR(10)  '$.add_tan',
            add_cin           VARCHAR(21)  '$.add_cin'
        );

        DECLARE @rn INT, @maxRn INT = (SELECT MAX(rn) FROM @Rows);
        SET @rn = 1;
        WHILE @rn <= @maxRn
        BEGIN
            DECLARE @addSno INT, @brnSno INT;

            INSERT INTO dbo.address_master (
                add_door_no, add_street, add_city, add_state, add_state_code, add_pin_code,
                add_pan, is_gst_applicable, add_gst, add_tan, add_cin
            )
            SELECT add_door_no, add_street, add_city, add_state, add_state_code, add_pin_code,
                   add_pan, is_gst_applicable, add_gst, add_tan, add_cin
            FROM @Rows WHERE rn = @rn;
            SET @addSno = SCOPE_IDENTITY();

            INSERT INTO dbo.branch_master (brn_name, brn_prefix, com_sno, div_sno, add_sno, is_active, created_date)
            SELECT brn_name, brn_prefix, com_sno, div_sno, @addSno, 'Y', GETDATE()
            FROM @Rows WHERE rn = @rn;
            SET @brnSno = SCOPE_IDENTITY();

            UPDATE @Rows SET add_sno = @addSno, brn_sno_out = @brnSno WHERE rn = @rn;
            SET @rn += 1;
        END

        COMMIT TRANSACTION;

        SELECT t.* FROM dbo.branch_master t JOIN @Rows r ON r.brn_sno_out = t.brn_sno ORDER BY r.rn;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateBranchRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.branch_master WHERE brn_sno = @id)
    BEGIN
        RAISERROR('Branch not found.', 16, 1);
        RETURN;
    END

    DECLARE @addSno INT = (SELECT add_sno FROM dbo.branch_master WHERE brn_sno = @id);

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.branch_master
        SET com_sno    = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT), com_sno),
            div_sno    = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT), div_sno),
            brn_name   = ISNULL(JSON_VALUE(@jsonInput, '$.brn_name'), brn_name),
            brn_prefix = ISNULL(JSON_VALUE(@jsonInput, '$.brn_prefix'), brn_prefix)
        WHERE brn_sno = @id;

        IF @addSno IS NOT NULL
        BEGIN
            UPDATE dbo.address_master
            SET add_door_no    = ISNULL(JSON_VALUE(@jsonInput, '$.add_door_no'), add_door_no),
                add_street     = ISNULL(JSON_VALUE(@jsonInput, '$.add_street'), add_street),
                add_city       = ISNULL(JSON_VALUE(@jsonInput, '$.add_city'), add_city),
                add_state      = ISNULL(JSON_VALUE(@jsonInput, '$.add_state'), add_state),
                add_state_code = ISNULL(JSON_VALUE(@jsonInput, '$.add_state_code'), add_state_code),
                add_pin_code   = ISNULL(JSON_VALUE(@jsonInput, '$.add_pin_code'), add_pin_code)
            WHERE add_sno = @addSno;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT b.*, a.add_door_no, a.add_street, a.add_city, a.add_state, a.add_state_code, a.add_pin_code
    FROM dbo.branch_master b
    LEFT JOIN dbo.address_master a ON a.add_sno = b.add_sno
    WHERE b.brn_sno = @id;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteBranchRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.branch_master WHERE brn_sno = @id)
    BEGIN
        RAISERROR('Branch not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.branch_master SET is_active = 'N' WHERE brn_sno = @id;
    SELECT @id AS brn_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO
