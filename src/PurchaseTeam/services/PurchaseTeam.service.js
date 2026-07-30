import PurchaseTeamRepository from "../repository/PurchaseTeam.repository.js";
import { sendMail, buildPOGeneratedEmail } from "../../Utils/Mailer/mailer.js";
import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";
import { nanoid } from "nanoid";

const SUPPLIER_PORTAL_URL =
  process.env.SUPPLIER_PORTAL_URL || "http://localhost:5173/supplier";

const PO_PDF_SUBDIRECTORY = "NON_TRADE_DATAS/PO_DATAS";

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
    po_basic_sno,
  }) {
    let po_pdf_url;
    try {
      po_pdf_url = await this.storePOPdf({ po_basic_sno, po_no, pdfBuffer, pdfFilename });
    } catch (error) {
      // Storage failure must not block the email that follows.
      console.error("PO PDF storage failed:", error.message);
    }

    try {
      const contact = await this.repo.getVendorContact(vendor_sno);
      if (!contact?.email) {
        return { emailSent: false, reason: "No email on the vendor's KYC record", po_pdf_url };
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

      return { emailSent: mailResult.sent, login_email: contact.email, po_pdf_url };
    } catch (error) {
      console.error("PO email failed:", error.message);
      return { emailSent: false, reason: error.message, po_pdf_url };
    }
  }

  // Uploads the PO PDF to FTP and, when the caller knows which PO row this
  // belongs to (final-approval flow), persists the URL onto po_request_info
  // so the supplier portal can offer it as a download.
  static async storePOPdf({ po_basic_sno, po_no, pdfBuffer, pdfFilename }) {
    if (!pdfBuffer) return undefined;

    const extension = (pdfFilename || "").split(".").pop() || "pdf";
    const uniqueFileName = `${po_no}_${nanoid(8)}.${extension}`;

    const result = await ftpUploader.uploadFile(pdfBuffer, uniqueFileName, PO_PDF_SUBDIRECTORY);
    if (!result.success) {
      console.error("PO PDF FTP upload failed:", result.message);
      return undefined;
    }

    const url = `${process.env.SERVER_URL}/dwl/${PO_PDF_SUBDIRECTORY}/${uniqueFileName}`;

    if (po_basic_sno) {
      await this.repo.savePOPdfUrl(po_basic_sno, url);
    }

    return url;
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
