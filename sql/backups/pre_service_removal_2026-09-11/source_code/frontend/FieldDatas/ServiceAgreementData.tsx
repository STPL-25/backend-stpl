import { useMemo } from "react";
import { useMasterOptions } from "../hooks/ReUsableHook/useMasterOptions";
import { FieldType } from "./fieldType/fieldType";

export type AgreementType = "FIXED_RECURRING" | "VARIABLE_RECURRING" | "VENDOR_BILL";

interface CascadeOption {
  value: string | number;
  label: string;
  com_sno?: string | number | null;
  div_sno?: string | number | null;
  brn_sno?: string | number | null;
  service_type_sno?: string | number | null;
  service_type_code?: string | null;
}

interface OrgCascadeParams {
  selectedCompany?: string;
  selectedDivision?: string;
  selectedBranch?: string;
}

/**
 * Shared org cascade (Company -> Division -> Branch -> Department), same
 * client-side-filter-by-parent-selection idiom as usePRBasicInfoFields
 * (FieldDatas/PRData.tsx) — all four masters fetched once unfiltered, no
 * server refetch on cascade change.
 */
function useOrgCascadeOptions(params: OrgCascadeParams | undefined, options: any) {
  const { selectedCompany, selectedDivision, selectedBranch } = params || {};
  const { CompanyMaster, DivisionMaster, BranchMaster, DeptMaster } = options || {};

  const divisionOptions = useMemo(() => {
    if (!DivisionMaster) return [];
    if (!selectedCompany) return DivisionMaster;
    return DivisionMaster.filter((d: CascadeOption) => String(d.com_sno) === String(selectedCompany));
  }, [DivisionMaster, selectedCompany]);

  const branchOptions = useMemo(() => {
    if (!BranchMaster) return [];
    return BranchMaster.filter((b: CascadeOption) => {
      const matchCompany = !selectedCompany || String(b.com_sno) === String(selectedCompany);
      const matchDivision = !selectedDivision || String(b.div_sno) === String(selectedDivision);
      return matchCompany && matchDivision;
    });
  }, [BranchMaster, selectedCompany, selectedDivision]);

  const deptOptions = useMemo(() => {
    if (!DeptMaster) return [];
    return DeptMaster.filter((d: CascadeOption) => {
      const matchCompany = !selectedCompany || String(d.com_sno) === String(selectedCompany);
      const matchDivision = !selectedDivision || String(d.div_sno) === String(selectedDivision);
      const matchBranch = !selectedBranch || String(d.brn_sno) === String(selectedBranch);
      return matchCompany && matchDivision && matchBranch;
    });
  }, [DeptMaster, selectedCompany, selectedDivision, selectedBranch]);

  return { CompanyMaster, divisionOptions, branchOptions, deptOptions };
}

function orgCascadeFields(CompanyMaster: any, divisionOptions: any, branchOptions: any, deptOptions: any): FieldType[] {
  return [
    { field: "com_sno", label: "Company", require: true, view: false, type: "select", options: CompanyMaster, input: true },
    { field: "com_name", label: "Company", require: false, view: true, type: "text", input: false },
    { field: "div_sno", label: "Division", require: true, view: false, type: "select", options: divisionOptions, input: true },
    { field: "div_name", label: "Division", require: false, view: true, type: "text", input: false },
    { field: "brn_sno", label: "Branch", require: true, view: false, type: "select", options: branchOptions, input: true },
    { field: "brn_name", label: "Branch", require: false, view: true, type: "text", input: false },
    { field: "dept_sno", label: "Department", require: true, view: false, type: "select", options: deptOptions, input: true },
    { field: "dept_name", label: "Department", require: false, view: true, type: "text", input: false },
  ];
}

interface ServiceAgreementFieldsParams extends OrgCascadeParams {
  agreementType: AgreementType;
}

/**
 * Fields for the Service Agreement create form — Fixed Recurring and
 * Variable Recurring only (Vendor Driven never creates an agreement row,
 * see useVendorDrivenPOFields below). Fields for the type NOT currently
 * selected get input:false so they don't render, same technique
 * usePRItemDetailsFields uses for isProduct/isService-gated fields.
 */
export const useServiceAgreementFields = (params: ServiceAgreementFieldsParams): FieldType[] => {
  const { agreementType, ...cascadeParams } = params;
  const { options } = useMasterOptions([
    "CompanyMaster", "DivisionMaster", "BranchMaster", "DeptMaster",
    "ServiceMaster", "ServiceTypeMaster", "VendorMaster", "UomMaster", "RecurrenceCadenceMaster",
  ]);
  const { CompanyMaster, divisionOptions, branchOptions, deptOptions } = useOrgCascadeOptions(cascadeParams, options);

  const isFixed = agreementType === "FIXED_RECURRING";
  const isVariable = agreementType === "VARIABLE_RECURRING";

  // ServiceMaster narrowed to services whose type matches the chosen
  // agreement type — resolved via ServiceTypeMaster's service_type_code
  // extra field rather than a hardcoded sno, since master snos aren't stable.
  const serviceOptions = useMemo(() => {
    const serviceTypeSno = (options?.ServiceTypeMaster ?? []).find(
      (t: CascadeOption) => t.service_type_code === agreementType
    )?.value;
    if (serviceTypeSno == null) return [];
    return (options?.ServiceMaster ?? []).filter(
      (s: CascadeOption) => String(s.service_type_sno) === String(serviceTypeSno)
    );
  }, [options?.ServiceMaster, options?.ServiceTypeMaster, agreementType]);

  return useMemo<FieldType[]>(
    () => [
      ...orgCascadeFields(CompanyMaster, divisionOptions, branchOptions, deptOptions),
      { field: "service_sno", label: "Service", require: true, view: false, type: "search-select", options: serviceOptions, input: true },
      { field: "service_name", label: "Service", require: false, view: true, type: "text", input: false },
      { field: "vendor_sno", label: "Supplier", require: true, view: false, type: "search-select", options: options?.VendorMaster, input: true },
      { field: "vendor_name", label: "Supplier", require: false, view: true, type: "text", input: false },

      { field: "rate_amount", label: "Rate Amount", require: isFixed, view: isFixed, type: "number", input: isFixed },
      { field: "rate_uom_sno", label: "Rate UOM (per)", require: false, view: false, type: "search-select", options: options?.UomMaster, input: isFixed },
      { field: "rate_uom_name", label: "Rate UOM", require: false, view: isFixed, type: "text", input: false },

      { field: "ceiling_amount", label: "Ceiling Amount", require: isVariable, view: isVariable, type: "number", input: isVariable },
      { field: "variance_tolerance_pct", label: "Variance Tolerance (%)", require: isVariable, view: isVariable, type: "number", input: isVariable },

      { field: "recurrence_cadence_sno", label: "Recurrence Cadence", require: true, view: true, type: "select", options: options?.RecurrenceCadenceMaster, input: true },
      { field: "cadence_name", label: "Cadence", require: false, view: false, type: "text", input: false },

      {
        field: "po_generation_day", label: "PO Generation Day (1-31)", require: false, view: isFixed, type: "number",
        input: isFixed, placeholder: "e.g. 5 for the 5th of every month",
      },
      {
        field: "notify_days_before", label: "Notify Before (days)", require: false, view: isFixed || isVariable, type: "number",
        input: isFixed || isVariable, defaultValue: 0, placeholder: "e.g. 2",
      },

      { field: "period_start_date", label: "Duration From", require: true, view: true, type: "date", input: true },
      { field: "period_end_date", label: "Duration To", require: true, view: true, type: "date", input: true },
      { field: "agreement_document", label: "Agreement Document", require: true, view: false, type: "file", input: true },
      { field: "remarks", label: "Remarks", require: false, view: true, type: "textarea", input: true },
    ],
    [CompanyMaster, divisionOptions, branchOptions, deptOptions, serviceOptions, options, isFixed, isVariable]
  );
};

/**
 * Header fields for a Vendor Driven (VENDOR_BILL) submission — a standalone,
 * retrospective Service PO, no agreement/recurrence involved at all (see
 * sp_nt_CreateServiceAgreement's THROW 53006 — VENDOR_BILL services can
 * never have an agreement).
 */
export const useVendorDrivenPOFields = (params: OrgCascadeParams | undefined): FieldType[] => {
  const { options } = useMasterOptions(["CompanyMaster", "DivisionMaster", "BranchMaster", "DeptMaster", "VendorMaster"]);
  const { CompanyMaster, divisionOptions, branchOptions, deptOptions } = useOrgCascadeOptions(params, options);

  const poTypeOptions = useMemo(() => ([
    { label: "One Time", value: "ONE_TIME" },
    { label: "Standing", value: "STANDING" },
  ]), []);

  return useMemo<FieldType[]>(
    () => [
      ...orgCascadeFields(CompanyMaster, divisionOptions, branchOptions, deptOptions),
      { field: "vendor_sno", label: "Supplier", require: true, view: false, type: "search-select", options: options?.VendorMaster, input: true },
      { field: "vendor_name", label: "Supplier", require: false, view: true, type: "text", input: false },
      { field: "po_type", label: "PO Type", require: true, view: true, type: "select", options: poTypeOptions, input: true, defaultValue: "ONE_TIME" },
      { field: "delivery_address", label: "Delivery Address", require: false, view: true, type: "textarea", input: true },
      { field: "terms_conditions", label: "Terms & Conditions", require: false, view: true, type: "textarea", input: true },
      { field: "purpose", label: "Purpose", require: false, view: true, type: "textarea", input: true },
    ],
    [CompanyMaster, divisionOptions, branchOptions, deptOptions, options, poTypeOptions]
  );
};

/** One item row of a Vendor Driven PO — field names match sp_nt_CreateServicePO's
 * item JSON shape exactly (service_sno, qty, unit, agreed_unit_price,
 * specification, remarks) so the saved rows can be submitted unmodified. */
export const useVendorDrivenItemFields = (): FieldType[] => {
  const { options } = useMasterOptions(["ServiceMaster", "ServiceTypeMaster", "UomMaster"]);

  const serviceOptions = useMemo(() => {
    const serviceTypeSno = (options?.ServiceTypeMaster ?? []).find(
      (t: CascadeOption) => t.service_type_code === "VENDOR_BILL"
    )?.value;
    if (serviceTypeSno == null) return [];
    return (options?.ServiceMaster ?? []).filter(
      (s: CascadeOption) => String(s.service_type_sno) === String(serviceTypeSno)
    );
  }, [options?.ServiceMaster, options?.ServiceTypeMaster]);

  return useMemo<FieldType[]>(
    () => [
      { field: "service_sno", label: "Service", require: true, view: false, type: "search-select", options: serviceOptions, input: true },
      { field: "service_name", label: "Service", require: false, view: true, type: "text", input: false },
      { field: "qty", label: "Quantity", require: true, view: true, type: "number", input: true, defaultValue: 1 },
      { field: "unit", label: "Unit", require: false, view: false, type: "search-select", options: options?.UomMaster, input: true },
      { field: "unit_name", label: "Unit", require: false, view: true, type: "text", input: false },
      { field: "agreed_unit_price", label: "Unit Price", require: true, view: true, type: "number", input: true },
      { field: "specification", label: "Specification", require: false, view: true, type: "text", input: true },
      { field: "remarks", label: "Remarks", require: false, view: false, type: "textarea", input: true },
    ],
    [serviceOptions, options]
  );
};
