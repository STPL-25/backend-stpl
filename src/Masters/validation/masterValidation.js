// Server-side mirror of the "require" flags in
// nt-frontend-stpl/src/FieldDatas/Data.tsx (useXxxMasterFields). The client
// check alone is not enforcement — anyone can call the API directly, so the
// same required-field list is re-checked here before a stored procedure
// ever runs. Only masters with a create stored procedure registered in
// CommonMasterRepo's createProcedureMap are listed; a masterField with no
// entry here is left unvalidated rather than blocked.
const REQUIRED_FIELDS = {
  CompanyMaster: [
    "com_name",
    "add_pan",
    "is_gst_applicable",
    "add_city",
    "add_state",
    "add_state_code",
    "add_pin_code",
    "add_reg_door_no",
    "add_reg_street",
    "add_reg_city",
    "add_reg_state",
    "add_reg_pincode",
  ],
  DivisionMaster: ["div_name", "div_prefix", "div_type", "com_sno"],
  BranchMaster: [
    "com_sno",
    "div_sno",
    "brn_name",
    "brn_prefix",
    "add_city",
    "add_state",
    "add_state_code",
    "add_pin_code",
  ],
  // uom_con_factor is deliberately NOT required — a non-base packaging unit
  // like Box has no single fixed conversion (it varies per product), so its
  // uom_con_factor is left blank on purpose. Products using such a unit
  // supply their own prod_uom_con_factor instead (see ProductMaster below).
  UomMaster: ["uom_code", "uom_name", "uom_class", "uom_base_uom_flag"],
  GSTStateCodeMaster: ["gst_state_un_name", "gst_code", "gst_alpha_code"],
  AcYearMaster: ["ac_year_code", "ac_year"],
  PriorityMaster: ["priority_name", "priority_desc"],
  DeptMaster: ["com_sno", "div_sno", "brn_sno", "dept_name", "dept_code"],
  ScreenMaster: ["screen_name"],
  ScreenPermission: ["permission_name"],
  // prod_uom_con_factor is conditionally required (only when the selected
  // uom_sno is a non-base unit with no fixed uom_master.uom_con_factor, e.g.
  // Box) — that depends on a DB lookup this synchronous validator can't do,
  // so it's left unvalidated here and enforced authoritatively in
  // sp_nt_CreateProductRecord (see backend-stpl/sql/26_product_uom_conversion_factor.sql).
  ProductMaster: ["cat_sno", "subcat_sno", "prod_name", "uom_sno"],
  // cat_notes doubles as the product-code prefix (see
  // sp_nt_CreateProductRecord's CategoryPrefix CTE) — not optional free text.
  ProductCategoryMaster: ["cat_name", "cat_notes"],
  ProductSubCategoryMaster: ["cat_sno", "subcat_name"],
  WorkflowMaster: ["workflow_name", "workflow_code", "entity_type"],
  TransportMaster: ["transport_name"],
  BankAccountTypeMaster: ["account_type_code", "account_type_name"],
  WarehouseLocationMaster: ["location_code", "location_name", "com_snos"],
  RecurrenceCadenceMaster: ["cadence_code", "cadence_name", "interval_unit", "interval_value"],
  DesignationMaster: ["designation_code", "designation_name"],
};

// Fields that are only mandatory conditionally on another field's value.
// CompanyMaster: GST/TAN/CIN are required unless the company has explicitly
// said GST does not apply (fixes D-14 — the unconditional rule contradicted
// real data: a legitimate company with Gst Applicable = N and all three blank).
const CONDITIONAL_RULES = {
  CompanyMaster: (data) => {
    if (data?.is_gst_applicable === "N") return [];
    return ["add_gst", "add_tan", "add_cin"].filter((field) => isBlank(data?.[field]));
  },
};

function isBlank(value) {
  return value === undefined || value === null || (typeof value === "string" && value.trim() === "");
}

function validateOneRow(masterField, data) {
  const required = REQUIRED_FIELDS[masterField];
  if (!required) return [];

  const missing = required.filter((field) => isBlank(data?.[field]));
  const conditionalMissing = CONDITIONAL_RULES[masterField]?.(data) ?? [];
  return [...new Set([...missing, ...conditionalMissing])];
}

/**
 * Validates a createMasterData request body, which is either a single
 * record object (normal Add New) or an array of records (Excel import,
 * which posts every parsed row in one request).
 */
export function validateMasterCreate(masterField, body) {
  const rows = Array.isArray(body) ? body : [body];

  if (rows.length === 0) {
    return { valid: false, errors: ["At least one record is required"] };
  }

  const multiRow = rows.length > 1;
  const errors = [];

  rows.forEach((row, index) => {
    const missing = validateOneRow(masterField, row);
    if (missing.length > 0) {
      errors.push(multiRow ? `Row ${index + 1}: missing ${missing.join(", ")}` : `Missing required field${missing.length > 1 ? "s" : ""}: ${missing.join(", ")}`);
    }
  });

  return { valid: errors.length === 0, errors };
}
