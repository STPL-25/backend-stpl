 CREATE   view vw_workflow_stages
 AS
SELECT
    wt.workflow_types_id,
    wt.workflow_types_name,
    wt.workflow_id,
    wt.workflow_name,
    wt.com_sno,
    wt.div_sno,
    wt.brn_sno,
    wt.dept_sno,
    (
        SELECT stage_order_json
        FROM workflow_stage ws
        WHERE ws.workflow_types_id = wt.workflow_types_id
        FOR JSON PATH
    ) AS stages_json
FROM workflow_types AS wt;