import { useMemo } from "react";
import { useMasterOptions } from "../hooks/ReUsableHook/useMasterOptions";
import { FieldType } from "./fieldType/fieldType";

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

/** VENDOR_BILL-only service options, same filter-by-service_type_code idiom as ServiceAgreementData.tsx. */
function useVendorBillServiceOptions(options: any) {
  return useMemo(() => {
    const serviceTypeSno = (options?.ServiceTypeMaster ?? []).find(
      (t: CascadeOption) => t.service_type_code === "VENDOR_BILL"
    )?.value;
    if (serviceTypeSno == null) return [];
    return (options?.ServiceMaster ?? []).filter(
      (s: CascadeOption) => String(s.service_type_sno) === String(serviceTypeSno)
    );
  }, [options?.ServiceMaster, options?.ServiceTypeMaster]);
}

/**
 * One daily log entry — e.g. "milk delivered today: 20 L @ 45.50". Saved
 * immediately (sp_nt_CreateServiceVendorDailyEntry) as a PENDING row, not
 * submitted as a PO — entries accumulate until someone consolidates a batch
 * of them into one PO on the Vendor Entry Consolidation screen.
 */
export const useServiceVendorDailyEntryFields = (params: OrgCascadeParams | undefined): FieldType[] => {
  const { options } = useMasterOptions(["CompanyMaster", "DivisionMaster", "BranchMaster", "DeptMaster", "ServiceMaster", "ServiceTypeMaster", "VendorMaster", "UomMaster"]);
  const { CompanyMaster, divisionOptions, branchOptions, deptOptions } = useOrgCascadeOptions(params, options);
  const serviceOptions = useVendorBillServiceOptions(options);

  return useMemo<FieldType[]>(
    () => [
      ...orgCascadeFields(CompanyMaster, divisionOptions, branchOptions, deptOptions),
      { field: "vendor_sno", label: "Supplier", require: true, view: false, type: "search-select", options: options?.VendorMaster, input: true },
      { field: "vendor_name", label: "Supplier", require: false, view: true, type: "text", input: false },
      { field: "service_sno", label: "Service", require: true, view: false, type: "search-select", options: serviceOptions, input: true },
      { field: "service_name", label: "Service", require: false, view: true, type: "text", input: false },
      { field: "entry_date", label: "Entry Date", require: true, view: true, type: "date", input: true },
      { field: "qty", label: "Quantity", require: true, view: true, type: "number", input: true },
      { field: "unit", label: "Unit", require: false, view: false, type: "search-select", options: options?.UomMaster, input: true },
      { field: "unit_name", label: "Unit", require: false, view: true, type: "text", input: false },
      { field: "unit_price", label: "Unit Price", require: true, view: true, type: "number", input: true },
      { field: "specification", label: "Specification", require: false, view: true, type: "text", input: true },
      { field: "remarks", label: "Remarks", require: false, view: false, type: "textarea", input: true },
      { field: "receipt_document", label: "Today's Receipt/Bill", require: true, view: false, type: "file", input: true },
    ],
    [CompanyMaster, divisionOptions, branchOptions, deptOptions, serviceOptions, options]
  );
};

/** Filter bar on the Vendor Entry Consolidation screen — vendor is required
 * (a PO is per-vendor), everything else narrows the pending-entry list. */
export const useServiceVendorEntryFilterFields = (params: OrgCascadeParams | undefined): FieldType[] => {
  const { options } = useMasterOptions(["CompanyMaster", "DivisionMaster", "BranchMaster", "DeptMaster", "ServiceMaster", "ServiceTypeMaster", "VendorMaster"]);
  const { CompanyMaster, divisionOptions, branchOptions, deptOptions } = useOrgCascadeOptions(params, options);
  const serviceOptions = useVendorBillServiceOptions(options);

  return useMemo<FieldType[]>(
    () => [
      ...orgCascadeFields(CompanyMaster, divisionOptions, branchOptions, deptOptions),
      { field: "vendor_sno", label: "Supplier", require: true, view: false, type: "search-select", options: options?.VendorMaster, input: true },
      { field: "vendor_name", label: "Supplier", require: false, view: true, type: "text", input: false },
      { field: "service_sno", label: "Service", require: false, view: false, type: "search-select", options: serviceOptions, input: true },
      { field: "date_from", label: "From Date", require: false, view: true, type: "date", input: true },
      { field: "date_to", label: "To Date", require: false, view: true, type: "date", input: true },
    ],
    [CompanyMaster, divisionOptions, branchOptions, deptOptions, serviceOptions, options]
  );
};

/** PO header details captured once, at the moment of raising the consolidated PO. */
export const useServiceVendorConsolidationPOFields = (): FieldType[] => {
  const poTypeOptions = useMemo(() => ([
    { label: "One Time", value: "ONE_TIME" },
    { label: "Standing", value: "STANDING" },
  ]), []);

  return useMemo<FieldType[]>(
    () => [
      { field: "po_type", label: "PO Type", require: true, view: true, type: "select", options: poTypeOptions, input: true, defaultValue: "ONE_TIME" },
      { field: "delivery_address", label: "Delivery Address", require: false, view: true, type: "textarea", input: true },
      { field: "terms_conditions", label: "Terms & Conditions", require: false, view: true, type: "textarea", input: true },
      { field: "purpose", label: "Purpose", require: false, view: true, type: "textarea", input: true },
    ],
    [poTypeOptions]
  );
};
