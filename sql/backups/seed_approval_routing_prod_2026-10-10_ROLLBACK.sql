-- Undo sql/126 on Non_Trade (all four tables were empty and entity_master.route_module_code all NULL before).
BEGIN TRAN;
DELETE FROM dbo.approval_entity_route;
DELETE FROM dbo.approval_route_variant;
DELETE FROM dbo.approval_route_module;
DELETE FROM dbo.approval_condition_field;
UPDATE dbo.entity_master SET route_module_code = NULL;
COMMIT;
