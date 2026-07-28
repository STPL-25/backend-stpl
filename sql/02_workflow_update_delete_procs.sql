-- ============================================================
-- Approval Workflow — update + delete procedures
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend/src/WorkFlowApproval (mounted at /api/workflow_approval)
--
-- NO NEW TABLES. Everything here operates on the three tables that already
-- exist: approval_workflow_master, workflow_types, workflow_stage.
--
-- Why this is needed
-- ------------------
-- The backend has always called ten sp_nt_* procedures, but only three of them
-- exist on the server:
--
--     PRESENT : sp_nt_SaveFullWorkflow, sp_nt_GetWorkflowMasters,
--               sp_nt_GetWorkflowTypes
--     MISSING : sp_nt_UpdateWorkflowMaster, sp_nt_SaveWorkflowType,
--               sp_nt_UpdateWorkflowType, sp_nt_SaveWorkflowStage,
--               sp_nt_GetWorkflowStages, sp_nt_UpdateWorkflowStage,
--               sp_nt_GetWorkflowByEntity
--
-- Creating a workflow worked because it goes through sp_nt_SaveFullWorkflow.
-- *Editing* one did not: every update call hit "Could not find stored
-- procedure" and the repository turned that into a generic failure. This file
-- supplies the seven missing procedures and adds three for delete.
--
-- Deletes are soft — is_active flips to 'N' and the row stays — so approvals
-- already routed through a workflow keep their history.
--
-- Conventions follow sp_nt_SaveFullWorkflow: a single @jsonInput NVARCHAR(MAX)
-- parameter, scalars via JSON_VALUE, and a result row the API can echo back.
-- The audit column modified_data holds a JSON snapshot of the row as it was
-- before the change.
-- ============================================================


-- ============================================================
-- approval_workflow_master
-- ============================================================

-- ── sp_nt_GetWorkflowMasters (REPLACED) ───────────────────────────────────
-- The existing version returns every row and omits is_active, so the screen
-- could never tell an active workflow from an inactive one and a soft-deleted
-- workflow would keep appearing in the dropdown. Same column list as before
-- plus is_active, and deleted rows are filtered out.
IF OBJECT_ID('dbo.sp_nt_GetWorkflowMasters', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetWorkflowMasters;
GO
CREATE PROCEDURE dbo.sp_nt_GetWorkflowMasters
AS
BEGIN
    SET NOCOUNT ON;

    SELECT workflow_id,
           workflow_code,
           workflow_name,
           entity_type,
           description,
           is_active
    FROM dbo.approval_workflow_master
    WHERE is_active = 'Y'
    ORDER BY workflow_name;
END;
GO

-- ── sp_nt_GetWorkflowByEntity ─────────────────────────────────────────────
-- Workflows for one entity type. @jsonInput: {"entity_type":"KYC"}
IF OBJECT_ID('dbo.sp_nt_GetWorkflowByEntity', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetWorkflowByEntity;
GO
CREATE PROCEDURE dbo.sp_nt_GetWorkflowByEntity
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @entity_type NVARCHAR(50) = JSON_VALUE(@jsonInput, '$.entity_type');

    SELECT workflow_id,
           workflow_code,
           workflow_name,
           entity_type,
           description,
           is_active
    FROM dbo.approval_workflow_master
    WHERE is_active = 'Y'
      AND (@entity_type IS NULL OR entity_type = @entity_type)
    ORDER BY workflow_name;
END;
GO

-- ── sp_nt_UpdateWorkflowMaster ────────────────────────────────────────────
-- Edits the header. workflow_code and entity_type are never changed: the code
-- is issued once by the sequence and the entity type is what the workflow is
-- keyed on. Any field left out of the JSON keeps its current value.
--
-- @jsonInput: {"workflow_id":12,"workflow_name":"...","description":"...",
--              "is_active":"Y","modified_by":"1234"}
IF OBJECT_ID('dbo.sp_nt_UpdateWorkflowMaster', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_UpdateWorkflowMaster;
GO
CREATE PROCEDURE dbo.sp_nt_UpdateWorkflowMaster
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @workflow_id   INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.workflow_id') AS INT),
            @workflow_name NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.workflow_name'),
            @description   NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.description'),
            @is_active     CHAR(1)       = JSON_VALUE(@jsonInput, '$.is_active'),
            @modified_by   VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.modified_by');

    IF @workflow_id IS NULL
    BEGIN
        THROW 50002, N'workflow_id is required.', 1;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.approval_workflow_master WHERE workflow_id = @workflow_id)
    BEGIN
        THROW 50003, N'Workflow not found.', 1;
        RETURN;
    END;

    -- Snapshot the row as it stands, for the audit column.
    DECLARE @before NVARCHAR(MAX) = (
        SELECT workflow_name, description, is_active
        FROM dbo.approval_workflow_master
        WHERE workflow_id = @workflow_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    UPDATE dbo.approval_workflow_master
    SET workflow_name = ISNULL(@workflow_name, workflow_name),
        description   = ISNULL(@description,   description),
        is_active     = ISNULL(@is_active,     is_active),
        modified_data = @before,
        modified_by   = @modified_by,
        modified_at   = GETDATE()
    WHERE workflow_id = @workflow_id;

    SELECT workflow_id,
           workflow_code,
           workflow_name,
           entity_type,
           description,
           is_active,
           N'SUCCESS' AS status,
           N'Workflow updated successfully.' AS message
    FROM dbo.approval_workflow_master
    WHERE workflow_id = @workflow_id;
END;
GO

-- ── sp_nt_DeleteWorkflow ──────────────────────────────────────────────────
-- Soft-deletes a workflow and everything under it: its types and their stages.
-- Nothing is physically removed.
--
-- @jsonInput: {"workflow_id":12,"modified_by":"1234"}
IF OBJECT_ID('dbo.sp_nt_DeleteWorkflow', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_DeleteWorkflow;
GO
CREATE PROCEDURE dbo.sp_nt_DeleteWorkflow
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @workflow_id INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.workflow_id') AS INT),
            @modified_by VARCHAR(20) = JSON_VALUE(@jsonInput, '$.modified_by');

    IF @workflow_id IS NULL
    BEGIN
        THROW 50002, N'workflow_id is required.', 1;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.approval_workflow_master WHERE workflow_id = @workflow_id)
    BEGIN
        THROW 50003, N'Workflow not found.', 1;
        RETURN;
    END;

    DECLARE @types_deleted  INT = 0,
            @stages_deleted INT = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.workflow_stage
        SET is_active   = 'N',
            modified_by = @modified_by,
            modified_at = GETDATE()
        WHERE is_active = 'Y'
          AND workflow_types_id IN (
              SELECT workflow_types_id FROM dbo.workflow_types WHERE workflow_id = @workflow_id
          );
        SET @stages_deleted = @@ROWCOUNT;

        UPDATE dbo.workflow_types
        SET is_active   = 'N',
            modified_by = @modified_by,
            modified_at = GETDATE()
        WHERE workflow_id = @workflow_id
          AND is_active = 'Y';
        SET @types_deleted = @@ROWCOUNT;

        UPDATE dbo.approval_workflow_master
        SET is_active   = 'N',
            modified_by = @modified_by,
            modified_at = GETDATE()
        WHERE workflow_id = @workflow_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @workflow_id    AS workflow_id,
           'N'             AS is_active,
           @types_deleted  AS types_deleted,
           @stages_deleted AS stages_deleted,
           N'SUCCESS'      AS status,
           N'Workflow deleted successfully.' AS message;
END;
GO


-- ============================================================
-- workflow_types
-- ============================================================

-- ── sp_nt_SaveWorkflowType ────────────────────────────────────────────────
-- Adds one branch × department row to an existing workflow. The API reads
-- workflow_types_id off the result to attach stages to it.
--
-- @jsonInput: {"workflow_id":12,"workflow_types_name":"Standard","com_sno":1,
--              "div_sno":2,"brn_sno":3,"dept_sno":4,"is_active":"Y"}
IF OBJECT_ID('dbo.sp_nt_SaveWorkflowType', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_SaveWorkflowType;
GO
CREATE PROCEDURE dbo.sp_nt_SaveWorkflowType
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @workflow_id         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.workflow_id') AS INT),
            @workflow_types_name NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.workflow_types_name'),
            @com_sno             INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno')  AS INT),
            @div_sno             INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno')  AS INT),
            @brn_sno             INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno')  AS INT),
            @dept_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT),
            @is_active           CHAR(1)       = ISNULL(JSON_VALUE(@jsonInput, '$.is_active'), 'Y'),
            @created_by          VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @workflow_id IS NULL OR @workflow_types_name IS NULL
    BEGIN
        THROW 50002, N'workflow_id and workflow_types_name are required.', 1;
        RETURN;
    END;

    DECLARE @workflow_name NVARCHAR(50);
    SELECT @workflow_name = LEFT(workflow_name, 50)
    FROM dbo.approval_workflow_master
    WHERE workflow_id = @workflow_id;

    IF @workflow_name IS NULL
    BEGIN
        THROW 50003, N'Workflow not found.', 1;
        RETURN;
    END;

    -- Reactivate rather than duplicate when this exact branch × department
    -- combination was deleted earlier.
    DECLARE @workflow_types_id INT;

    SELECT TOP 1 @workflow_types_id = workflow_types_id
    FROM dbo.workflow_types
    WHERE workflow_id = @workflow_id
      AND is_active = 'N'
      AND ISNULL(brn_sno, -1)  = ISNULL(@brn_sno, -1)
      AND ISNULL(dept_sno, -1) = ISNULL(@dept_sno, -1);

    IF @workflow_types_id IS NOT NULL
    BEGIN
        UPDATE dbo.workflow_types
        SET workflow_types_name = @workflow_types_name,
            workflow_name       = @workflow_name,
            com_sno             = @com_sno,
            div_sno             = @div_sno,
            is_active           = @is_active,
            modified_by         = @created_by,
            modified_at         = GETDATE()
        WHERE workflow_types_id = @workflow_types_id;
    END
    ELSE
    BEGIN
        INSERT INTO dbo.workflow_types (
            workflow_types_name, workflow_id, workflow_name,
            is_active,           brn_sno,     dept_sno,
            com_sno,             div_sno,     created_by
        )
        VALUES (
            @workflow_types_name, @workflow_id, @workflow_name,
            @is_active,           @brn_sno,     @dept_sno,
            @com_sno,             @div_sno,     @created_by
        );

        SET @workflow_types_id = SCOPE_IDENTITY();
    END;

    SELECT @workflow_types_id AS workflow_types_id,
           @workflow_id       AS workflow_id,
           N'SUCCESS'         AS status,
           N'Workflow type saved successfully.' AS message;
END;
GO

-- ── sp_nt_UpdateWorkflowType ──────────────────────────────────────────────
-- Edits one type. Hierarchy columns are only overwritten when supplied.
--
-- @jsonInput: {"workflow_types_id":34,"workflow_types_name":"...","is_active":"Y"}
IF OBJECT_ID('dbo.sp_nt_UpdateWorkflowType', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_UpdateWorkflowType;
GO
CREATE PROCEDURE dbo.sp_nt_UpdateWorkflowType
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @workflow_types_id   INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.workflow_types_id') AS INT),
            @workflow_types_name NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.workflow_types_name'),
            @com_sno             INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno')  AS INT),
            @div_sno             INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno')  AS INT),
            @brn_sno             INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno')  AS INT),
            @dept_sno            INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT),
            @is_active           CHAR(1)       = JSON_VALUE(@jsonInput, '$.is_active'),
            @modified_by         VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.modified_by');

    IF @workflow_types_id IS NULL
    BEGIN
        THROW 50002, N'workflow_types_id is required.', 1;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.workflow_types WHERE workflow_types_id = @workflow_types_id)
    BEGIN
        THROW 50003, N'Workflow type not found.', 1;
        RETURN;
    END;

    DECLARE @before NVARCHAR(MAX) = (
        SELECT workflow_types_name, com_sno, div_sno, brn_sno, dept_sno, is_active
        FROM dbo.workflow_types
        WHERE workflow_types_id = @workflow_types_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    UPDATE dbo.workflow_types
    SET workflow_types_name = ISNULL(@workflow_types_name, workflow_types_name),
        com_sno             = ISNULL(@com_sno,   com_sno),
        div_sno             = ISNULL(@div_sno,   div_sno),
        brn_sno             = ISNULL(@brn_sno,   brn_sno),
        dept_sno            = ISNULL(@dept_sno,  dept_sno),
        is_active           = ISNULL(@is_active, is_active),
        modified_data       = @before,
        modified_by         = @modified_by,
        modified_at         = GETDATE()
    WHERE workflow_types_id = @workflow_types_id;

    SELECT workflow_types_id,
           workflow_id,
           workflow_types_name,
           com_sno, div_sno, brn_sno, dept_sno,
           is_active,
           N'SUCCESS' AS status,
           N'Workflow type updated successfully.' AS message
    FROM dbo.workflow_types
    WHERE workflow_types_id = @workflow_types_id;
END;
GO

-- ── sp_nt_DeleteWorkflowType ──────────────────────────────────────────────
-- Soft-deletes one type and its stages.
--
-- @jsonInput: {"workflow_types_id":34,"modified_by":"1234"}
IF OBJECT_ID('dbo.sp_nt_DeleteWorkflowType', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_DeleteWorkflowType;
GO
CREATE PROCEDURE dbo.sp_nt_DeleteWorkflowType
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @workflow_types_id INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.workflow_types_id') AS INT),
            @modified_by       VARCHAR(20) = JSON_VALUE(@jsonInput, '$.modified_by');

    IF @workflow_types_id IS NULL
    BEGIN
        THROW 50002, N'workflow_types_id is required.', 1;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.workflow_types WHERE workflow_types_id = @workflow_types_id)
    BEGIN
        THROW 50003, N'Workflow type not found.', 1;
        RETURN;
    END;

    DECLARE @stages_deleted INT = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.workflow_stage
        SET is_active   = 'N',
            modified_by = @modified_by,
            modified_at = GETDATE()
        WHERE workflow_types_id = @workflow_types_id
          AND is_active = 'Y';
        SET @stages_deleted = @@ROWCOUNT;

        UPDATE dbo.workflow_types
        SET is_active   = 'N',
            modified_by = @modified_by,
            modified_at = GETDATE()
        WHERE workflow_types_id = @workflow_types_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @workflow_types_id AS workflow_types_id,
           'N'                AS is_active,
           @stages_deleted    AS stages_deleted,
           N'SUCCESS'         AS status,
           N'Workflow type deleted successfully.' AS message;
END;
GO


-- ============================================================
-- workflow_stage
-- ============================================================

-- ── sp_nt_GetWorkflowStages ───────────────────────────────────────────────
-- Active stage rows for one type. @jsonInput: {"workflow_types_id":34}
IF OBJECT_ID('dbo.sp_nt_GetWorkflowStages', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetWorkflowStages;
GO
CREATE PROCEDURE dbo.sp_nt_GetWorkflowStages
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @workflow_types_id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.workflow_types_id') AS INT);

    IF @workflow_types_id IS NULL
    BEGIN
        THROW 50002, N'workflow_types_id is required.', 1;
        RETURN;
    END;

    SELECT stage_id,
           workflow_types_id,
           stage_order_json,
           is_active,
           created_at,
           modified_at
    FROM dbo.workflow_stage
    WHERE workflow_types_id = @workflow_types_id
      AND is_active = 'Y'
    ORDER BY stage_id;
END;
GO

-- ── sp_nt_SaveWorkflowStage ───────────────────────────────────────────────
-- Attaches the stage chain to a type. A type carries a single active stage row
-- holding the whole ordered chain as JSON, so this reuses that row when one is
-- already there instead of stacking duplicates.
--
-- @jsonInput: {"workflow_types_id":34,"stage_order_json":"[{...},{...}]"}
IF OBJECT_ID('dbo.sp_nt_SaveWorkflowStage', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_SaveWorkflowStage;
GO
CREATE PROCEDURE dbo.sp_nt_SaveWorkflowStage
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @workflow_types_id INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.workflow_types_id') AS INT),
            @stage_order_json  NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.stage_order_json'),
            @created_by        VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

    -- stage_order_json may arrive as a JSON string or as a nested array.
    IF @stage_order_json IS NULL
        SET @stage_order_json = JSON_QUERY(@jsonInput, '$.stage_order_json');

    IF @workflow_types_id IS NULL
    BEGIN
        THROW 50002, N'workflow_types_id is required.', 1;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.workflow_types WHERE workflow_types_id = @workflow_types_id)
    BEGIN
        THROW 50003, N'Workflow type not found.', 1;
        RETURN;
    END;

    DECLARE @stage_id INT;

    SELECT TOP 1 @stage_id = stage_id
    FROM dbo.workflow_stage
    WHERE workflow_types_id = @workflow_types_id
      AND is_active = 'Y'
    ORDER BY stage_id;

    IF @stage_id IS NOT NULL
    BEGIN
        UPDATE dbo.workflow_stage
        SET modified_data    = stage_order_json,
            stage_order_json = @stage_order_json,
            modified_by      = @created_by,
            modified_at      = GETDATE()
        WHERE stage_id = @stage_id;
    END
    ELSE
    BEGIN
        INSERT INTO dbo.workflow_stage (workflow_types_id, stage_order_json, is_active, created_by)
        VALUES (@workflow_types_id, @stage_order_json, 'Y', @created_by);

        SET @stage_id = SCOPE_IDENTITY();
    END;

    SELECT @stage_id          AS stage_id,
           @workflow_types_id AS workflow_types_id,
           N'SUCCESS'         AS status,
           N'Workflow stage saved successfully.' AS message;
END;
GO

-- ── sp_nt_UpdateWorkflowStage ─────────────────────────────────────────────
-- Replaces a type's stage chain. Identical upsert to the save procedure — the
-- screen sends the whole chain every time, and a type that somehow lost its
-- stage row still ends up with one rather than silently updating nothing.
--
-- @jsonInput: {"workflow_types_id":34,"stage_order_json":"[{...},{...}]"}
IF OBJECT_ID('dbo.sp_nt_UpdateWorkflowStage', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_UpdateWorkflowStage;
GO
CREATE PROCEDURE dbo.sp_nt_UpdateWorkflowStage
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    DECLARE @workflow_types_id INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.workflow_types_id') AS INT),
            @stage_order_json  NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.stage_order_json'),
            @modified_by       VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.modified_by');

    IF @stage_order_json IS NULL
        SET @stage_order_json = JSON_QUERY(@jsonInput, '$.stage_order_json');

    IF @workflow_types_id IS NULL
    BEGIN
        THROW 50002, N'workflow_types_id is required.', 1;
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.workflow_types WHERE workflow_types_id = @workflow_types_id)
    BEGIN
        THROW 50003, N'Workflow type not found.', 1;
        RETURN;
    END;

    DECLARE @stage_id INT;

    SELECT TOP 1 @stage_id = stage_id
    FROM dbo.workflow_stage
    WHERE workflow_types_id = @workflow_types_id
      AND is_active = 'Y'
    ORDER BY stage_id;

    IF @stage_id IS NOT NULL
    BEGIN
        UPDATE dbo.workflow_stage
        SET modified_data    = stage_order_json,
            stage_order_json = @stage_order_json,
            modified_by      = @modified_by,
            modified_at      = GETDATE()
        WHERE stage_id = @stage_id;
    END
    ELSE
    BEGIN
        INSERT INTO dbo.workflow_stage (workflow_types_id, stage_order_json, is_active, created_by)
        VALUES (@workflow_types_id, @stage_order_json, 'Y', @modified_by);

        SET @stage_id = SCOPE_IDENTITY();
    END;

    SELECT @stage_id          AS stage_id,
           @workflow_types_id AS workflow_types_id,
           N'SUCCESS'         AS status,
           N'Workflow stage updated successfully.' AS message;
END;
GO

-- ── sp_nt_DeleteWorkflowStage ─────────────────────────────────────────────
-- Soft-deletes stage rows, either one by stage_id or every row of a type.
--
-- @jsonInput: {"stage_id":56} or {"workflow_types_id":34}
IF OBJECT_ID('dbo.sp_nt_DeleteWorkflowStage', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_DeleteWorkflowStage;
GO
CREATE PROCEDURE dbo.sp_nt_DeleteWorkflowStage
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @stage_id          INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.stage_id') AS INT),
            @workflow_types_id INT         = TRY_CAST(JSON_VALUE(@jsonInput, '$.workflow_types_id') AS INT),
            @modified_by       VARCHAR(20) = JSON_VALUE(@jsonInput, '$.modified_by');

    IF @stage_id IS NULL AND @workflow_types_id IS NULL
    BEGIN
        THROW 50002, N'stage_id or workflow_types_id is required.', 1;
        RETURN;
    END;

    UPDATE dbo.workflow_stage
    SET is_active   = 'N',
        modified_by = @modified_by,
        modified_at = GETDATE()
    WHERE is_active = 'Y'
      AND (@stage_id IS NULL OR stage_id = @stage_id)
      AND (@workflow_types_id IS NULL OR workflow_types_id = @workflow_types_id);

    SELECT @@ROWCOUNT  AS deleted_count,
           'N'         AS is_active,
           N'SUCCESS'  AS status,
           N'Workflow stage deleted successfully.' AS message;
END;
GO

-- ============================================================
-- After running, confirm all ten procedures resolve:
--
--   SELECT name FROM sys.procedures
--   WHERE name IN ('sp_nt_SaveFullWorkflow','sp_nt_GetWorkflowMasters',
--                  'sp_nt_GetWorkflowByEntity','sp_nt_UpdateWorkflowMaster',
--                  'sp_nt_SaveWorkflowType','sp_nt_GetWorkflowTypes',
--                  'sp_nt_UpdateWorkflowType','sp_nt_SaveWorkflowStage',
--                  'sp_nt_GetWorkflowStages','sp_nt_UpdateWorkflowStage',
--                  'sp_nt_DeleteWorkflow','sp_nt_DeleteWorkflowType',
--                  'sp_nt_DeleteWorkflowStage')
--   ORDER BY name;   -- expect 13 rows
-- ============================================================
