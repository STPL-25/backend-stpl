-- Seeds the approval-routing config (data only) that sql/99, 124 and 125 inserted on Dev but the
-- 2026-10-10 Dev->Non_Trade schema sync did not copy. Idempotent (MERGE / NOT EXISTS / IS NULL guards).
-- Every default route maps a variant to its module's OWN entity, i.e. exactly today's behaviour; the
-- Dev-only dedicated entities (ServiceAgreement_FIXED_RECURRING ...) are NOT created.
-- Rollback: sql/backups/seed_approval_routing_prod_2026-10-10_ROLLBACK.sql

-- 1. modules
MERGE dbo.approval_route_module AS t
USING (VALUES
    (N'PurchaseRequisition', N'Purchase Requisition', N'Request type',   N'Regular PR vs Vendor-driven PR',          1, 0),
    (N'ServiceAgreement',    N'Service Agreement',    N'Agreement type', N'One variant per Service Type master row', 2, 1),
    (N'ServicePO',           N'Service PO',           N'Agreement type', N'Per-cycle PO of each Service Type',       3, 1),
    (N'PurchaseOrder',       N'Purchase Order',       N'Order type',     N'PO raised from an approved quotation',    4, 0),
    (N'GRN',                 N'GRN',                  N'Receipt type',   N'Goods receipt approval',                  5, 0),
    (N'Payment',             N'Payment',              N'Payment type',   N'Supplier payment approval',               6, 0),
    (N'KYC',                 N'KYC',                  N'KYC type',       N'Supplier KYC approval',                   7, 0)
) AS s(module_code, module_label, variant_label, description, sort_order, variants_from_master)
ON t.module_code = s.module_code
WHEN NOT MATCHED THEN INSERT (module_code, module_label, variant_label, description, sort_order, variants_from_master)
     VALUES (s.module_code, s.module_label, s.variant_label, s.description, s.sort_order, s.variants_from_master);

-- 2. static variants (service-type variants come from service_type_master via the view)
MERGE dbo.approval_route_variant AS t
USING (VALUES
    (N'PurchaseRequisition', N'NORMAL',        N'Regular',       1),
    (N'PurchaseRequisition', N'VENDOR_DRIVEN', N'Vendor driven', 2),
    (N'PurchaseOrder',       N'STANDARD',      N'Standard',      1),
    (N'GRN',                 N'STANDARD',      N'Standard',      1),
    (N'Payment',             N'STANDARD',      N'Standard',      1),
    (N'KYC',                 N'SUPPLIER',      N'Supplier KYC',  1)
) AS s(module_code, variant_code, variant_label, sort_order)
ON t.module_code = s.module_code AND t.variant_code = s.variant_code
WHEN NOT MATCHED THEN INSERT (module_code, variant_code, variant_label, sort_order)
     VALUES (s.module_code, s.variant_code, s.variant_label, s.sort_order);

-- 3. entity_master -> module
UPDATE dbo.entity_master SET route_module_code = N'PurchaseRequisition'
 WHERE entity_code IN (N'PurchaseRequisition', N'VendorDrivenPurchaseRequisition') AND route_module_code IS NULL;
UPDATE dbo.entity_master SET route_module_code = entity_code
 WHERE entity_code IN (N'ServiceAgreement', N'ServicePO', N'PurchaseOrder', N'GRN', N'Payment', N'KYC') AND route_module_code IS NULL;

-- 4. default routes (variant -> module's own entity; vendor-driven PR -> its own entity)
INSERT INTO dbo.approval_entity_route (module_code, variant_code, entity_code, modified_by)
SELECT s.module_code, s.variant_code, s.entity_code, N'system'
FROM (
    SELECT N'PurchaseRequisition' module_code, N'NORMAL' variant_code, N'PurchaseRequisition' entity_code
    UNION ALL SELECT N'PurchaseRequisition', N'VENDOR_DRIVEN', N'VendorDrivenPurchaseRequisition'
    UNION ALL SELECT N'PurchaseOrder', N'STANDARD', N'PurchaseOrder'
    UNION ALL SELECT N'GRN', N'STANDARD', N'GRN'
    UNION ALL SELECT N'Payment', N'STANDARD', N'Payment'
    UNION ALL SELECT N'KYC', N'SUPPLIER', N'KYC'
    UNION ALL SELECT m.module_code, CAST(st.service_type_code AS NVARCHAR(50)), m.module_code
              FROM dbo.service_type_master st
              CROSS JOIN (SELECT N'ServiceAgreement' module_code UNION ALL SELECT N'ServicePO') m
) s
WHERE NOT EXISTS (SELECT 1 FROM dbo.approval_entity_route r WHERE r.module_code = s.module_code AND r.variant_code = s.variant_code);

-- 5. condition-field registry (PR + vendor-driven PR)
MERGE dbo.approval_condition_field AS t
USING (VALUES
    ('PurchaseRequisition',            'amount',             N'Amount (PR total)',          'number', NULL,                       'INR',  N'Total cost of all lines on the requisition', 1),
    ('PurchaseRequisition',            'category',           N'Category',                   'list',   'ProductCategoryMaster',    NULL,   N'Product categories of the lines',            2),
    ('PurchaseRequisition',            'subcategory',        N'Sub-category',               'list',   'ProductSubCategoryMaster', NULL,   N'Product sub-categories of the lines',        3),
    ('PurchaseRequisition',            'priority',           N'Priority',                   'list',   'PriorityMaster',           NULL,   N'Priority chosen on the requisition',         4),
    ('VendorDrivenPurchaseRequisition','amount',             N'Amount (total incl. GST)',   'number', NULL,                       'INR',  N'Total of all lines including GST',           1),
    ('VendorDrivenPurchaseRequisition','supplier',           N'Supplier',                   'list',   'VendorMaster',             NULL,   N'The supplier the requisition is for',        2),
    ('VendorDrivenPurchaseRequisition','payment_cycle_days', N'Payment cycle (days)',       'number', NULL,                       'days', N'Days agreed to pay the supplier',            3),
    ('VendorDrivenPurchaseRequisition','category',           N'Category',                   'list',   'ProductCategoryMaster',    NULL,   N'Product categories of the lines',            4),
    ('VendorDrivenPurchaseRequisition','subcategory',        N'Sub-category',               'list',   'ProductSubCategoryMaster', NULL,   N'Product sub-categories of the lines',        5),
    ('VendorDrivenPurchaseRequisition','priority',           N'Priority',                   'list',   'PriorityMaster',           NULL,   N'Priority chosen on the requisition',         6)
) AS s (entity_type, field_key, field_label, value_kind, option_source, unit, help_text, sort_order)
ON t.entity_type = s.entity_type AND t.field_key = s.field_key
WHEN NOT MATCHED THEN
    INSERT (entity_type, field_key, field_label, value_kind, option_source, unit, help_text, sort_order)
    VALUES (s.entity_type, s.field_key, s.field_label, s.value_kind, s.option_source, s.unit, s.help_text, s.sort_order);
