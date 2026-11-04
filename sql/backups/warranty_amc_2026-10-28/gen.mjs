import fs from "node:fs";
const rd = n => fs.readFileSync(`${n}.before.sql`, "utf8").replace(/\r\n/g, "\n").replace(/CREATE\s+PROCEDURE/i, "CREATE OR ALTER PROCEDURE");
const once = (s, a, b, tag) => { const c = s.split(a).length - 1; if (c !== 1) throw new Error(`${tag}: anchor hit ${c}x: ${a.slice(0,50)}`); return s.replace(a, () => b); };
const COLS = "warranty_applicable, warranty_period, warranty_terms, amc_applicable, amc_details, amc_terms";
const WITH = (pad) => [
  `warranty_applicable CHAR(1)       '$.warranty_applicable'`,
  `warranty_period     NVARCHAR(100) '$.warranty_period'`,
  `warranty_terms      NVARCHAR(1000) '$.warranty_terms'`,
  `amc_applicable      CHAR(1)       '$.amc_applicable'`,
  `amc_details         NVARCHAR(1000) '$.amc_details'`,
  `amc_terms           NVARCHAR(1000) '$.amc_terms'`].map(l => pad + l).join(",\n");
const NORMALIZE = (ind) => `${ind}-- Warranty / AMC: only 'Y' counts; details are dropped when not applicable.
${ind}UPDATE dbo.supplier_quotation_items
${ind}SET warranty_applicable = CASE WHEN warranty_applicable = 'Y' THEN 'Y' ELSE 'N' END,
${ind}    amc_applicable      = CASE WHEN amc_applicable = 'Y' THEN 'Y' ELSE 'N' END,
${ind}    warranty_period     = CASE WHEN warranty_applicable = 'Y' THEN NULLIF(LTRIM(RTRIM(warranty_period)), '') END,
${ind}    warranty_terms      = CASE WHEN warranty_applicable = 'Y' THEN NULLIF(LTRIM(RTRIM(warranty_terms)), '') END,
${ind}    amc_details         = CASE WHEN amc_applicable = 'Y' THEN NULLIF(LTRIM(RTRIM(amc_details)), '') END,
${ind}    amc_terms           = CASE WHEN amc_applicable = 'Y' THEN NULLIF(LTRIM(RTRIM(amc_terms)), '') END
${ind}WHERE sq_basic_sno = @sq_basic_sno;

`;
// Create
let c = rd("sp_nt_CreateSupplierQuotation");
const i0 = c.indexOf("INSERT INTO dbo.supplier_quotation_items");
if (i0 < 0) throw new Error("create: item insert not found");
let head = c.slice(0, i0), tail = c.slice(i0);
tail = once(tail, "            remarks,\n            is_active\n", `            remarks,\n            is_active,\n            ${COLS.split(", ").join(",\n            ")}\n`, "c1");
tail = once(tail, "            remarks,\n            ISNULL(is_active, 1)\n", `            remarks,\n            ISNULL(is_active, 1),\n            ${COLS.split(", ").join(",\n            ")}\n`, "c2");
tail = once(tail, "            is_active     BIT             '$.is_active'\n        );\n", `            is_active     BIT             '$.is_active',\n${WITH("            ")}\n        );\n\n${NORMALIZE("        ")}`, "c3");
c = head + tail;
// Update
let u = rd("sp_nt_UpdateSupplierQuotation");
u = once(u, "total_amount, delivery_days, remarks\n        INTO #new_items", `total_amount, delivery_days, remarks,\n               ${COLS}\n        INTO #new_items`, "u1");
u = once(u, "remarks       NVARCHAR(1000) '$.remarks'\n        );", `remarks       NVARCHAR(1000) '$.remarks',\n${WITH("            ")}\n        );`, "u2");
u = once(u, "qi.remarks = n.remarks,\n", `qi.remarks = n.remarks,\n            ${COLS.split(", ").map(x => `qi.${x} = n.${x}`).join(", ")},\n`, "u3");
u = once(u, "total_amount, delivery_days, remarks, is_active)", `total_amount, delivery_days, remarks, is_active,\n             ${COLS})`, "u4");
u = once(u, "n.delivery_days, n.remarks, 1\n", `n.delivery_days, n.remarks, 1,\n               ${COLS.split(", ").map(x => `n.${x}`).join(", ")}\n`, "u5");
u = once(u, "        -- Advance: switched off", NORMALIZE("        ") + "        -- Advance: switched off", "u6");
// Get
let g = rd("sp_nt_GetSupplierQuotations");
g = once(g, "                sqi.remarks,\n", `                sqi.remarks,\n${COLS.split(", ").map(x => `                sqi.${x},`).join("\n")}\n`, "g1");
// Approval
let a = rd("sp_nt_GetQuotationsForApproval");
a = once(a, "sid.delivery_days,                            sid.remarks,", `sid.delivery_days,                            sid.remarks,\n${COLS.split(", ").map(x => `                        sid.${x},`).join("\n")}`, "a1");
const hdr = `-- 143: Supplier quotation — per-item Warranty / AMC (varies by supplier, so it lives on the quotation line, not the product).
--  * supplier_quotation_items: warranty_applicable (Y/N), warranty_period, warranty_terms,
--    amc_applicable (Y/N), amc_details, amc_terms.
--  * sp_nt_CreateSupplierQuotation / sp_nt_UpdateSupplierQuotation persist them (details dropped when not applicable).
--  * sp_nt_GetSupplierQuotations (Purchase screen) and sp_nt_GetQuotationsForApproval (Quotation + PO approval) return them.
-- Previous definitions: sql/backups/warranty_amc_2026-10-28/*.before.sql. Re-runnable.
IF COL_LENGTH('dbo.supplier_quotation_items','warranty_applicable') IS NULL ALTER TABLE dbo.supplier_quotation_items ADD warranty_applicable CHAR(1) NOT NULL CONSTRAINT DF_sqitem_warranty DEFAULT 'N';
IF COL_LENGTH('dbo.supplier_quotation_items','warranty_period')     IS NULL ALTER TABLE dbo.supplier_quotation_items ADD warranty_period NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.supplier_quotation_items','warranty_terms')      IS NULL ALTER TABLE dbo.supplier_quotation_items ADD warranty_terms NVARCHAR(1000) NULL;
IF COL_LENGTH('dbo.supplier_quotation_items','amc_applicable')      IS NULL ALTER TABLE dbo.supplier_quotation_items ADD amc_applicable CHAR(1) NOT NULL CONSTRAINT DF_sqitem_amc DEFAULT 'N';
IF COL_LENGTH('dbo.supplier_quotation_items','amc_details')         IS NULL ALTER TABLE dbo.supplier_quotation_items ADD amc_details NVARCHAR(1000) NULL;
IF COL_LENGTH('dbo.supplier_quotation_items','amc_terms')           IS NULL ALTER TABLE dbo.supplier_quotation_items ADD amc_terms NVARCHAR(1000) NULL;
GO
`;
fs.writeFileSync("../../143_quotation_item_warranty_amc.sql", hdr + [c, u, g, a].map(x => x.trim() + "\nGO\n").join("\n"));
console.log("written");
