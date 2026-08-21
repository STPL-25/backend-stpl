import ServicePORepository from "../repository/ServicePO.repository.js";
import { sendPOGeneratedEmail } from "../../Utils/Notify/notifyClient.js";

const SUPPLIER_PORTAL_URL = process.env.SUPPLIER_PORTAL_URL || "http://localhost:5173/supplier";

class ServicePOService {
  static repo = new ServicePORepository();

  static async createServicePO(payload) {
    const data = await this.repo.createServicePO(payload);

    // Direct-issue POs (no ServicePO workflow configured for this org scope —
    // see sql/11_service_po_direct_issue.sql) have no approval event to send
    // the vendor notification from, so it fires here instead. Fire-and-forget:
    // the PO is already created and committed: an email failure must not
    // fail this response (same rule PurchaseTeamService.sendPOEmail follows).
    if (data?.[0]?.is_direct_issue) {
      this.sendDirectIssuePOEmail(payload.vendor_sno, data[0]).catch((error) => {
        console.error("Direct-issue ServicePO email failed:", error.message);
      });
    }

    return data;
  }

  static async sendDirectIssuePOEmail(vendor_sno, { po_basic_sno, po_no }) {
    const [contact, items] = await Promise.all([
      this.repo.getVendorContact(vendor_sno),
      this.repo.getPoItemsForEmail(po_basic_sno),
    ]);
    if (!contact?.email) return;

    const totalAmount = items.reduce((sum, it) => sum + (Number(it.total_amount) || 0), 0);

    await sendPOGeneratedEmail({
      to: contact.email,
      companyName: contact.company_name || "Supplier",
      poNo: po_no,
      poDate: new Date().toISOString().slice(0, 10),
      items,
      totalAmount: totalAmount.toFixed(2),
      portalUrl: SUPPLIER_PORTAL_URL,
    });
  }

  static async createCallOffPO(payload) {
    return this.repo.createCallOffPO(payload);
  }

  static async approveServicePO(approvalData) {
    return this.repo.approveServicePO(approvalData);
  }

  static async getServicePORecords(ecno) {
    return this.repo.getServicePORecords(ecno);
  }

  static async getAllServicePOs(filters) {
    return this.repo.getAllServicePOs(filters);
  }

  static async getEligiblePrLines(pr_basic_sno) {
    return this.repo.getEligiblePrLines(pr_basic_sno);
  }
}

export default ServicePOService;
