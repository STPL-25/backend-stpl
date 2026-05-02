import PurchaseTeamService from "../services/PurchaseTeam.service.js";
import { invalidateCache, invalidateCacheByPattern } from "../../Middleware/redisCache.js";

function getAuthUser(req) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  return user;
}

class PurchaseTeamController {
  // ── GET APPROVED PRs ────────────────────────────────────────────────────
  static async getApprovedPRs(req, res) {
    try {
      const data = await PurchaseTeamService.getApprovedPRs(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // ── GET APPROVED VENDORS ────────────────────────────────────────────────
  static async getApprovedVendors(req, res) {
    try {
      const data = await PurchaseTeamService.getApprovedVendors(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // ── SUPPLIER QUOTATION CRUD ─────────────────────────────────────────────
  static async createSupplierQuotation(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const data = await PurchaseTeamService.createSupplierQuotation({
        ...req.body,
        created_by: ecno,
      });
      const prSno = req.body.pr_basic_sno;
      if (prSno) await invalidateCache(req.redisClient, `pt:quotations:${prSno}`);
      await invalidateCache(req.redisClient, "pt:approved_prs");
      res.json({ success: true, data, message: "Supplier quotation created" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getSupplierQuotations(req, res) {
    try {
      const { prBasicSno } = req.params;
      if (!prBasicSno) return res.status(400).json({ success: false, error: "pr_basic_sno required" });

      const data = await PurchaseTeamService.getSupplierQuotations(Number(prBasicSno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async selectQuotation(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { selectedQuotation } = req.body;
      const data = await PurchaseTeamService.selectQuotation(selectedQuotation, ecno);
      const prSno = selectedQuotation?.pr_basic_sno;
      if (prSno) await invalidateCache(req.redisClient, `pt:quotations:${prSno}`);
      await invalidateCache(req.redisClient, "pt:approved_prs");
      res.json({ success: true, data, message: "Quotation selected" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // ── CREATE PO FROM QUOTATION ────────────────────────────────────────────
  static async createPOFromQuotation(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const data = await PurchaseTeamService.createPOFromQuotation({
        ...req.body,
        created_by: ecno,
      });
      await invalidateCache(req.redisClient, "pt:approved_prs", "grn:pending_pos", "storepo:list");
      res.json({ success: true, data, message: "Purchase Order created" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // ── UPDATE ITEM QTY ─────────────────────────────────────────────────────
  static async updateItemQuantity(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const data = await PurchaseTeamService.updateItemQuantity({
        ...req.body,
        modified_by: ecno,
      });
      await invalidateCacheByPattern(req.redisClient, "pt:quotations:*");
      res.json({ success: true, data, message: "Item quantity updated" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // ── PO CONFIRMATION (Step 1) ─────────────────────────────────────────────
  static async savePOConfirmation(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const data = await PurchaseTeamService.savePOConfirmation({
        ...req.body,
        confirmed_by: ecno,
      });
      const prSno = req.body.pr_basic_sno;
      if (prSno) await invalidateCache(req.redisClient, `pt:po_confirm:${prSno}`);
      res.json({ success: true, data, message: "PO confirmation saved" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getPOConfirmation(req, res) {
    try {
      const { prBasicSno } = req.params;
      if (!prBasicSno) return res.status(400).json({ success: false, error: "pr_basic_sno required" });

      const data = await PurchaseTeamService.getPOConfirmation(Number(prBasicSno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // ── DRAFT OPERATIONS ────────────────────────────────────────────────────
  static async saveQuotationDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const result = await PurchaseTeamService.saveQuotationDraft(req.redisClient, ecno, req.body);
      res.json({ success: true, ...result, message: "Quotation draft saved" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getQuotationDrafts(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const drafts = await PurchaseTeamService.getQuotationDrafts(req.redisClient, ecno);
      res.json({ success: true, data: drafts, count: drafts.length });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async deleteQuotationDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { draftId } = req.params;
      const deleted = await PurchaseTeamService.deleteQuotationDraft(req.redisClient, ecno, draftId);
      if (!deleted) return res.status(404).json({ success: false, error: "Draft not found" });

      res.json({ success: true, message: "Draft deleted" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default PurchaseTeamController;
