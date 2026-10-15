-- resolvers
-- (module, variant) -> entity_type: own row, else the '*' row, else the module's own entity.
CREATE   FUNCTION dbo.fn_resolve_approval_entity (@module VARCHAR(50), @variant VARCHAR(50))
RETURNS VARCHAR(50)
AS
BEGIN
    RETURN ISNULL((
        SELECT TOP 1 r.entity_code
        FROM dbo.approval_entity_route r
        WHERE r.is_active = 'Y' AND r.module_code = @module AND r.variant_code IN (ISNULL(@variant, N'*'), N'*')
        ORDER BY CASE WHEN r.variant_code = @variant THEN 0 ELSE 1 END
    ), @module);
END;