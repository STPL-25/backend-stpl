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
  UomMaster: ["uom_code", "uom_name", "uom_class", "uom_base_uom_flag", "uom_con_factor"],
  GSTStateCodeMaster: ["gst_state_un_name", "gst_code", "gst_alpha_code"],
  AcYearMaster: ["ac_year_code", "ac_year"],
  PriorityMaster: ["priority_name", "priority_desc"],
  DeptMaster: ["com_sno", "div_sno", "brn_sno", "dept_name", "dept_code"],
  ScreenMaster: ["screen_name"],
  ScreenPermission: ["permission_name"],
  ProductMaster: ["cat_sno", "subcat_sno", "prod_name", "uom_sno"],
  WorkflowMaster: ["workflow_name", "workflow_code", "entity_type"],
  TransportMaster: ["transport_name"],
  BankAccountTypeMaster: ["account_type_code", "account_type_name"],
  WarehouseLocationMaster: ["location_code", "location_name", "com_snos"],
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
