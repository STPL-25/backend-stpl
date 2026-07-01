/* ============================================================================
   Seed: Procurement Inward-to-Pay menu screens + permissions
   Adds the four new pages to the DB-driven sidebar and grants permissions.

       Gate Entry  →  GRN (already seeded)  →  PO Amendment
                   →  Accounts (Bill Booking)  →  Payment

   Target DB : Microsoft SQL Server (sp_nt_* / SQL Server ERP)
   Driven by : `screens` (comp = sectionComponents key, comp_img = lucide icon),
               `screen_group`, `permissions`, `nt_screen_permissions`.

   This script is IDEMPOTENT — safe to run more than once. It will not create
   duplicate screens or duplicate permission grants.

   >>> EDIT the @ecno below to the employee/login whose menu should receive the
       new screens, OR set @grant_all_active = 1 to grant to every active user.
   ============================================================================ */

SET NOCOUNT ON;

DECLARE @ecno            VARCHAR(50) = 'ADMIN';   -- <-- set the target user's ecno
DECLARE @grant_all_active BIT        = 0;          -- 1 = grant to all active nt_sign_up users

/* --- Permission ids (fixed by the app; see usePermissions.ts) ------------- */
--   2 = View, 3 = Create, 4 = Edit, 5 = Delete
DECLARE @PERM_VIEW INT = 2, @PERM_CREATE INT = 3, @PERM_EDIT INT = 4, @PERM_DELETE INT = 5;

/* ---------------------------------------------------------------------------
   1. Resolve menu groups
   Gate Entry & PO Amendment sit with GRN (procurement). Bill & Payment go in
   an Accounts & Payments group. Reuse GRN's group if present, else 'Procurement'.
   --------------------------------------------------------------------------- */
DECLARE @procGroup INT, @acctGroup INT;

SELECT TOP 1 @procGroup = group_id
FROM screens
WHERE comp = 'GRNPage' AND group_id IS NOT NULL;

IF @procGroup IS NULL
BEGIN
    SELECT @procGroup = group_id FROM screen_group WHERE group_name = 'Procurement';
    IF @procGroup IS NULL
    BEGIN
        INSERT INTO screen_group (group_name, is_active) VALUES ('Procurement', 'Y');
        SET @procGroup = SCOPE_IDENTITY();
    END
END

SELECT @acctGroup = group_id FROM screen_group WHERE group_name = 'Accounts & Payments';
IF @acctGroup IS NULL
BEGIN
    INSERT INTO screen_group (group_name, is_active) VALUES ('Accounts & Payments', 'Y');
    SET @acctGroup = SCOPE_IDENTITY();
END

/* ---------------------------------------------------------------------------
   2. Upsert the four screens.
      comp     = sectionComponents key (must match ComponentDatas.tsx)
      comp_img = lucide-react icon name (PascalCase)
   --------------------------------------------------------------------------- */
DECLARE @newScreens TABLE (
    screen_name  VARCHAR(255),
    screen_code  VARCHAR(50),
    comp         VARCHAR(255),
    comp_img     VARCHAR(500),
    group_id     INT,
    display_order INT
);

INSERT INTO @newScreens (screen_name, screen_code, comp, comp_img, group_id, display_order)
VALUES
    ('Gate Entry',              'GATE_ENTRY',   'GateEntryPage',    'DoorOpen',    @procGroup, 81),
    ('PO Amendment',           'PO_AMEND',     'POAmendmentPage',  'FileEdit',    @procGroup, 83),
    ('Accounts - Bill Booking','ACCT_BILL',    'AccountsBillPage', 'ReceiptText', @acctGroup, 91),
    ('Payments',                'PAYMENTS',     'PaymentPage',      'Wallet',      @acctGroup, 92);

INSERT INTO screens (screen_name, screen_code, group_id, comp, comp_img, display_order, is_active, created_date)
SELECT n.screen_name, n.screen_code, n.group_id, n.comp, n.comp_img, n.display_order, 'Y', GETDATE()
FROM @newScreens n
WHERE NOT EXISTS (SELECT 1 FROM screens s WHERE s.comp = n.comp);

/* ---------------------------------------------------------------------------
   3. Build the set of permissions to grant per screen.
      All four get View + Create + Edit (+ Delete for the procurement docs).
      Bill "Approve" is gated by canEdit in the UI, so Edit covers it.
   --------------------------------------------------------------------------- */
DECLARE @grants TABLE (comp VARCHAR(255), permission_id INT);

INSERT INTO @grants (comp, permission_id)
SELECT n.comp, p.permission_id
FROM @newScreens n
CROSS JOIN (VALUES (@PERM_VIEW), (@PERM_CREATE), (@PERM_EDIT)) AS p(permission_id)
UNION ALL
-- Delete only on Gate Entry & PO Amendment (document corrections)
SELECT comp, @PERM_DELETE FROM @newScreens WHERE comp IN ('GateEntryPage', 'POAmendmentPage');

/* ---------------------------------------------------------------------------
   4. Resolve the target users (nt_sign_up_sno).
   --------------------------------------------------------------------------- */
DECLARE @users TABLE (nt_sign_up_sno INT);

IF @grant_all_active = 1
    INSERT INTO @users SELECT nt_sign_up_sno FROM nt_sign_up WHERE is_active = 'Y';
ELSE
    INSERT INTO @users SELECT nt_sign_up_sno FROM nt_sign_up WHERE ecno = @ecno AND is_active = 'Y';

IF NOT EXISTS (SELECT 1 FROM @users)
    PRINT 'WARNING: no matching user found — screens added but no permissions granted. Check @ecno / @grant_all_active.';

/* ---------------------------------------------------------------------------
   5. Grant permissions (idempotent — skips grants that already exist).
   --------------------------------------------------------------------------- */
INSERT INTO nt_screen_permissions (nt_sign_up_sno, screen_id, permission_id, created_date, is_active)
SELECT u.nt_sign_up_sno, s.screen_id, g.permission_id, GETDATE(), 'Y'
FROM @grants g
JOIN screens s ON s.comp = g.comp
CROSS JOIN @users u
WHERE NOT EXISTS (
    SELECT 1 FROM nt_screen_permissions x
    WHERE x.nt_sign_up_sno = u.nt_sign_up_sno
      AND x.screen_id     = s.screen_id
      AND x.permission_id = g.permission_id
);

PRINT 'Procurement menu seed complete. Screens added (if missing) and permissions granted.';
PRINT 'NOTE: the sidebar API is cached (ua:user_screens:<ecno>, 300s) — clear Redis or wait for TTL to see the new menu.';
GO
