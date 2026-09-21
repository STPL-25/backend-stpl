import ServiceGrnService from "../services/ServiceGrn.service.js";
import { invalidateCacheByPattern } from "../../Middleware/redisCache.js";
import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";

const INVOICE_DOC_SUBDIRECTORY = "NON_TRADE_DATAS/SERVICE_GRN_INVOICES";

class ServiceGrnController {
  // Minimal receipt record for an Unfixed service agreement's PO — PO
  // reference, invoice number, invoice file (required), received date,
  // remarks. Deliberately no stock/qty/FIFO tracking (out of scope, see
  // sql/81_service_agreement_dispatch_grn.sql header).
  static async createServiceGrn(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { po_basic_sno, invoice_no, received_date, remarks } = req.body;

      if (!po_basic_sno || !invoice_no || !received_date) {
        return res.status(400).json({ success: false, error: "po_basic_sno, invoice_no and received_date are required" });
      }

      let invoice_doc_url = "";
      if (Array.isArray(req.files) && req.files.length) {
        const doc = req.files.find((f) => f.fieldname === "invoice_document") || req.files[0];
        if (doc) {
          invoice_doc_url = await ftpUploader.uploadFileIfExists(doc, INVOICE_DOC_SUBDIRECTORY);
        }
      }
      if (!invoice_doc_url) {
        return res.status(400).json({ success: false, error: "Invoice document upload failed or was not provided" });
      }

      const data = await ServiceGrnService.createServiceGrn({
        po_basic_sno: Number(po_basic_sno),
        invoice_no,
        invoice_doc_url,
        received_date,
        remarks,
        // entered_by is always the authenticated session's ecno, never client-supplied
        entered_by: ecno,
      });

      await invalidateCacheByPattern(req.redisClient, "service_grn:list:*");

      res.json({ success: true, data });
    } catch (error) {
      console.error("Error in createServiceGrn:", error);
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getPendingServiceGrnPOs(req, res) {
    try {
      const data = await ServiceGrnService.getPendingServiceGrnPOs(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getServiceGrns(req, res) {
    try {
      const data = await ServiceGrnService.getServiceGrns(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default ServiceGrnController;
