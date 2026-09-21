import ServicePORepository from "../repository/ServicePO.repository.js";
import { sendPOGeneratedEmail } from "../../Utils/Notify/notifyClient.js";
import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";
import { nanoid } from "nanoid";

const SUPPLIER_PORTAL_URL = process.env.SUPPLIER_PORTAL_URL || "http://localhost:5173/supplier";
const SERVICE_PO_PDF_SUBDIRECTORY = "NON_TRADE_DATAS/SERVICE_PO_DATAS";

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
      this.sendVendorPOEmail(payload.vendor_sno, data[0]).catch((error) => {
        console.error("Direct-issue ServicePO email failed:", error.message);
      });
    }

    return data;
  }

  static async sendVendorPOEmail(vendor_sno, { po_basic_sno, po_no }) {
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

  // Approval itself never emails — same as the regular PO flow
  // (sp_nt_ApproveSupplierQuotation's approve step doesn't email either; the
  // frontend calls sendServicePOEmail separately, right after a successful
  // final-stage approval, with the PDF it just rendered). An earlier version
  // of this method fired a plain-text email straight from here; that's now
  // superseded by sendServicePOEmail below, which attaches a real PDF —
  // keeping both would double-email the vendor.
  static async approveServicePO(approvalData) {
    return this.repo.approveServicePO(approvalData);
  }

  // Emails the supplier the Service PO PDF the frontend already generated
  // (ServicePOApprovalScreen, right after a final-stage approval) — same
  // shape as PurchaseTeamService.sendPOEmail. Never throws: a mail failure
  // must not fail the request after the PO is already approved and committed.
  static async sendServicePOEmail({
    vendor_sno, po_no, po_date, items, terms_conditions, delivery_address,
    pdfBuffer, pdfFilename, po_basic_sno,
  }) {
    let po_pdf_url;
    try {
      po_pdf_url = await this.storeServicePOPdf({ po_basic_sno, po_no, pdfBuffer, pdfFilename });
    } catch (error) {
      console.error("Service PO PDF storage failed:", error.message);
    }

    try {
      const contact = await this.repo.getVendorContact(vendor_sno);
      if (!contact?.email) {
        return { emailSent: false, reason: "No email on the vendor's KYC record", po_pdf_url };
      }

      const safeItems = Array.isArray(items) ? items : [];
      const totalAmount = safeItems.reduce((sum, it) => sum + (Number(it.total_amount) || 0), 0);

      const mailResult = await sendPOGeneratedEmail({
        to: contact.email,
        companyName: contact.company_name || "Supplier",
        poNo: po_no,
        poDate: po_date,
        items: safeItems,
        totalAmount: totalAmount.toFixed(2),
        termsConditions: terms_conditions,
        deliveryAddress: delivery_address,
        portalUrl: SUPPLIER_PORTAL_URL,
        pdfBuffer,
        pdfFilename,
      });

      return { emailSent: mailResult.sent, login_email: contact.email, po_pdf_url };
    } catch (error) {
      console.error("Service PO email failed:", error.message);
      return { emailSent: false, reason: error.message, po_pdf_url };
    }
  }

  static async storeServicePOPdf({ po_basic_sno, po_no, pdfBuffer, pdfFilename }) {
    if (!pdfBuffer) return undefined;

    const extension = (pdfFilename || "").split(".").pop() || "pdf";
    const uniqueFileName = `${po_no}_${nanoid(8)}.${extension}`;

    const result = await ftpUploader.uploadFile(pdfBuffer, uniqueFileName, SERVICE_PO_PDF_SUBDIRECTORY);
    if (!result.success) {
      console.error("Service PO PDF FTP upload failed:", result.message);
      return undefined;
    }

    const url = `${process.env.SERVER_URL}/dwl/${SERVICE_PO_PDF_SUBDIRECTORY}/${uniqueFileName}`;

    if (po_basic_sno) {
      await this.repo.savePOPdfUrl(po_basic_sno, url);
    }

    return url;
  }

  static async reviseServicePOCeiling(payload) {
    return this.repo.reviseServicePOCeiling(payload);
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
