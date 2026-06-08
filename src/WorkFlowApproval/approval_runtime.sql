-- ============================================================
-- Runtime Approval Movement (Forward / Backward / Resubmit)
-- Works against the workflow definition in workflow_schema.sql
-- (approval_workflow -> workflow_types -> workflow_stage.stage_order_json)
-- ============================================================

-- 1. Live state of one document in the approval flow (one row per request)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'approval_request')
BEGIN
  CREATE TABLE approval_request (
    request_id           INT           NOT NULL PRIMARY KEY IDENTITY(1,1),
    entity_type          NVARCHAR(50)  NOT NULL,   -- e.g. 'PR'
    entity_ref_no        NVARCHAR(50)  NOT NULL,   -- e.g. the pr_no
    workflow_types_id    INT           NOT NULL REFERENCES workflow_types(workflow_types_id),
    current_approver_ecno NVARCHAR(20) NOT NULL,   -- who must act now
    current_stage        NVARCHAR(100) NULL,       -- stage name from JSON
    return_to_ecno       NVARCHAR(20)  NULL,       -- set on BACKWARD; who it must come back to
    status               NVARCHAR(20)  NOT NULL DEFAULT 'PENDING',
                                                   -- PENDING | FORWARDED | SENT_BACK | RESUBMITTED | APPROVED | REJECTED
    created_by           VARCHAR(20)   NULL,
    created_at           DATETIME      NOT NULL DEFAULT GETDATE(),
    modified_at          DATETIME      NULL
  );
END;

-- 2. Audit trail: every action taken on a request
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'approval_request_history')
BEGIN
  CREATE TABLE approval_request_history (
    history_id     INT           NOT NULL PRIMARY KEY IDENTITY(1,1),
    request_id     INT           NOT NULL REFERENCES approval_request(request_id),
    action         NVARCHAR(20)  NOT NULL,   -- APPROVE | REJECT | FORWARD | BACKWARD | RESUBMIT
    from_ecno      NVARCHAR(20)  NOT NULL,
    to_ecno        NVARCHAR(20)  NULL,
    remarks        NVARCHAR(MAX) NULL,
    modified_data  NVARCHAR(MAX) NULL,       -- qty / quotation changes captured on RESUBMIT
    action_at      DATETIME      NOT NULL DEFAULT GETDATE()
  );
END;

GO

-- ============================================================
-- sp_nt_ApprovalAction
-- One entry point for all movements. Validates the action against
-- the current approver's can_forward / can_backward flags in the
-- stage JSON before moving the document.
--
-- Input JSON:
--   {
--     "request_id": 123,
--     "action": "FORWARD" | "BACKWARD" | "RESUBMIT" | "APPROVE" | "REJECT",
--     "actor_ecno": "SHO222",        -- person performing the action
--     "target_ecno": "EMP9001",      -- required for BACKWARD (who to transfer to)
--     "remarks": "need clarification on qty",
--     "modified_data": "{...}"        -- optional; carried on RESUBMIT
--   }
-- ============================================================
CREATE OR ALTER PROCEDURE sp_nt_ApprovalAction
  @jsonInput NVARCHAR(MAX)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE
    @request_id   INT          = CAST(JSON_VALUE(@jsonInput, '$.request_id') AS INT),
    @action       NVARCHAR(20) = UPPER(JSON_VALUE(@jsonInput, '$.action')),
    @actor        NVARCHAR(20) = JSON_VALUE(@jsonInput, '$.actor_ecno'),
    @target       NVARCHAR(20) = JSON_VALUE(@jsonInput, '$.target_ecno'),
    @remarks      NVARCHAR(MAX)= JSON_VALUE(@jsonInput, '$.remarks'),
    @modified     NVARCHAR(MAX)= JSON_QUERY(@jsonInput, '$.modified_data');

  DECLARE
    @wt_id        INT,
    @cur_approver NVARCHAR(20),
    @return_to    NVARCHAR(20),
    @stage_json   NVARCHAR(MAX);

  -- Load the live request
  SELECT
    @wt_id        = workflow_types_id,
    @cur_approver = current_approver_ecno,
    @return_to    = return_to_ecno
  FROM approval_request
  WHERE request_id = @request_id;

  IF @wt_id IS NULL
  BEGIN
    RAISERROR('Request not found.', 16, 1); RETURN;
  END;

  -- The actor must be the person the document is currently sitting with
  IF @actor <> @cur_approver
  BEGIN
    RAISERROR('You are not the current approver for this request.', 16, 1); RETURN;
  END;

  -- Pull the actor's stage config (can_forward / can_backward / next stage)
  -- from the active workflow_stage JSON for this workflow type.
  DECLARE
    @can_forward  CHAR(1),
    @can_backward CHAR(1),
    @next_ecno    NVARCHAR(20),
    @stage_name   NVARCHAR(100);

  SELECT TOP 1
    @can_forward  = JSON_VALUE(s.[value], '$.can_forward'),
    @can_backward = JSON_VALUE(s.[value], '$.can_backward'),
    @next_ecno    = JSON_VALUE(s.[value], '$.next_approver_ecno'),
    @stage_name   = JSON_VALUE(s.[value], '$.stage')
  FROM workflow_stage ws
  CROSS APPLY OPENJSON(ws.stage_order_json) AS s
  WHERE ws.workflow_types_id = @wt_id
    AND ws.is_active = 'Y'
    AND JSON_VALUE(s.[value], '$.approver_ecno') = @actor;

  BEGIN TRY
    BEGIN TRANSACTION;

    IF @action = 'FORWARD'
    BEGIN
      -- Escalate up to the next stage for clarification
      IF ISNULL(@can_forward, 'N') <> 'Y'
      BEGIN
        RAISERROR('Forwarding is not permitted at this stage.', 16, 1); RETURN;
      END;
      IF NULLIF(@next_ecno, '') IS NULL
      BEGIN
        RAISERROR('No next approver defined to forward to.', 16, 1); RETURN;
      END;

      UPDATE approval_request
      SET current_approver_ecno = @next_ecno,
          current_stage         = @stage_name,
          return_to_ecno        = NULL,        -- forward is upward, not a round-trip
          status                = 'FORWARDED',
          modified_at           = GETDATE()
      WHERE request_id = @request_id;

      INSERT INTO approval_request_history (request_id, action, from_ecno, to_ecno, remarks)
      VALUES (@request_id, 'FORWARD', @actor, @next_ecno, @remarks);
    END

    ELSE IF @action = 'BACKWARD'
    BEGIN
      -- Transfer down to a chosen person; remember to return it to me
      IF ISNULL(@can_backward, 'N') <> 'Y'
      BEGIN
        RAISERROR('Backward transfer is not permitted at this stage.', 16, 1); RETURN;
      END;
      IF NULLIF(@target, '') IS NULL
      BEGIN
        RAISERROR('Select a person to transfer the request to.', 16, 1); RETURN;
      END;

      UPDATE approval_request
      SET current_approver_ecno = @target,
          return_to_ecno        = @actor,      -- comes back to whoever sent it
          status                = 'SENT_BACK',
          modified_at           = GETDATE()
      WHERE request_id = @request_id;

      INSERT INTO approval_request_history (request_id, action, from_ecno, to_ecno, remarks)
      VALUES (@request_id, 'BACKWARD', @actor, @target, @remarks);
    END

    ELSE IF @action = 'RESUBMIT'
    BEGIN
      -- The transferred person sends it back (with clarification / changed qty / quotation)
      IF @return_to IS NULL
      BEGIN
        RAISERROR('This request was not transferred to you for resubmission.', 16, 1); RETURN;
      END;

      UPDATE approval_request
      SET current_approver_ecno = @return_to,
          return_to_ecno        = NULL,
          status                = 'RESUBMITTED',
          modified_at           = GETDATE()
      WHERE request_id = @request_id;

      INSERT INTO approval_request_history (request_id, action, from_ecno, to_ecno, remarks, modified_data)
      VALUES (@request_id, 'RESUBMIT', @actor, @return_to, @remarks, @modified);
    END

    ELSE IF @action IN ('APPROVE', 'REJECT')
    BEGIN
      UPDATE approval_request
      SET status      = CASE WHEN @action = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,
          modified_at = GETDATE()
      WHERE request_id = @request_id;

      INSERT INTO approval_request_history (request_id, action, from_ecno, remarks)
      VALUES (@request_id, @action, @actor, @remarks);
    END

    ELSE
    BEGIN
      RAISERROR('Unknown action.', 16, 1); RETURN;
    END;

    COMMIT TRANSACTION;

    -- Return the updated state to the caller
    SELECT request_id, current_approver_ecno, return_to_ecno, status
    FROM approval_request WHERE request_id = @request_id;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
  END CATCH;
END;
GO
