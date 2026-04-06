-- ============================================================
-- Workflow Approval DB Schema
-- Tables: approval_workflow_master, workflow_types, workflow_stage
-- ============================================================

-- 1. approval_workflow_master
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'approval_workflow_master')
BEGIN
  CREATE TABLE approval_workflow_master (
    workflow_id     INT           NOT NULL PRIMARY KEY IDENTITY(1,1),
    workflow_name   NVARCHAR(100) NOT NULL,
    workflow_code   NVARCHAR(50)  NOT NULL UNIQUE,
    entity_type     NVARCHAR(50)  NOT NULL,
    description     NVARCHAR(500) NULL,
    is_active       CHAR(1)       NOT NULL DEFAULT 'Y',
    created_by      VARCHAR(20)   NULL,
    created_at      DATETIME      NOT NULL DEFAULT GETDATE(),
    modified_data   NVARCHAR(MAX) NULL,
    modified_by     VARCHAR(20)   NULL,
    modified_at     DATETIME      NULL
  );
END;

-- 2. workflow_types
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'workflow_types')
BEGIN
  CREATE TABLE workflow_types (
    workflow_types_id   INT           NOT NULL PRIMARY KEY IDENTITY(1,1),
    workflow_types_name NVARCHAR(100) NOT NULL,
    workflow_id         INT           NOT NULL REFERENCES approval_workflow_master(workflow_id),
    workflow_name       NVARCHAR(50)  NULL,
    is_active           CHAR(1)       NOT NULL DEFAULT 'Y',
    brn_sno             INT           NOT NULL,  -- FK -> branch_master
    dept_sno            INT           NOT NULL,  -- FK -> dept_master
    created_by          VARCHAR(20)   NULL,
    created_at          DATETIME      NOT NULL DEFAULT GETDATE(),
    modified_data       NVARCHAR(MAX) NULL,
    modified_by         VARCHAR(20)   NULL,
    modified_at         DATETIME      NULL
  );
END;

-- 3. workflow_stage
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'workflow_stage')
BEGIN
  CREATE TABLE workflow_stage (
    stage_id            INT           NOT NULL PRIMARY KEY IDENTITY(1,1),
    workflow_types_id   INT           NOT NULL REFERENCES workflow_types(workflow_types_id),
    stage_order_json    NVARCHAR(MAX) NOT NULL,  -- JSON: { stages, approvers, conditions }
    is_active           CHAR(1)       NOT NULL DEFAULT 'Y',
    created_by          VARCHAR(20)   NULL,
    created_at          DATETIME      NOT NULL DEFAULT GETDATE(),
    modified_data       NVARCHAR(MAX) NULL,
    modified_by         VARCHAR(20)   NULL,
    modified_at         DATETIME      NULL
  );
END;

GO

-- ============================================================
-- sp_nt_SaveFullWorkflow
-- Compatible with SQL Server 2016+ (uses OPENJSON, no JSON_ARRAY_LENGTH)
-- Input: jsonInput (NVARCHAR MAX) containing:
--   {
--     workflow_name, workflow_code, entity_type, description, is_active, created_by,
--     workflow_types: [
--       { workflow_types_name, brn_sno, dept_sno, is_active, stage_order_json }
--     ]
--   }
-- ============================================================
CREATE OR ALTER PROCEDURE sp_nt_SaveFullWorkflow
  @jsonInput NVARCHAR(MAX)
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @workflow_id  INT;
  DECLARE @wt_id        INT;
  DECLARE @workflow_name  NVARCHAR(100);
  DECLARE @created_by     VARCHAR(20);
  DECLARE @types          NVARCHAR(MAX);

  -- Read scalar header fields once
  SET @workflow_name = JSON_VALUE(@jsonInput, '$.workflow_name');
  SET @created_by    = JSON_VALUE(@jsonInput, '$.created_by');
  SET @types         = JSON_QUERY(@jsonInput, '$.workflow_types');

  -- 1. Insert approval_workflow (actual table name in DB)
  INSERT INTO approval_workflow (
    workflow_name, workflow_code, entity_type, description, is_active, created_by
  )
  VALUES (
    @workflow_name,
    JSON_VALUE(@jsonInput, '$.workflow_code'),
    JSON_VALUE(@jsonInput, '$.entity_type'),
    JSON_VALUE(@jsonInput, '$.description'),
    ISNULL(JSON_VALUE(@jsonInput, '$.is_active'), 'Y'),
    @created_by
  );

  SET @workflow_id = SCOPE_IDENTITY();

  -- 2. Iterate workflow_types using OPENJSON (SQL Server 2016+)
  DECLARE
    @wt_name        NVARCHAR(100),
    @wt_is_active   CHAR(1),
    @wt_brn         INT,
    @wt_dept        INT,
    @wt_stage_json  NVARCHAR(MAX);

  DECLARE type_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT
      JSON_VALUE(t.[value], '$.workflow_types_name'),
      ISNULL(JSON_VALUE(t.[value], '$.is_active'), 'Y'),
      CAST(JSON_VALUE(t.[value], '$.brn_sno')  AS INT),
      CAST(JSON_VALUE(t.[value], '$.dept_sno') AS INT),
      JSON_VALUE(t.[value], '$.stage_order_json')
    FROM OPENJSON(@types) AS t;

  OPEN type_cur;
  FETCH NEXT FROM type_cur INTO @wt_name, @wt_is_active, @wt_brn, @wt_dept, @wt_stage_json;

  WHILE @@FETCH_STATUS = 0
  BEGIN
    -- Insert workflow_types row
    INSERT INTO workflow_types (
      workflow_types_name, workflow_id, workflow_name, is_active, brn_sno, dept_sno, created_by
    )
    VALUES (
      @wt_name, @workflow_id, @workflow_name, @wt_is_active, @wt_brn, @wt_dept, @created_by
    );

    SET @wt_id = SCOPE_IDENTITY();

    -- Insert workflow_stage row (stage_order_json is already a JSON string)
    INSERT INTO workflow_stage (workflow_types_id, stage_order_json, is_active, created_by)
    VALUES (@wt_id, @wt_stage_json, 'Y', @created_by);

    FETCH NEXT FROM type_cur INTO @wt_name, @wt_is_active, @wt_brn, @wt_dept, @wt_stage_json;
  END;

  CLOSE type_cur;
  DEALLOCATE type_cur;

  -- Return the new workflow_id to frontend
  SELECT @workflow_id AS workflow_id;
END;

GO

-- ============================================================
-- sp_nt_GetWorkflowMasters
-- ============================================================
CREATE OR ALTER PROCEDURE sp_nt_GetWorkflowMasters
AS
BEGIN
  SET NOCOUNT ON;
  SELECT * FROM approval_workflow WHERE is_active = 'Y' ORDER BY created_at DESC;
END;

GO

-- ============================================================
-- sp_nt_GetWorkflowByEntity
-- Input: jsonInput { entity_type }
-- ============================================================
CREATE OR ALTER PROCEDURE sp_nt_GetWorkflowByEntity
  @jsonInput NVARCHAR(MAX)
AS
BEGIN
  SET NOCOUNT ON;
  SELECT * FROM approval_workflow
  WHERE entity_type = JSON_VALUE(@jsonInput, '$.entity_type')
    AND is_active = 'Y';
END;

GO

-- ============================================================
-- sp_nt_UpdateWorkflowMaster
-- Input: jsonInput { workflow_id, workflow_name, workflow_code, entity_type, description, is_active, modified_by }
-- ============================================================
CREATE OR ALTER PROCEDURE sp_nt_UpdateWorkflowMaster
  @jsonInput NVARCHAR(MAX)
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE approval_workflow SET
    workflow_name = ISNULL(JSON_VALUE(@jsonInput, '$.workflow_name'), workflow_name),
    workflow_code = ISNULL(JSON_VALUE(@jsonInput, '$.workflow_code'), workflow_code),
    entity_type   = ISNULL(JSON_VALUE(@jsonInput, '$.entity_type'),   entity_type),
    description   = JSON_VALUE(@jsonInput, '$.description'),
    is_active     = ISNULL(JSON_VALUE(@jsonInput, '$.is_active'),     is_active),
    modified_by   = JSON_VALUE(@jsonInput, '$.modified_by'),
    modified_at   = GETDATE()
  WHERE workflow_id = CAST(JSON_VALUE(@jsonInput, '$.workflow_id') AS INT);

  SELECT workflow_id FROM approval_workflow
  WHERE workflow_id = CAST(JSON_VALUE(@jsonInput, '$.workflow_id') AS INT);
END;

GO

-- ============================================================
-- sp_nt_SaveWorkflowType
-- Input: jsonInput { workflow_id, workflow_types_name, brn_sno, dept_sno, is_active, created_by }
-- ============================================================
CREATE OR ALTER PROCEDURE sp_nt_SaveWorkflowType
  @jsonInput NVARCHAR(MAX)
AS
BEGIN
  SET NOCOUNT ON;
  INSERT INTO workflow_types (workflow_types_name, workflow_id, workflow_name, is_active, brn_sno, dept_sno, created_by)
  SELECT
    JSON_VALUE(@jsonInput, '$.workflow_types_name'),
    CAST(JSON_VALUE(@jsonInput, '$.workflow_id') AS INT),
    (SELECT workflow_name FROM approval_workflow WHERE workflow_id = CAST(JSON_VALUE(@jsonInput, '$.workflow_id') AS INT)),
    ISNULL(JSON_VALUE(@jsonInput, '$.is_active'), 'Y'),
    CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT),
    CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT),
    JSON_VALUE(@jsonInput, '$.created_by');

  SELECT SCOPE_IDENTITY() AS workflow_types_id;
END;

GO

-- ============================================================
-- sp_nt_GetWorkflowTypes
-- Input: jsonInput { workflow_id }
-- ============================================================
CREATE OR ALTER PROCEDURE sp_nt_GetWorkflowTypes
  @jsonInput NVARCHAR(MAX)
AS
BEGIN
  SET NOCOUNT ON;
  SELECT * FROM workflow_types
  WHERE workflow_id = CAST(JSON_VALUE(@jsonInput, '$.workflow_id') AS INT)
    AND is_active = 'Y';
END;

GO

-- ============================================================
-- sp_nt_UpdateWorkflowType
-- Input: jsonInput { workflow_types_id, workflow_types_name, brn_sno, dept_sno, is_active, modified_by }
-- ============================================================
CREATE OR ALTER PROCEDURE sp_nt_UpdateWorkflowType
  @jsonInput NVARCHAR(MAX)
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE workflow_types SET
    workflow_types_name = ISNULL(JSON_VALUE(@jsonInput, '$.workflow_types_name'), workflow_types_name),
    brn_sno    = ISNULL(CAST(JSON_VALUE(@jsonInput, '$.brn_sno')  AS INT), brn_sno),
    dept_sno   = ISNULL(CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT), dept_sno),
    is_active  = ISNULL(JSON_VALUE(@jsonInput, '$.is_active'),  is_active),
    modified_by = JSON_VALUE(@jsonInput, '$.modified_by'),
    modified_at = GETDATE()
  WHERE workflow_types_id = CAST(JSON_VALUE(@jsonInput, '$.workflow_types_id') AS INT);

  SELECT workflow_types_id FROM workflow_types
  WHERE workflow_types_id = CAST(JSON_VALUE(@jsonInput, '$.workflow_types_id') AS INT);
END;

GO

-- ============================================================
-- sp_nt_SaveWorkflowStage
-- Input: jsonInput { workflow_types_id, stage_order_json, is_active, created_by }
-- ============================================================
CREATE OR ALTER PROCEDURE sp_nt_SaveWorkflowStage
  @jsonInput NVARCHAR(MAX)
AS
BEGIN
  SET NOCOUNT ON;
  INSERT INTO workflow_stage (workflow_types_id, stage_order_json, is_active, created_by)
  VALUES (
    CAST(JSON_VALUE(@jsonInput, '$.workflow_types_id') AS INT),
    JSON_VALUE(@jsonInput, '$.stage_order_json'),
    ISNULL(JSON_VALUE(@jsonInput, '$.is_active'), 'Y'),
    JSON_VALUE(@jsonInput, '$.created_by')
  );

  SELECT SCOPE_IDENTITY() AS stage_id;
END;

GO

-- ============================================================
-- sp_nt_GetWorkflowStages
-- Input: jsonInput { workflow_types_id }
-- ============================================================
CREATE OR ALTER PROCEDURE sp_nt_GetWorkflowStages
  @jsonInput NVARCHAR(MAX)
AS
BEGIN
  SET NOCOUNT ON;
  SELECT * FROM workflow_stage
  WHERE workflow_types_id = CAST(JSON_VALUE(@jsonInput, '$.workflow_types_id') AS INT)
    AND is_active = 'Y';
END;

GO

-- ============================================================
-- sp_nt_UpdateWorkflowStage
-- Input: jsonInput { stage_id, stage_order_json, is_active, modified_by }
-- ============================================================
CREATE OR ALTER PROCEDURE sp_nt_UpdateWorkflowStage
  @jsonInput NVARCHAR(MAX)
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE workflow_stage SET
    stage_order_json = ISNULL(JSON_VALUE(@jsonInput, '$.stage_order_json'), stage_order_json),
    is_active        = ISNULL(JSON_VALUE(@jsonInput, '$.is_active'),        is_active),
    modified_by      = JSON_VALUE(@jsonInput, '$.modified_by'),
    modified_at      = GETDATE()
  WHERE stage_id = CAST(JSON_VALUE(@jsonInput, '$.stage_id') AS INT);

  SELECT stage_id FROM workflow_stage
  WHERE stage_id = CAST(JSON_VALUE(@jsonInput, '$.stage_id') AS INT);
END;

GO
