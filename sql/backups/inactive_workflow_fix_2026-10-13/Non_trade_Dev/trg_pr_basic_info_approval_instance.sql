-- ── 8. Create the instance whenever a PR is raised ──────────────────────────
-- A trigger rather than editing every PR-creating procedure (normal, vendor-driven,
-- recurring, agreement-driven). Only pending PRs with a workflow get one.
CREATE   TRIGGER dbo.trg_pr_basic_info_approval_instance
ON dbo.pr_basic_info
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.approval_instance (entity_type, entity_ref_id, workflow_types_id, stages_json, cycle_no, current_seq, status, current_since)
    SELECT 'PurchaseRequisition', i.pr_basic_sno, i.workflow_types_id, ws.stage_order_json, 1, 0, 'P', GETDATE()
    FROM inserted i
    CROSS APPLY (SELECT TOP 1 w.stage_order_json
                 FROM dbo.workflow_stage w
                 WHERE w.workflow_types_id = i.workflow_types_id AND w.is_active = 'Y' AND ISJSON(w.stage_order_json) = 1
                 ORDER BY w.stage_id) ws
    WHERE i.status = 'P' AND i.workflow_types_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.approval_instance a
                      WHERE a.entity_type = 'PurchaseRequisition' AND a.entity_ref_id = i.pr_basic_sno);
END