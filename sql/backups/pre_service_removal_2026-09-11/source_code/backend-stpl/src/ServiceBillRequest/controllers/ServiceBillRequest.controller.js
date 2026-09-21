import ServiceBillRequestService from "../services/ServiceBillRequest.service.js";
import { invalidateCacheByPattern } from "../../Middleware/redisCache.js";
import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";

const INVOICE_DOC_SUBDIRECTORY = "NON_TRADE_DATAS/SERVICE_BILL_REQUESTS";

class ServiceBillRequestController {
  static async createServiceBillRequest(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const {
        agreement_sno, billing_period_start, billing_period_end,
        invoice_no, invoice_date, remarks,
      } = req.body;

      if (!agreement_sno || !billing_period_start || !billing_period_end) {
        return res.status(400).json({ success: false, error: "agreement_sno, billing_period_start and billing_period_end are required" });
      }

      let items = [];
      try {
        items = JSON.parse(req.body.items || "[]");
      } catch {
        items = [];
      }
      if (!Array.isArray(items) || items.length === 0) {
        return res.status(400).json({ success: false, error: "At least one item (service, qty, unit_price) is required" });
      }

      // Upload the invoice document to FTP — required, same pattern as
      // ServiceAgreement's agreement_document (sql/23_..._redesign.sql's
      // invoice_doc_url NOT NULL + THROW 56013).
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

      const data = await ServiceBillRequestService.createServiceBillRequest({
        agreement_sno, billing_period_start, billing_period_end,
        invoice_no, invoice_date, invoice_doc_url, remarks, items,
        // created_by is always the authenticated session's ecno, never client-supplied
        created_by: ecno,
      });

      res.json({ success: true, data });
    } catch (error) {
      console.error("Error in createServiceBillRequest:", error);
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async approveServiceBillRequest(req, res) {
    try {
      const { bill_request_sno, comments, approval_stages, action } = req.body;
      const ecno = req.user_ecno;

      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      if (!bill_request_sno || !action) {
        return res.status(400).json({ success: false, error: "bill_request_sno and action are required" });
      }
      if (action === "reject" && !comments?.trim()) {
        return res.status(400).json({ success: false, error: "comments are required when rejecting" });
      }

      const data = await ServiceBillRequestService.approveServiceBillRequest({
        bill_request_sno,
        // approved_by comes from the session, never the request body — a
        // client-supplied ecno would let anyone forge who approved a bill
        approved_by: ecno,
        comments: comments || "",
        approval_stages,
        action,
      });

      await invalidateCacheByPattern(req.redisClient, "service_bill_request:list:*");

      req.io.to("service_bill_request:approval").emit("service_bill_request:approval:updated", {
        bill_request_sno,
        action,
        approved_by: ecno,
      });

      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getServiceBillRequests(req, res) {
    try {
      const data = await ServiceBillRequestService.getServiceBillRequests(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getActiveCeilingAgreementsForBilling(req, res) {
    try {
      const { com_sno, div_sno, brn_sno, dept_sno, service_sno } = req.query;
      if (!com_sno || !div_sno || !brn_sno || !dept_sno) {
        return res.status(400).json({ success: false, error: "com_sno, div_sno, brn_sno and dept_sno are required" });
      }

      const data = await ServiceBillRequestService.getActiveCeilingAgreementsForBilling({
        com_sno, div_sno, brn_sno, dept_sno, service_sno,
      });

      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async retryPOIssue(req, res) {
    try {
      const { bill_request_sno } = req.body;
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      if (!bill_request_sno) {
        return res.status(400).json({ success: false, error: "bill_request_sno is required" });
      }

      const data = await ServiceBillRequestService.retryPOIssue({ bill_request_sno, issued_by: ecno });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getServiceBillRequestsForApproval(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const data = await ServiceBillRequestService.getServiceBillRequestsForApproval(ecno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default ServiceBillRequestController;
