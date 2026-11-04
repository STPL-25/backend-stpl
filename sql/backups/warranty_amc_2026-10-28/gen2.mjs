import fs from "node:fs";
const rd = n => fs.readFileSync(`${n}.before.sql`, "utf8").replace(/\r\n/g, "\n").replace(/CREATE\s+PROCEDURE/i, "CREATE OR ALTER PROCEDURE");
const once = (s, a, b, t) => { const c = s.split(a).length - 1; if (c !== 1) throw new Error(`${t}: ${c}x`); return s.replace(a, () => b); };
const NORM = ind => `${ind}-- Additional covers (Warranty / AMC / Others): keep NULL when the list is empty.
${ind}UPDATE dbo.supplier_quotation_items SET additional_json = NULL
${ind}WHERE sq_basic_sno = @sq_basic_sno AND (additional_json IS NULL OR ISJSON(additional_json) = 0 OR additional_json = N'[]');

`;
let c = rd("sp_nt_CreateSupplierQuotation");
const i0 = c.indexOf("INSERT INTO dbo.supplier_quotation_items"); let h = c.slice(0, i0), t = c.slice(i0);
t = once(t, "            remarks,\n            is_active\n", "            remarks,\n            is_active,\n            additional_json\n", "c1");
t = once(t, "            remarks,\n            ISNULL(is_active, 1)\n", "            remarks,\n            ISNULL(is_active, 1),\n            additional_json\n", "c2");
t = once(t, "            is_active     BIT             '$.is_active'\n        );\n", `            is_active     BIT             '$.is_active',\n            additional_json NVARCHAR(MAX) '$.additional' AS JSON\n        );\n\n${NORM("        ")}`, "c3");
c = h + t;
let u = rd("sp_nt_UpdateSupplierQuotation");
u = once(u, "total_amount, delivery_days, remarks\n        INTO #new_items", "total_amount, delivery_days, remarks, additional_json\n        INTO #new_items", "u1");
u = once(u, "remarks       NVARCHAR(1000) '$.remarks'\n        );", "remarks       NVARCHAR(1000) '$.remarks',\n            additional_json NVARCHAR(MAX) '$.additional' AS JSON\n        );", "u2");
u = once(u, "qi.remarks = n.remarks,\n", "qi.remarks = n.remarks, qi.additional_json = n.additional_json,\n", "u3");
u = once(u, "total_amount, delivery_days, remarks, is_active)", "total_amount, delivery_days, remarks, is_active, additional_json)", "u4");
u = once(u, "n.delivery_days, n.remarks, 1\n", "n.delivery_days, n.remarks, 1, n.additional_json\n", "u5");
u = once(u, "        -- Advance: switched off", NORM("        ") + "        -- Advance: switched off", "u6");
let g = rd("sp_nt_GetSupplierQuotations");
g = once(g, "                sqi.remarks,\n", "                sqi.remarks,\n                JSON_QUERY(sqi.additional_json) AS additional,\n", "g1");
let a = rd("sp_nt_GetQuotationsForApproval");
a = once(a, "sid.delivery_days,                            sid.remarks,", "sid.delivery_days,                            sid.remarks,\n                        JSON_QUERY(sid.additional_json) AS additional,", "a1");
const hdr = `-- 144: Supplier quotation — per-item "Additional" covers, replacing the fixed Warranty/AMC columns of sql/143.
--  * supplier_quotation_items.additional_json: JSON list of {type: Warranty|AMC|Other, label, years, cost_type: Free|Paid|Semi-paid, terms}.
--  * Create/Update/Get quotation procs + sp_nt_GetQuotationsForApproval read and write it (returned as "additional").
--  * The six sql/143 columns are dropped (never used by a release). Procs are rebuilt from the pre-143 definitions
--    in sql/backups/warranty_amc_2026-10-28/*.before.sql. Re-runnable.
IF COL_LENGTH('dbo.supplier_quotation_items','additional_json') IS NULL ALTER TABLE dbo.supplier_quotation_items ADD additional_json NVARCHAR(MAX) NULL;
GO
`;
const drop = `-- Drop the sql/143 columns (procs no longer reference them).
DECLARE @s NVARCHAR(MAX) = N'';
SELECT @s += N'ALTER TABLE dbo.supplier_quotation_items DROP CONSTRAINT ' + QUOTENAME(dc.name) + N';'
FROM sys.default_constraints dc JOIN sys.columns col ON col.object_id = dc.parent_object_id AND col.column_id = dc.parent_column_id
WHERE dc.parent_object_id = OBJECT_ID('dbo.supplier_quotation_items') AND col.name IN ('warranty_applicable','amc_applicable');
EXEC (@s);
IF COL_LENGTH('dbo.supplier_quotation_items','warranty_applicable') IS NOT NULL ALTER TABLE dbo.supplier_quotation_items DROP COLUMN warranty_applicable;
IF COL_LENGTH('dbo.supplier_quotation_items','warranty_period') IS NOT NULL ALTER TABLE dbo.supplier_quotation_items DROP COLUMN warranty_period;
IF COL_LENGTH('dbo.supplier_quotation_items','warranty_terms') IS NOT NULL ALTER TABLE dbo.supplier_quotation_items DROP COLUMN warranty_terms;
IF COL_LENGTH('dbo.supplier_quotation_items','amc_applicable') IS NOT NULL ALTER TABLE dbo.supplier_quotation_items DROP COLUMN amc_applicable;
IF COL_LENGTH('dbo.supplier_quotation_items','amc_details') IS NOT NULL ALTER TABLE dbo.supplier_quotation_items DROP COLUMN amc_details;
IF COL_LENGTH('dbo.supplier_quotation_items','amc_terms') IS NOT NULL ALTER TABLE dbo.supplier_quotation_items DROP COLUMN amc_terms;
`;
fs.writeFileSync("../../144_quotation_item_additional_covers.sql", hdr + [c, u, g, a].map(x => x.trim() + "\nGO\n").join("\n") + "\n" + drop + "GO\n");
console.log("ok");
