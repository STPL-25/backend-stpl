import { FieldType } from "./fieldType/fieldType";
import { useMemo } from "react";

export const useServicePoApprovalSideCardDatas = (): FieldType[] => {
  return useMemo<FieldType[]>(
    () => [
      { field: "po_no",                  label: "Service PO No",  view: true, type: "text", input: false },
      { field: "pr_no",                  label: "Source PR",      view: true, type: "text", input: false },
      { field: "vendor_name",            label: "Vendor",         view: true, type: "text", input: false },
      { field: "service_type_name",      label: "Billing Pattern",view: true, type: "text", input: false },
      { field: "po_type",                label: "PO Type",        view: true, type: "text", input: false },
      { field: "validity_from",          label: "Validity From",  view: true, type: "date", input: false },
      { field: "validity_to",            label: "Validity To",    view: true, type: "date", input: false },
      { field: "ceiling_amount",         label: "Ceiling Amount", view: true, type: "text", input: false },
      { field: "current_approver_id",    label: "Current Approver", view: true, type: "text", input: false },
    ],
    []
  );
};
