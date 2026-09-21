import { useMemo } from "react";
import { useMasterOptions } from "../hooks/ReUsableHook/useMasterOptions";
import { FieldType } from "./fieldType/fieldType";
import { useBankFields } from "./KycFieldDatas";

interface CascadeOption {
  value: string | number;
  label: string;
  com_sno?: string | number | null;
  div_sno?: string | number | null;
  brn_sno?: string | number | null;
}

interface OrgCascadeParams {
  selectedCompany?: string;
  selectedDivision?: string;
  selectedBranch?: string;
}

/** Same client-side-filter-by-parent-selection cascade as ServiceAgreementData.tsx. */
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

const YES_NO_OPTIONS = [
  { label: "Yes", value: "true" },
  { label: "No", value: "false" },
];

/**
 * Fields for the Service Vendor KYC create form — a separate onboarding/
 * approval path from the existing goods/trade vendor KYC (Kyc module,
 * kyc_basic_info), see sql/43_service_vendor_kyc.sql's header for why.
 */
export const useServiceVendorKycFields = (params: OrgCascadeParams | undefined): FieldType[] => {
  const { options } = useMasterOptions(["CompanyMaster", "DivisionMaster", "BranchMaster", "DeptMaster", "SupplierCatagoryMaster", "PaymentModeMaster"]);
  const { CompanyMaster, divisionOptions, branchOptions, deptOptions } = useOrgCascadeOptions(params, options);
  // Reused as-is from the main/goods KYC form (KycFieldDatas.tsx) — same 7
  // account fields (ac_holder_name/ac_number/ac_type/ifsc/bank_name/
  // bank_branch_name/bank_address), single primary account (no array here,
  // unlike goods KYC's multi-account bankDetails list).
  const bankFields = useBankFields();

  return useMemo<FieldType[]>(
    () => [
      ...orgCascadeFields(CompanyMaster, divisionOptions, branchOptions, deptOptions),
      { field: "company_name", label: "Company Name", require: true, view: true, type: "text", input: true },
      { field: "contact_person", label: "Contact Person", require: true, view: true, type: "text", input: true },
      { field: "mobile_number", label: "Mobile Number", require: true, view: true, type: "text", input: true },
      { field: "email", label: "Email", require: true, view: true, type: "text", input: true },
      { field: "business_type", label: "Business Type", require: true, view: true, type: "text", input: true },
      { field: "pan_no", label: "PAN Number", require: true, view: true, type: "text", input: true },
      { field: "supplier_cat_code", label: "Supplier Category", require: false, view: true, type: "select", options: options?.SupplierCatagoryMaster, input: true },
      { field: "is_gst_avail", label: "GST Available", require: false, view: true, type: "select", options: YES_NO_OPTIONS, input: true, defaultValue: "false" },
      { field: "gst_no", label: "GST Number", require: false, view: true, type: "text", input: true },
      { field: "is_msme_avail", label: "MSME Available", require: false, view: true, type: "select", options: YES_NO_OPTIONS, input: true, defaultValue: "false" },
      { field: "msme_no", label: "MSME Number", require: false, view: true, type: "text", input: true },
      ...bankFields,
      { field: "preferred_payment_mode", label: "Preferred Payment Mode", require: false, view: true, type: "select", options: options?.PaymentModeMaster, input: true },
      { field: "kyc_document", label: "Supporting Document (PAN / GST / etc.)", require: true, view: false, type: "file", input: true },
      { field: "remarks", label: "Remarks", require: false, view: true, type: "textarea", input: true },
    ],
    [CompanyMaster, divisionOptions, branchOptions, deptOptions, options, bankFields]
  );
};
