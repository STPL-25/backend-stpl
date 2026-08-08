-- ============================================================
-- workflow_types — add a description column
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend/src/WorkFlowApproval (mounted at /api/workflow_approval)
--
-- workflow_types already has a name column (workflow_types_name) but no
-- description column. This adds workflow_types_description and updates the
-- four procedures that read/write workflow_types rows so the Approval
-- Workflow page can capture and display a description per type.
--
-- Confirmed against the live server before writing this file (OBJECT_DEFINITION
-- pulled directly): sp_nt_GetWorkflowTypes already nests workflow_types_name from
-- dbo.workflow_types, not from dbo.approval_workflow_master, and
-- sp_nt_SaveFullWorkflow already inserts workflow_types_name from the per-type
-- JSON, not from the workflow master row. Nothing here changes that — this
-- migration only adds the missing description column and column-list changes to
-- carry it through the same four procedures.
-- ============================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.workflow_types')
      AND name = 'workflow_types_description'
)
BEGIN
    ALTER TABLE dbo.workflow_types
        ADD workflow_types_description NVARCHAR(500) NULL;
END;
GO


-- ── sp_nt_SaveWorkflowType (REPLACED) ─────────────────────────────────────
-- @jsonInput: {"workflow_id":12,"workflow_types_name":"Standard",
--              "workflow_types_description":"...","com_sno":1,"div_sno":2,
--              "brn_sno":3,"dept_sno":4,"is_active":"Y"}
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

    DECLARE @workflow_id                INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.workflow_id') AS INT),
            @workflow_types_name        NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.workflow_types_name'),
            @workflow_types_description NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.workflow_types_description'),
            @com_sno                    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno')  AS INT),
            @div_sno                    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno')  AS INT),
            @brn_sno                    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno')  AS INT),
            @dept_sno                   INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT),
            @is_active                  CHAR(1)       = ISNULL(JSON_VALUE(@jsonInput, '$.is_active'), 'Y'),
            @created_by                 VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');

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
        SET workflow_types_name        = @workflow_types_name,
            workflow_types_description = @workflow_types_description,
            workflow_name               = @workflow_name,
            com_sno                     = @com_sno,
            div_sno                     = @div_sno,
            is_active                   = @is_active,
            modified_by                 = @created_by,
            modified_at                 = GETDATE()
        WHERE workflow_types_id = @workflow_types_id;
    END
    ELSE
    BEGIN
        INSERT INTO dbo.workflow_types (
            workflow_types_name, workflow_types_description, workflow_id, workflow_name,
            is_active,           brn_sno,                     dept_sno,
            com_sno,             div_sno,                     created_by
        )
        VALUES (
            @workflow_types_name, @workflow_types_description, @workflow_id, @workflow_name,
            @is_active,           @brn_sno,                     @dept_sno,
            @com_sno,             @div_sno,                     @created_by
        );

        SET @workflow_types_id = SCOPE_IDENTITY();
    END;

    SELECT @workflow_types_id AS workflow_types_id,
           @workflow_id       AS workflow_id,
           N'SUCCESS'         AS status,
           N'Workflow type saved successfully.' AS message;
END;
GO

-- ── sp_nt_UpdateWorkflowType (REPLACED) ───────────────────────────────────
-- @jsonInput: {"workflow_types_id":34,"workflow_types_name":"...",
--              "workflow_types_description":"...","is_active":"Y"}
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

    DECLARE @workflow_types_id          INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.workflow_types_id') AS INT),
            @workflow_types_name        NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.workflow_types_name'),
            @workflow_types_description NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.workflow_types_description'),
            @com_sno                    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno')  AS INT),
            @div_sno                    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno')  AS INT),
            @brn_sno                    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno')  AS INT),
            @dept_sno                   INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT),
            @is_active                  CHAR(1)       = JSON_VALUE(@jsonInput, '$.is_active'),
            @modified_by                VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.modified_by');

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
        SELECT workflow_types_name, workflow_types_description, com_sno, div_sno, brn_sno, dept_sno, is_active
        FROM dbo.workflow_types
        WHERE workflow_types_id = @workflow_types_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    UPDATE dbo.workflow_types
    SET workflow_types_name        = ISNULL(@workflow_types_name, workflow_types_name),
        workflow_types_description = ISNULL(@workflow_types_description, workflow_types_description),
        com_sno                    = ISNULL(@com_sno,   com_sno),
        div_sno                    = ISNULL(@div_sno,   div_sno),
        brn_sno                    = ISNULL(@brn_sno,   brn_sno),
        dept_sno                   = ISNULL(@dept_sno,  dept_sno),
        is_active                  = ISNULL(@is_active, is_active),
        modified_data              = @before,
        modified_by                = @modified_by,
        modified_at                = GETDATE()
    WHERE workflow_types_id = @workflow_types_id;

    SELECT workflow_types_id,
           workflow_id,
           workflow_types_name,
           workflow_types_description,
           com_sno, div_sno, brn_sno, dept_sno,
           is_active,
           N'SUCCESS' AS status,
           N'Workflow type updated successfully.' AS message
    FROM dbo.workflow_types
    WHERE workflow_types_id = @workflow_types_id;
END;
GO

-- ── sp_nt_GetWorkflowTypes (REPLACED) ─────────────────────────────────────
-- Same shape as before (workflow master header + nested workflow_types +
-- nested stages, all via FOR JSON PATH), with workflow_types_description
-- added to the nested workflow_types projection.
IF OBJECT_ID('dbo.sp_nt_GetWorkflowTypes', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetWorkflowTypes;
GO
CREATE PROCEDURE dbo.sp_nt_GetWorkflowTypes
    @workflow_id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        awm.workflow_id,
        awm.workflow_name,
        awm.workflow_code,
        awm.entity_type,
        awm.description,
        awm.is_active,
        awm.created_at,
        (
            SELECT
                wt.workflow_types_id,
                wt.workflow_types_name,
                wt.workflow_types_description,
                wt.com_sno,
                wt.div_sno,
                wt.brn_sno,
                wt.dept_sno,
                wt.is_active,
                wt.created_at,
                (
                    SELECT
                        ws.stage_id,
                        ws.stage_order_json,
                        ws.is_active,
                        ws.created_at
                    FROM workflow_stage ws
                    WHERE ws.workflow_types_id = wt.workflow_types_id
                      AND ws.is_active = 'Y'
                    FOR JSON PATH
                ) AS stages
            FROM workflow_types wt
            WHERE wt.workflow_id = awm.workflow_id
              AND wt.is_active = 'Y'
            FOR JSON PATH
        ) AS workflow_types
    FROM approval_workflow_master awm
    WHERE awm.is_active = 'Y'
      AND (@workflow_id IS NULL OR awm.workflow_id = @workflow_id)
    FOR JSON PATH, ROOT('workflows');
END;
GO

-- ── sp_nt_SaveFullWorkflow (REPLACED) ─────────────────────────────────────
-- Identical to the live version, with workflow_types_description staged
-- through #WFTypes and carried into the workflow_types INSERT.
IF OBJECT_ID('dbo.sp_nt_SaveFullWorkflow', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_SaveFullWorkflow;
GO
CREATE PROCEDURE dbo.sp_nt_SaveFullWorkflow
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ----------------------------------------------------------------
    -- 1. Validate JSON
    ----------------------------------------------------------------
    IF ISJSON(@jsonInput) = 0
    BEGIN
        THROW 50001, N'Invalid JSON payload provided.', 1;
        RETURN;
    END;

    ----------------------------------------------------------------
    -- 2. Extract header fields
    ----------------------------------------------------------------
    DECLARE
        @workflow_name  NVARCHAR(200) = JSON_VALUE(@jsonInput, '$.workflow_name'),
        @entity_type    NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.entity_type'),
        @description    NVARCHAR(MAX) = JSON_VALUE(@jsonInput, '$.description'),
        @is_active      CHAR(1)       = ISNULL(JSON_VALUE(@jsonInput, '$.is_active'), 'Y'),
        @created_by     NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.created_by');

    ----------------------------------------------------------------
    -- 3. Required-field guard
    ----------------------------------------------------------------
    IF @workflow_name IS NULL OR @entity_type IS NULL
    BEGIN
        THROW 50002, N'workflow_name and entity_type are required fields.', 1;
        RETURN;
    END;

    ----------------------------------------------------------------
    -- 4. Auto-generate workflow_code (concurrency-safe)
    ----------------------------------------------------------------
    DECLARE
        @workflow_code  NVARCHAR(100),
        @code_prefix    NVARCHAR(50),
        @next_seq       INT;

    SET @code_prefix = N'WF_' + UPPER(@entity_type) + N'_';

    MERGE dbo.workflow_code_sequence WITH (HOLDLOCK) AS target
    USING (SELECT UPPER(@entity_type) AS entity_type) AS source
        ON target.entity_type = source.entity_type
    WHEN MATCHED THEN
        UPDATE SET last_seq = last_seq + 1
    WHEN NOT MATCHED THEN
        INSERT (entity_type, last_seq) VALUES (source.entity_type, 1);

    SELECT @next_seq = last_seq
    FROM   dbo.workflow_code_sequence
    WHERE  entity_type = UPPER(@entity_type);

    SET @workflow_code = @code_prefix + RIGHT('000' + CAST(@next_seq AS NVARCHAR(10)), 3);

    ----------------------------------------------------------------
    -- 5. Parse workflow_types array
    ----------------------------------------------------------------
    DECLARE @types NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.workflow_types');

    IF @types IS NULL OR (SELECT COUNT(*) FROM OPENJSON(@types)) = 0
    BEGIN
        THROW 50004, N'workflow_types array is empty or missing.', 1;
        RETURN;
    END;

    ----------------------------------------------------------------
    -- 6. Stage workflow_types rows into temp table
    ----------------------------------------------------------------
    IF OBJECT_ID('tempdb..#WFTypes') IS NOT NULL
        DROP TABLE #WFTypes;

    CREATE TABLE #WFTypes (
        row_num                    INT IDENTITY(1,1) PRIMARY KEY,
        arr_key                    INT,
        workflow_types_name        NVARCHAR(200),
        workflow_types_description NVARCHAR(500),
        brn_sno                    INT,
        dept_sno                   INT,
        com_sno                    INT,
        div_sno                    INT,
        is_active                  CHAR(1),
        stage_order_json           NVARCHAR(MAX),
        wt_id                      INT NULL
    );

    INSERT INTO #WFTypes (
        arr_key,
        workflow_types_name,
        workflow_types_description,
        brn_sno,
        dept_sno,
        com_sno,
        div_sno,
        is_active,
        stage_order_json
    )
    SELECT
        CAST(wt.[key] AS INT) AS arr_key,
        JSON_VALUE(wt.value, '$.workflow_types_name') AS workflow_types_name,
        JSON_VALUE(wt.value, '$.workflow_types_description') AS workflow_types_description,
        CAST(JSON_VALUE(wt.value, '$.brn_sno')  AS INT) AS brn_sno,
        CAST(JSON_VALUE(wt.value, '$.dept_sno') AS INT) AS dept_sno,
        CAST(JSON_VALUE(wt.value, '$.com_sno')  AS INT) AS com_sno,
        CAST(JSON_VALUE(wt.value, '$.div_sno')  AS INT) AS div_sno,
        ISNULL(JSON_VALUE(wt.value, '$.is_active'), 'Y') AS is_active,
        JSON_VALUE(wt.value, '$.stage_order_json') AS stage_order_json
    FROM OPENJSON(@types) AS wt;

    ----------------------------------------------------------------
    -- 7. Main transaction
    ----------------------------------------------------------------
    DECLARE @workflow_id INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        ------------------------------------------------------------
        -- 7.1 Insert workflow master
        ------------------------------------------------------------
        INSERT INTO dbo.approval_workflow_master (
            workflow_name, workflow_code, entity_type,
            description,   is_active,     created_by
        )
        VALUES (
            @workflow_name, @workflow_code, @entity_type,
            @description,   @is_active,     @created_by
        );

        SET @workflow_id = SCOPE_IDENTITY();

        ------------------------------------------------------------
        -- 7.2 Insert workflow_types row by row
        ------------------------------------------------------------
        DECLARE
            @cur_row        INT = 1,
            @total_rows     INT = (SELECT COUNT(*) FROM #WFTypes),
            @wt_id          INT,
            @wt_name        NVARCHAR(200),
            @wt_description NVARCHAR(500),
            @wt_brn         INT,
            @wt_dept        INT,
            @wt_com         INT,
            @wt_div         INT,
            @wt_active      CHAR(1),
            @wt_stage_json  NVARCHAR(MAX);

        WHILE @cur_row <= @total_rows
        BEGIN
            SELECT
                @wt_name        = workflow_types_name,
                @wt_description = workflow_types_description,
                @wt_brn         = brn_sno,
                @wt_dept        = dept_sno,
                @wt_com         = com_sno,
                @wt_div         = div_sno,
                @wt_active      = is_active,
                @wt_stage_json  = stage_order_json
            FROM #WFTypes
            WHERE row_num = @cur_row;

            -- Insert into workflow_types
            INSERT INTO dbo.workflow_types (
                workflow_types_name, workflow_types_description, workflow_id,  workflow_name,
                is_active,           brn_sno,                     dept_sno,
                com_sno,             div_sno,                     created_by
            )
            VALUES (
                @wt_name,   @wt_description, @workflow_id, @workflow_name,
                @wt_active, @wt_brn,         @wt_dept,
                @wt_com,    @wt_div,         @created_by
            );

            SET @wt_id = SCOPE_IDENTITY();

            UPDATE #WFTypes
            SET    wt_id = @wt_id
            WHERE  row_num = @cur_row;

            -- Insert into workflow_stage
            INSERT INTO dbo.workflow_stage (
                workflow_types_id, stage_order_json, is_active, created_by
            )
            VALUES (
                @wt_id,
                @wt_stage_json,
                'Y',
                @created_by
            );

            SET @cur_row = @cur_row + 1;
        END;

        DROP TABLE #WFTypes;

        COMMIT TRANSACTION;

        ------------------------------------------------------------
        -- 8. Success response
        ------------------------------------------------------------
        SELECT
            @workflow_id   AS workflow_id,
            @workflow_code AS workflow_code,
            @workflow_name AS workflow_name,
            N'SUCCESS'     AS status,
            N'Workflow saved successfully.' AS message;

    END TRY
    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        IF OBJECT_ID('tempdb..#WFTypes') IS NOT NULL
            DROP TABLE #WFTypes;

        DECLARE
            @ErrMsg   NVARCHAR(4000) = ERROR_MESSAGE(),
            @ErrSev   INT            = ERROR_SEVERITY(),
            @ErrState INT            = ERROR_STATE(),
            @ErrLine  INT            = ERROR_LINE();

        SELECT
            NULL     AS workflow_id,
            NULL     AS workflow_code,
            N'ERROR' AS status,
            @ErrMsg  AS message,
            @ErrLine AS error_line;

        THROW;

    END CATCH;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS
--   WHERE TABLE_NAME = 'workflow_types' AND COLUMN_NAME = 'workflow_types_description';
-- ============================================================
