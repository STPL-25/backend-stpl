-- ============================================================================
-- 151_individual_master_screens.sql   (Non_trade_Dev, re-runnable)
--
-- Per-master access on the Role Permissions screen.
--
-- Until now one screen row, "Masters" (comp 'masters'), gated the WHOLE Masters page: a user either saw every master
-- and could create / edit / delete in all of them, or saw none. This adds one screen row PER MASTER, so the Role
-- Permissions matrix can grant (View / Create / Edit / Delete) master by master.
--
--   * new screen_group "Individual Masters" -> its own table in the Role Permissions matrix
--   * one screens row per master tile (32), comp = 'masters.<master key>' (the key MasterPageScreen already uses, e.g.
--     'masters.CompanyMaster'), parent_screen_id = the "Masters" row, screen_name = the tile's name on the Masters grid
--   * Terms & Conditions and Product Stock Level are staff_only = 'Y', matching their staffOnly flag on the grid
--   * the sidebar skips these rows (SideBar.tsx) - they only exist to carry permissions, there is no page behind them
--   * the "Masters" row is unchanged and still opens the Masters page from the sidebar
--
-- BACKFILL - so nobody loses access the moment the page starts checking the new rows: every active user who already
-- holds "Masters" gets all 32 new rows with exactly the permissions their "Masters" row has. Admins can then take
-- individual masters away on Role Permissions. Users without "Masters" get nothing. Rows a user already holds are
-- left alone, so re-running this never overwrites a later change.
--
-- Re-running also switches any of these rows back on if they were switched off (the rollback does exactly that).
--
-- To add a master later: add its tile to masterItems (Data.tsx) AND a screens row here-style (comp 'masters.<key>').
-- A tile with no screen row is hidden from everyone.
-- Rollback: sql/backups/individual_master_screens_2026-11-04_ROLLBACK.sql
-- ============================================================================

IF NOT EXISTS (SELECT 1 FROM dbo.screen_group WHERE group_name = N'Individual Masters')
    INSERT INTO dbo.screen_group (group_name, is_active) VALUES (N'Individual Masters', 'Y');
ELSE
    UPDATE dbo.screen_group SET is_active = 'Y' WHERE group_name = N'Individual Masters' AND is_active <> 'Y';
GO

DECLARE @group_id INT = (SELECT TOP 1 group_id FROM dbo.screen_group WHERE group_name = N'Individual Masters');
DECLARE @parent   INT = (SELECT TOP 1 screen_id FROM dbo.screens WHERE comp = 'masters');
IF @group_id IS NULL OR @parent IS NULL
    THROW 51000, 'screen_group "Individual Masters" or the "Masters" screen row is missing.', 1;

DECLARE @masters TABLE (ord INT, master_key VARCHAR(60), screen_name VARCHAR(30), staff_only CHAR(1));
INSERT INTO @masters (ord, master_key, screen_name, staff_only) VALUES
 ( 1, 'CompanyMaster',            'Company Master',          'N'),
 ( 2, 'DivisionMaster',           'Division Master',         'N'),
 ( 3, 'BranchMaster',             'Branch Master',           'N'),
 ( 4, 'DeptMaster',               'Department Master',       'N'),
 ( 5, 'GSTStateCodeMaster',       'GST State Code',          'N'),
 ( 6, 'ScreenMaster',             'Screen Master',           'N'),
 ( 7, 'ScreenPermission',         'Screen Permission',       'N'),
 ( 8, 'WorkflowMaster',           'Workflow Master',         'N'),
 ( 9, 'PriorityMaster',           'Priority Master',         'N'),
 (10, 'ProductCategoryMaster',    'Product Category',        'N'),
 (11, 'ProductSubCategoryMaster', 'Product Sub Category',    'N'),
 (12, 'StockTypeMaster',          'Stock Type',              'N'),
 (13, 'ProductMaster',            'Product',                 'N'),
 (14, 'UomMaster',                'UOM',                     'N'),
 (15, 'UomClassMaster',           'UOM Class',               'N'),
 (16, 'TransportMaster',          'Transporter Master',      'N'),
 (17, 'BankAccountTypeMaster',    'Bank Account Type',       'N'),
 (18, 'PaymentTermsMaster',       'Payment Terms',           'N'),
 (19, 'WarehouseLocationMaster',  'Warehouse Location',      'N'),
 (20, 'DesignationMaster',        'Designation Master',      'N'),
 (21, 'TermsConditionsMaster',    'Terms & Conditions',      'Y'),
 (22, 'ProductStockLevelMaster',  'Product Stock Level',     'Y'),
 (23, 'TdsSectionMaster',         'TDS Section',             'N'),
 (24, 'SupplierCatagoryMaster',   'Supplier Category',       'N'),
 (25, 'PaymentModeMaster',        'Payment Mode',            'N'),
 (26, 'ServiceTypeMaster',        'Service Type',            'N'),
 (27, 'ServiceMaster',            'Service',                 'N'),
 (28, 'RecurrenceCadenceMaster',  'Recurrence Cadence',      'N'),
 (29, 'AccountHeadMaster',        'Account Head',            'N'),
 (30, 'PaymentBankMaster',        'Payment Bank',            'N'),
 (31, 'BankFileFormatMaster',     'Bank File Format',        'N'),
 (32, 'BankFileFormatColumnMaster','Bank File Format Columns','N');

-- A name that is already taken by some OTHER screen would make two matrix rows share one key (the matrix is keyed by
-- screen_name), so stop rather than silently merge them.
IF EXISTS (
    SELECT 1 FROM @masters m
    JOIN dbo.screens s ON s.screen_name = m.screen_name AND ISNULL(s.comp, '') <> 'masters.' + m.master_key
)
    THROW 51001, 'A new master screen name collides with an existing screen name.', 1;

INSERT INTO dbo.screens (screen_name, screen_code, parent_screen_id, display_order, is_active, group_id, comp, comp_img, staff_only)
SELECT m.screen_name, 'S5', @parent, m.ord, 'Y', @group_id, 'masters.' + m.master_key, 'Table', m.staff_only
FROM @masters m
WHERE NOT EXISTS (SELECT 1 FROM dbo.screens s WHERE s.comp = 'masters.' + m.master_key);

-- Re-applying after the rollback (which only switches the rows off) turns them back on.
UPDATE dbo.screens SET is_active = 'Y' WHERE comp LIKE 'masters.%' AND is_active <> 'Y';
GO

-- ---- backfill: copy each "Masters" holder's permissions onto every new row they do not already have ------------------
DECLARE @masters_screen INT = (SELECT TOP 1 screen_id FROM dbo.screens WHERE comp = 'masters');

UPDATE u
SET u.screens_json = (
        SELECT a.screen_id, JSON_QUERY(a.permissions) AS permissions
        FROM (
            SELECT e.screen_id, e.permissions
            FROM OPENJSON(u.screens_json) WITH (screen_id INT '$.screen_id', permissions NVARCHAR(MAX) '$.permissions' AS JSON) e
            UNION ALL
            SELECT c.screen_id, m.permissions
            FROM dbo.screens c
            WHERE c.comp LIKE 'masters.%'
              AND NOT EXISTS (
                    SELECT 1 FROM OPENJSON(u.screens_json) WITH (screen_id INT '$.screen_id') h WHERE h.screen_id = c.screen_id
              )
        ) a
        FOR JSON PATH
    ),
    u.updated_date = GETDATE()
FROM dbo.nt_user_permissions_json u
CROSS APPLY (
    SELECT TOP 1 x.permissions
    FROM OPENJSON(u.screens_json) WITH (screen_id INT '$.screen_id', permissions NVARCHAR(MAX) '$.permissions' AS JSON) x
    WHERE x.screen_id = @masters_screen
) m
WHERE u.is_active = 'Y'
  AND ISJSON(u.screens_json) = 1
  AND ISNULL(m.permissions, '[]') <> '[]'
  AND EXISTS (   -- only rows still missing at least one of the new screens
        SELECT 1 FROM dbo.screens c
        WHERE c.comp LIKE 'masters.%'
          AND NOT EXISTS (SELECT 1 FROM OPENJSON(u.screens_json) WITH (screen_id INT '$.screen_id') h WHERE h.screen_id = c.screen_id)
  );
GO
