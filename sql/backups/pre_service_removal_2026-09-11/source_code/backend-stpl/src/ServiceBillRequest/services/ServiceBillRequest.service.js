import ServiceBillRequestRepository from "../repository/ServiceBillRequest.repository.js";
import ServicePOService from "../../ServicePO/services/ServicePO.service.js";

class ServiceBillRequestService {
  static repo = new ServiceBillRequestRepository();

  static async createServiceBillRequest(payload) {
    return this.repo.createServiceBillRequest(payload);
  }

  // On final approval, sp_nt_ApproveServiceBillRequest auto-issues the
  // Service PO itself (SQL-layer, bypassing this Node service) and returns
  // the vendor_sno alongside it — same reasoning as every other auto-issue
  // path this session: some Variable Recurring services (AWS, electricity)
  // genuinely have no supplier PO relationship, so this best-effort emails
  // the vendor ONLY when one is on file; incharge visibility (the primary
  // channel per the user's own framing) comes from the existing Recurring
  // POs tab on ServiceAgreementListPage, which needs no extra wiring here —
  // it already reads any po_request_info row regardless of how it was issued.
  static async approveServiceBillRequest(approvalData) {
    const data = await this.repo.approveServiceBillRequest(approvalData);

    const row = data?.[0];
    if (row?.result === "SUCCESS" && row?.auto_po_basic_sno && row?.auto_po_vendor_sno) {
      ServicePOService.sendVendorPOEmail(row.auto_po_vendor_sno, {
        po_basic_sno: row.auto_po_basic_sno,
        po_no: row.auto_po_no,
      }).catch((error) => {
        console.error("Service Bill Request auto-issued PO email failed:", error.message);
      });
    }

    return data;
  }

  static async getServiceBillRequests(filters) {
    return this.repo.getServiceBillRequests(filters);
  }

  static async getActiveCeilingAgreementsForBilling(scope) {
    return this.repo.getActiveCeilingAgreementsForBilling(scope);
  }

  static async retryPOIssue(payload) {
    return this.repo.retryPOIssue(payload);
  }

  static async getServiceBillRequestsForApproval(ecno) {
    return this.repo.getServiceBillRequestsForApproval(ecno);
  }
}

export default ServiceBillRequestService;
