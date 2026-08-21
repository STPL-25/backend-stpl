import ServiceAgreementService from "../services/ServiceAgreement.service.js";
import { invalidateCacheByPattern } from "../../Middleware/redisCache.js";
import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";

const AGREEMENT_DOC_SUBDIRECTORY = "NON_TRADE_DATAS/SERVICE_AGREEMENTS";

class ServiceAgreementController {
  static async createServiceAgreement(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const {
        com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
        rate_amount, rate_uom_sno, recurrence_cadence,
        period_start_date, period_end_date, remarks,
      } = req.body;

      if (!com_sno || !div_sno || !brn_sno || !dept_sno || !service_sno) {
        return res.status(400).json({ success: false, error: "com_sno, div_sno, brn_sno, dept_sno and service_sno are required" });
      }
      if (!rate_amount || !period_start_date || !period_end_date) {
        return res.status(400).json({ success: false, error: "rate_amount, period_start_date and period_end_date are required" });
      }

      // Upload the agreement/contract document to FTP. Required — a Service
      // Agreement can't be submitted without one (see
      // sql/10_service_agreement.sql's agreement_doc_url NOT NULL + THROW 53004).
      let agreement_doc_url = "";
      if (Array.isArray(req.files) && req.files.length) {
        const doc = req.files.find((f) => f.fieldname === "agreement_document") || req.files[0];
        if (doc) {
          agreement_doc_url = await ftpUploader.uploadFileIfExists(doc, AGREEMENT_DOC_SUBDIRECTORY);
        }
      }
      if (!agreement_doc_url) {
        return res.status(400).json({ success: false, error: "Agreement document upload failed or was not provided" });
      }

      const data = await ServiceAgreementService.createServiceAgreement({
        com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
        rate_amount, rate_uom_sno, recurrence_cadence,
        period_start_date, period_end_date, remarks,
        agreement_doc_url,
        // created_by is always the authenticated session's ecno, never client-supplied
        created_by: ecno,
      });

      await invalidateCacheByPattern(req.redisClient, "service_agreement:list:*");
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async approveServiceAgreement(req, res) {
    try {
      const { agreement_sno, comments, approval_stages, action } = req.body;
      const ecno = req.user_ecno;

      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      if (!agreement_sno || !action) {
        return res.status(400).json({ success: false, error: "agreement_sno and action are required" });
      }
      if (action === "reject" && !comments?.trim()) {
        return res.status(400).json({ success: false, error: "comments are required when rejecting" });
      }

      const data = await ServiceAgreementService.approveServiceAgreement({
        agreement_sno,
        // approved_by comes from the session, never the request body — a
        // client-supplied ecno would let anyone forge who approved an agreement
        approved_by: ecno,
        comments: comments || "",
        approval_stages,
        action,
      });

      await invalidateCacheByPattern(req.redisClient, "service_agreement:list:*");

      req.io.to("service_agreement:approval").emit("service_agreement:approval:updated", {
        agreement_sno,
        action,
        approved_by: ecno,
      });

      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getServiceAgreements(req, res) {
    try {
      const data = await ServiceAgreementService.getServiceAgreements(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // The PR-line auto-fill lookup (spec §5): the one Approved, in-period
  // agreement for an exact company/division/branch/department + service.
  static async getActiveServiceAgreement(req, res) {
    try {
      const { com_sno, div_sno, brn_sno, dept_sno, service_sno } = req.query;
      if (!com_sno || !div_sno || !brn_sno || !dept_sno || !service_sno) {
        return res.status(400).json({ success: false, error: "com_sno, div_sno, brn_sno, dept_sno and service_sno are required" });
      }

      const data = await ServiceAgreementService.getActiveServiceAgreement({
        com_sno, div_sno, brn_sno, dept_sno, service_sno,
      });

      // Zero rows means "no active agreement" (spec §5) — not an error, just
      // nothing to auto-fill with; the caller (PR line) blocks on a null data.
      res.json({ success: true, data: data?.[0] || null });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getServiceAgreementsForApproval(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const data = await ServiceAgreementService.getServiceAgreementsForApproval(ecno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default ServiceAgreementController;
