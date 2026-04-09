import GRNService from "../services/GRN.service.js";

function getAuthUser(req) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  return user;
}

class GRNController {
  // ── DB Operations ─────────────────────────────────────────────────────────

  static async getPendingPOs(req, res) {
    try {
      const data = await GRNService.getPendingPOs(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getGRNsByPO(req, res) {
    try {
      const { po_basic_sno } = req.params;
      const data = await GRNService.getGRNsByPO(Number(po_basic_sno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async createGRN(req, res) {
    try {
      const user = getAuthUser(req);
      const data = await GRNService.createGRN({ ...req.body, created_by: user?.ecno });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getAllGRNs(req, res) {
    try {
      const data = await GRNService.getAllGRNs(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // ── Draft Operations ──────────────────────────────────────────────────────

  static async saveGRNDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      if (!req.body || Object.keys(req.body).length === 0)
        return res.status(400).json({ success: false, error: "Draft data is required" });

      const result = await GRNService.saveGRNDraft(req.redisClient, ecno, req.body);
      res.json({ success: true, ...result, message: "GRN draft saved" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getGRNDrafts(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const drafts = await GRNService.getGRNDrafts(req.redisClient, ecno);
      res.json({ success: true, data: drafts, count: drafts.length });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getGRNDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { draftId } = req.params;
      const draft = await GRNService.getGRNDraft(req.redisClient, ecno, draftId);
      if (!draft) return res.status(404).json({ success: false, error: "Draft not found" });

      res.json({ success: true, data: draft });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async updateGRNDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { draftId } = req.params;
      const result = await GRNService.updateGRNDraft(req.redisClient, ecno, draftId, req.body);
      if (!result) return res.status(404).json({ success: false, error: "Draft not found" });

      res.json({ success: true, ...result, message: "GRN draft updated" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async deleteGRNDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { draftId } = req.params;
      const deleted = await GRNService.deleteGRNDraft(req.redisClient, ecno, draftId);
      if (!deleted) return res.status(404).json({ success: false, error: "Draft not found" });

      res.json({ success: true, message: "GRN draft deleted" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async submitGRNDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { draftId } = req.params;
      const result = await GRNService.submitGRNDraftToDB(req.redisClient, ecno, draftId);
      if (!result) return res.status(404).json({ success: false, error: "Draft not found" });

      res.json({ success: true, data: result, message: "GRN submitted successfully" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default GRNController;
