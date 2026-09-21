// Supplier/Incharge dispatch for an auto-issued Service PO
// (sql/81_service_agreement_dispatch_grn.sql). Deliberately reuses existing
// infrastructure rather than adding a parallel one:
//   - sendPOGeneratedEmail / createInAppNotification
//     (Utils/Notify/notifyClient.js) — the same notification-service calls
//     PurchaseTeamService.sendPOEmail already uses for the regular PO flow.
//   - logPOSentToSupplier (sp_nt_LogPOSentToSupplier, sql/29_pr_tracking.sql)
//     — the same po_history_data audit row the regular PO flow already logs.
// Called from both PO-issuance paths: inline at an agreement's final
// approval (ServiceAgreement.controller.js) and from the hourly recurring
// sweep (ServiceAgreement/jobs/AgreementPoJob.js).
import { sendPOGeneratedEmail, createInAppNotification } from "../../Utils/Notify/notifyClient.js";
import ServiceAgreementRepository from "../repository/ServiceAgreement.repository.js";

const SUPPLIER_PORTAL_URL = process.env.SUPPLIER_PORTAL_URL || "http://localhost:5173/supplier";

const repo = new ServiceAgreementRepository();

// Never throws — a dispatch failure must not fail the approval/sweep that
// triggered it (same philosophy as sp_approve_service_agreement's own
// PO-issuance try/catch). Failures are just console-logged; nothing else in
// this module persists a dispatch-attempt row, since po_history_data (via
// logPOSentToSupplier/logServiceDispatchToIncharge) already is that record.
async function dispatchServicePo(po_basic_sno) {
  if (!po_basic_sno) return;

  let info;
  try {
    info = await repo.getServicePoDispatchInfo(po_basic_sno);
  } catch (error) {
    console.error(`Service PO dispatch: failed to load info for PO ${po_basic_sno}:`, error.message);
    return;
  }
  if (!info) {
    console.error(`Service PO dispatch: PO ${po_basic_sno} has no dispatch info (not a service PO?).`);
    return;
  }

  try {
    if (info.dispatch_type === "I") {
      if (info.incharge_ecno) {
        const result = await createInAppNotification({
          ecno: info.incharge_ecno,
          type: "info",
          title: "Service PO assigned to you",
          message: `PO ${info.po_no} for ${info.service_name} (Agreement ${info.agreement_no}) needs to be fulfilled — you're the configured Incharge for this service.`,
          data: { po_basic_sno, agreement_sno: info.agreement_sno },
        });
        if (!result.sent) {
          console.error(`Service PO dispatch: in-app notify to incharge ${info.incharge_ecno} failed for PO ${info.po_no}: ${result.reason}`);
        }
      } else {
        console.error(`Service PO dispatch: PO ${info.po_no} routed to Incharge but service has no incharge_ecno configured.`);
      }

      await repo.logServiceDispatchToIncharge(
        po_basic_sno,
        info.incharge_ecno || "SYSTEM",
        `Service PO routed to Incharge${info.incharge_ecno ? ` ${info.incharge_ecno}` : " (none configured)"}.`
      );
      return;
    }

    // Supplier path (default / dispatch_type === 'S')
    if (info.vendor_email) {
      const totalAmount = (Number(info.rate_amount) * Number(info.qty)).toFixed(2);
      const mailResult = await sendPOGeneratedEmail({
        to: info.vendor_email,
        companyName: info.vendor_name || "Supplier",
        poNo: info.po_no,
        poDate: info.po_date,
        requiredDate: info.required_date,
        items: [{ prod_name: info.service_name, qty: info.qty, unit_price: info.rate_amount, total_amount: totalAmount }],
        totalAmount,
        termsConditions: null,
        deliveryAddress: null,
        portalUrl: SUPPLIER_PORTAL_URL,
      });
      if (!mailResult.sent) {
        console.error(`Service PO dispatch: email to supplier failed for PO ${info.po_no}: ${mailResult.reason}`);
      }
    } else {
      console.error(`Service PO dispatch: PO ${info.po_no}'s vendor has no email on file — skipping email, still logging as sent.`);
    }

    await repo.logPOSentToSupplier(po_basic_sno, info.created_by || "SYSTEM", "Service PO auto-issued and emailed to supplier.");

    if (info.created_by) {
      const result = await createInAppNotification({
        ecno: info.created_by,
        type: "success",
        title: "Service PO sent to supplier",
        message: `PO ${info.po_no} for Agreement ${info.agreement_no} was sent to ${info.vendor_name || "the supplier"}.`,
        data: { po_basic_sno, agreement_sno: info.agreement_sno },
      });
      if (!result.sent) {
        console.error(`Service PO dispatch: in-app confirmation to ${info.created_by} failed for PO ${info.po_no}: ${result.reason}`);
      }
    }
  } catch (error) {
    console.error(`Service PO dispatch crashed for PO ${po_basic_sno}:`, error.message);
  }
}

export { dispatchServicePo };
