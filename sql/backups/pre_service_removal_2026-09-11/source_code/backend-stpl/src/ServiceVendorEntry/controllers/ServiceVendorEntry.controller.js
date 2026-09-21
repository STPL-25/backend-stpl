import ServiceVendorEntryService from "../services/ServiceVendorEntry.service.js";
import { invalidateCacheByPattern } from "../../Middleware/redisCache.js";
import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";

const RECEIPT_DOC_SUBDIRECTORY = "NON_TRADE_DATAS/SERVICE_VENDOR_RECEIPTS";

class ServiceVendorEntryController {
  static async createEntry(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const {
        com_sno, div_sno, brn_sno, dept_sno, vendor_sno, service_sno,
        entry_date, qty, unit, unit_price, specification, remarks,
      } = req.body;

      if (!com_sno || !div_sno || !brn_sno || !dept_sno || !vendor_sno || !service_sno || !entry_date) {
        return res.status(400).json({ success: false, error: "com_sno, div_sno, brn_sno, dept_sno, vendor_sno, service_sno and entry_date are required" });
      }
      if (!qty || qty <= 0 || unit_price == null) {
        return res.status(400).json({ success: false, error: "qty (>0) and unit_price are required" });
      }

      // Today's receipt/bill, for verification — required (see
      // sql/46_service_vendor_daily_entry_receipt.sql's THROW 54104).
      let receipt_doc_url = "";
      if (Array.isArray(req.files) && req.files.length) {
        const doc = req.files.find((f) => f.fieldname === "receipt_document") || req.files[0];
        if (doc) {
          receipt_doc_url = await ftpUploader.uploadFileIfExists(doc, RECEIPT_DOC_SUBDIRECTORY);
        }
      }
      if (!receipt_doc_url) {
        return res.status(400).json({ success: false, error: "Receipt/bill document upload failed or was not provided" });
      }

      const data = await ServiceVendorEntryService.createEntry({
        com_sno, div_sno, brn_sno, dept_sno, vendor_sno, service_sno,
        entry_date, qty, unit, unit_price, specification, remarks, receipt_doc_url,
        // created_by is always the authenticated session's ecno, never client-supplied
        created_by: ecno,
      });

      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getEntries(req, res) {
    try {
      const { vendor_sno, service_sno, com_sno, div_sno, brn_sno, dept_sno, status, date_from, date_to, approver_ecno } = req.query;
      const data = await ServiceVendorEntryService.getEntries({
        vendor_sno, service_sno, com_sno, div_sno, brn_sno, dept_sno, status, date_from, date_to, approver_ecno,
      });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async cancelEntry(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { entry_sno } = req.body;
      if (!entry_sno) return res.status(400).json({ success: false, error: "entry_sno is required" });

      const data = await ServiceVendorEntryService.cancelEntry({ entry_sno, cancelled_by: ecno });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async approveEntry(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { entry_sno, action, comments } = req.body;
      if (!entry_sno || !action) {
        return res.status(400).json({ success: false, error: "entry_sno and action are required" });
      }
      if (action === "Reject" && !String(comments || "").trim()) {
        return res.status(400).json({ success: false, error: "comments are required when rejecting" });
      }

      const data = await ServiceVendorEntryService.approveEntry({
        entry_sno,
        action,
        comments,
        // approved_by is always the authenticated session's ecno, never client-supplied
        approved_by: ecno,
      });

      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async consolidate(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { entry_snos, delivery_address, terms_conditions, purpose, po_type } = req.body;
      if (!Array.isArray(entry_snos) || entry_snos.length === 0) {
        return res.status(400).json({ success: false, error: "entry_snos must be a non-empty array" });
      }

      const data = await ServiceVendorEntryService.consolidate({
        entry_snos,
        // consolidated_by is always the authenticated session's ecno, never client-supplied
        consolidated_by: ecno,
        delivery_address, terms_conditions, purpose, po_type,
      });

      await invalidateCacheByPattern(req.redisClient, "service_po:list:*");
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default ServiceVendorEntryController;
