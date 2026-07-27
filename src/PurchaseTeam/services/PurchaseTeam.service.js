import PurchaseTeamRepository from "../repository/PurchaseTeam.repository.js";
import { sendMail, buildPOGeneratedEmail } from "../../Utils/Mailer/mailer.js";

const SUPPLIER_PORTAL_URL =
  process.env.SUPPLIER_PORTAL_URL || "http://localhost:5173/supplier";

class PurchaseTeamService {
  static repo = new PurchaseTeamRepository();

  static async getApprovedPRs(filters) {
    return this.repo.getApprovedPRs(filters);
  }

  static async getApprovedVendors(filters) {
    return this.repo.getApprovedVendors(filters);
  }

  static async createSupplierQuotation(quotationData) {
    return this.repo.createSupplierQuotation(quotationData);
  }

  static async getSupplierQuotations(prBasicSno,pr_no) {
    return this.repo.getSupplierQuotations(prBasicSno,pr_no);
  }

  static async selectQuotation(selectedQuotation, selectedBy) {
    return this.repo.selectQuotation(selectedQuotation, selectedBy);
  }

  static async createPOFromQuotation(poData) {
    return this.repo.createPOFromQuotation(poData);
  }

  // Emails the supplier the PO PDF the frontend already generated (it has
  // the real po_no returned by createPOFromQuotation baked into it). Never
  // throws: a mail failure must not fail the request after the PDF was
  // already generated and the PO already saved.
  static async sendPOEmail({
    vendor_sno,
    po_no,
    po_date,
    required_date,
    terms_conditions,
    delivery_address,
    items,
    pdfBuffer,
    pdfFilename,
  }) {
    try {
      const contact = await this.repo.getVendorContact(vendor_sno);
      if (!contact?.email) {
        return { emailSent: false, reason: "No email on the vendor's KYC record" };
      }

      const safeItems = Array.isArray(items) ? items : [];
      const totalAmount = safeItems.reduce(
        (sum, it) => sum + (Number(it.total_amount) || Number(it.qty) * Number(it.unit_price) || 0),
        0
      );

      const message = buildPOGeneratedEmail({
        to: contact.email,
        companyName: contact.company_name || "Supplier",
        poNo: po_no,
        poDate: po_date,
        requiredDate: required_date,
        items: safeItems,
        totalAmount: totalAmount.toFixed(2),
        termsConditions: terms_conditions,
        deliveryAddress: delivery_address,
        portalUrl: SUPPLIER_PORTAL_URL,
      });

      message.attachments = [
        { filename: pdfFilename || `${po_no}.pdf`, content: pdfBuffer, contentType: "application/pdf" },
      ];
console.log("Sending PO email with message:", message);
      const mailResult = await sendMail(message);

      return { emailSent: mailResult.sent, login_email: contact.email };
    } catch (error) {
      console.error("PO email failed:", error.message);
      return { emailSent: false, reason: error.message };
    }
  }

  static async updateItemQuantity(updateData) {
    return this.repo.updateItemQuantity(updateData);
  }

  static async savePOConfirmation(confirmationData) {
    return this.repo.savePOConfirmation(confirmationData);
  }

  static async getPOConfirmation(prBasicSno) {
    return this.repo.getPOConfirmation(prBasicSno);
  }

  static async saveSplitGroup(splitData) {
    console.log("Saving split group with data:", splitData);
    return this.repo.saveSplitGroup(splitData);
  }

  static async getSplitGroups(prBasicSno) {
    return this.repo.getSplitGroups(prBasicSno);
  }

  static async updateSplitGroupOrg(data) {
    return this.repo.updateSplitGroupOrg(data);
  }

  static async saveQuotationDraft(redisClient, ecno, draftData) {
    return this.repo.saveQuotationDraft(redisClient, ecno, draftData);
  }

  static async getQuotationDrafts(redisClient, ecno) {
    return this.repo.getQuotationDrafts(redisClient, ecno);
  }

  static async deleteQuotationDraft(redisClient, ecno, draftId) {
    return this.repo.deleteQuotationDraft(redisClient, ecno, draftId);
  }
}

export default PurchaseTeamService;
