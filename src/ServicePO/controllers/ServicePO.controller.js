import ServicePOService from "../services/ServicePO.service.js";
import { invalidateCacheByPattern } from "../../Middleware/redisCache.js";

class ServicePOController {
  static async createServicePO(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const {
        pr_basic_sno, vendor_sno, service_type_code, po_type,
        validity_from, validity_to, ceiling_amount, variance_tolerance_pct,
        is_retrospective, parent_blanket_po_sno,
        delivery_address, terms_conditions, purpose,
        com_sno, div_sno, brn_sno, dept_sno, budget_sno, budget_code,
        items,
      } = req.body;

      if (!vendor_sno || !service_type_code || !items?.length) {
        return res.status(400).json({ success: false, error: "vendor_sno, service_type_code and at least one item are required" });
      }

      const data = await ServicePOService.createServicePO({
        pr_basic_sno, vendor_sno, service_type_code, po_type,
        validity_from, validity_to, ceiling_amount, variance_tolerance_pct,
        is_retrospective, parent_blanket_po_sno,
        delivery_address, terms_conditions, purpose,
        com_sno, div_sno, brn_sno, dept_sno, budget_sno, budget_code,
        // created_by is always the authenticated session's ecno, never client-supplied
        created_by: ecno,
        items,
      });

      await invalidateCacheByPattern(req.redisClient, "service_po:list:*");
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async createCallOffPO(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { parent_blanket_po_sno, invoice_sno, delivery_address, terms_conditions, purpose, items } = req.body;

      if (!parent_blanket_po_sno || !items?.length) {
        return res.status(400).json({ success: false, error: "parent_blanket_po_sno and at least one item are required" });
      }

      const data = await ServicePOService.createCallOffPO({
        parent_blanket_po_sno, invoice_sno, delivery_address, terms_conditions, purpose,
        created_by: ecno,
        items,
      });

      await invalidateCacheByPattern(req.redisClient, "service_po:list:*");
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async approveServicePO(req, res) {
    try {
      const { po_basic_sno, comments, approval_stages, action } = req.body;
      const ecno = req.user_ecno;

      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      if (!po_basic_sno || !action) {
        return res.status(400).json({ success: false, error: "po_basic_sno and action are required" });
      }
      if (action === "reject" && !comments?.trim()) {
        return res.status(400).json({ success: false, error: "comments are required when rejecting" });
      }

      const data = await ServicePOService.approveServicePO({
        po_basic_sno,
        approved_by: ecno,
        comments: comments || "",
        approval_stages,
        action,
      });

      await invalidateCacheByPattern(req.redisClient, "service_po:list:*");

      req.io.to("service_po:approval").emit("service_po:approval:updated", {
        po_basic_sno,
        action,
        approved_by: ecno,
      });

      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // ── EMAIL THE GENERATED SERVICE PO PDF TO THE SUPPLIER ──────────────────
  // Mirrors PurchaseTeamController.sendPOEmail exactly — called by
  // ServicePOApprovalScreen right after a final-stage approval, with the PDF
  // it just rendered client-side.
  static async sendServicePOEmail(req, res) {
    try {
      const file = Array.isArray(req.files)
        ? req.files.find((f) => f.fieldname === "po_pdf") || req.files[0]
        : null;
      if (!file) return res.status(400).json({ success: false, error: "po_pdf file is required" });

      const { vendor_sno, po_no, po_date, terms_conditions, delivery_address, po_basic_sno } = req.body;
      if (!vendor_sno || !po_no) {
        return res.status(400).json({ success: false, error: "vendor_sno and po_no are required" });
      }

      let items = [];
      try {
        items = JSON.parse(req.body.items || "[]");
      } catch {
        items = [];
      }

      const data = await ServicePOService.sendServicePOEmail({
        vendor_sno: Number(vendor_sno),
        po_no,
        po_date,
        terms_conditions,
        delivery_address,
        items,
        pdfBuffer: file.buffer,
        pdfFilename: file.originalname || `${po_no}.pdf`,
        po_basic_sno: po_basic_sno ? Number(po_basic_sno) : undefined,
      });

      await invalidateCacheByPattern(req.redisClient, "service_po:list:*");
      res.json({ success: true, data, message: "Service Purchase Order emailed to supplier" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async reviseServicePOCeiling(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { po_basic_sno, ceiling_amount, variance_tolerance_pct, comments } = req.body;
      if (!po_basic_sno || (ceiling_amount == null && variance_tolerance_pct == null)) {
        return res.status(400).json({ success: false, error: "po_basic_sno and at least one of ceiling_amount/variance_tolerance_pct are required" });
      }

      const data = await ServicePOService.reviseServicePOCeiling({
        po_basic_sno, ceiling_amount, variance_tolerance_pct, comments,
        revised_by: ecno,
      });

      await invalidateCacheByPattern(req.redisClient, "service_po:list:*");
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getServicePORecords(req, res) {
    try {
      const ecno = req.user_ecno;
      const data = await ServicePOService.getServicePORecords(ecno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getAllServicePOs(req, res) {
    try {
      const { status, vendor_sno } = req.query;
      const data = await ServicePOService.getAllServicePOs({ status, vendor_sno });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getEligiblePrLines(req, res) {
    try {
      const { pr_basic_sno } = req.query;
      if (!pr_basic_sno) {
        return res.status(400).json({ success: false, error: "pr_basic_sno is required" });
      }
      const data = await ServicePOService.getEligiblePrLines(pr_basic_sno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default ServicePOController;
