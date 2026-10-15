-- The one call a feature makes to find its workflow. Scope NULL = no org scope (lowest id wins).
CREATE   PROCEDURE dbo.sp_nt_ResolveWorkflow
    @module VARCHAR(50), @variant VARCHAR(50) = NULL,
    @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL,
    @workflow_types_id INT OUTPUT,
    @first_approver VARCHAR(30) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @entity VARCHAR(50) = dbo.fn_resolve_approval_entity(@module, @variant);

    SELECT TOP 1 @workflow_types_id = wt.workflow_types_id
    FROM dbo.workflow_types wt
    JOIN dbo.approval_workflow_master a ON a.workflow_id = wt.workflow_id
    WHERE a.entity_type = @entity AND a.is_active = 'Y' AND wt.is_active = 'Y'
      AND (@com_sno IS NULL OR wt.com_sno = @com_sno) AND (@div_sno IS NULL OR wt.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR wt.brn_sno = @brn_sno) AND (@dept_sno IS NULL OR wt.dept_sno = @dept_sno)
    ORDER BY wt.workflow_types_id;

    IF @workflow_types_id IS NULL
        THROW 52110, N'No approval workflow is configured for this request type and organisation scope.', 1;

    SELECT @first_approver = JSON_VALUE(s2.value, '$.approver_ecno')
    FROM dbo.vw_workflow_stages AS ws
    CROSS APPLY OPENJSON(ws.stages_json) AS s
    CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
    WHERE ws.workflow_types_id = @workflow_types_id AND s.[key] = '0' AND s2.[key] = '0';

    IF @first_approver IS NULL
        THROW 52111, N'The first stage of the approval workflow has no approver.', 1;
END;