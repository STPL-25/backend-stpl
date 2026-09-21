import { FieldType } from "./fieldType/fieldType";
import { useMemo } from "react";

export const useServiceVendorKycApprovalSideCardDatas = (): FieldType[] => {
  return useMemo<FieldType[]>(
    () => [
      { field: "service_vendor_code",  label: "Vendor Code",         view: true, type: "text", input: false },
      { field: "company_name",         label: "Company Name",        view: true, type: "text", input: false },
      { field: "contact_person",       label: "Contact Person",      view: true, type: "text", input: false },
      { field: "mobile_number",        label: "Mobile Number",       view: true, type: "text", input: false },
      { field: "email",                label: "Email",               view: true, type: "text", input: false },
      { field: "business_type",        label: "Business Type",       view: true, type: "text", input: false },
      { field: "pan_no",               label: "PAN Number",          view: true, type: "text", input: false },
      { field: "gst_no",               label: "GST Number",          view: true, type: "text", input: false },
      { field: "msme_no",              label: "MSME Number",         view: true, type: "text", input: false },
      { field: "supplier_cat_code",    label: "Supplier Category",   view: true, type: "text", input: false },
      { field: "current_approver_id",  label: "Current Approver",    view: true, type: "text", input: false },
    ],
    []
  );
};
