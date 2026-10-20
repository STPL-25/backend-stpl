-- Special Agreement screens get their own menu group, "Product Agreement" (Non_trade_Dev). Re-runnable.
IF NOT EXISTS (SELECT 1 FROM dbo.screen_group WHERE group_name = N'Product Agreement')
    INSERT INTO dbo.screen_group (group_name, is_active) VALUES (N'Product Agreement', 'Y');
GO
UPDATE s SET group_id = g.group_id
FROM dbo.screens s CROSS JOIN dbo.screen_group g
WHERE g.group_name = N'Product Agreement' AND s.comp IN ('SpecialAgreementPage', 'SpecialAgreementApprovalScreen');
GO
