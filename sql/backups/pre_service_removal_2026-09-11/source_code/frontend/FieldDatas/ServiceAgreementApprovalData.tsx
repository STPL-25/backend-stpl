import { FieldType } from "./fieldType/fieldType";
import { useMemo } from "react";

export const useServiceAgreementApprovalSideCardDatas = (): FieldType[] => {
  return useMemo<FieldType[]>(
    () => [
      { field: "agreement_no",         label: "Agreement No",        view: true, type: "text", input: false },
      { field: "service_name",         label: "Service",             view: true, type: "text", input: false },
      { field: "vendor_name",          label: "Supplier",            view: true, type: "text", input: false },
      { field: "rate_amount",          label: "Rate Amount",         view: true, type: "text", input: false },
      { field: "ceiling_amount",       label: "Ceiling Amount",      view: true, type: "text", input: false },
      { field: "variance_tolerance_pct", label: "Variance Tolerance (%)", view: true, type: "text", input: false },
      { field: "recurrence_cadence",   label: "Recurrence Cadence",  view: true, type: "text", input: false },
      { field: "po_generation_day",    label: "PO Generation Day",   view: true, type: "text", input: false },
      { field: "notify_days_before",   label: "Notify Before (days)", view: true, type: "text", input: false },
      { field: "period_start_date",    label: "Duration From",       view: true, type: "date", input: false },
      { field: "period_end_date",      label: "Duration To",         view: true, type: "date", input: false },
      { field: "current_approver_id",  label: "Current Approver",    view: true, type: "text", input: false },
    ],
    []
  );
};
