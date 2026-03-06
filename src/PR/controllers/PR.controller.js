import PRService from "../services/PR.service.js";

// Helper: extract authenticated user from JWT payload (array or object)
function getAuthUser(req) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  return user;
}

class PRController {
  static async createPrRecords(req, res) {
    try {
      const data = await PRService.createPrRecords(req.body);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getPrRecords(req, res) {
    try {
      const data = await PRService.getPrRecords();
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // ── DRAFT OPERATIONS ───────────────────────────────────────────────────

  static async saveDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      if (!req.body || Object.keys(req.body).length === 0) {
        return res.status(400).json({ success: false, error: "Draft data is required" });
      }

      const result = await PRService.saveDraft(req.redisClient, ecno, req.body);
      res.json({ success: true, ...result, message: "Draft saved successfully" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getDrafts(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const drafts = await PRService.getDrafts(req.redisClient, ecno);
      res.json({ success: true, data: drafts, count: drafts.length });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { draftId } = req.params;
      const draft = await PRService.getDraft(req.redisClient, ecno, draftId);
      if (!draft) return res.status(404).json({ success: false, error: "Draft not found" });

      res.json({ success: true, data: draft });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async updateDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { draftId } = req.params;
      const result = await PRService.updateDraft(req.redisClient, ecno, draftId, req.body);
      if (!result) return res.status(404).json({ success: false, error: "Draft not found" });

      res.json({ success: true, ...result, message: "Draft updated successfully" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async deleteDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { draftId } = req.params;
      const deleted = await PRService.deleteDraft(req.redisClient, ecno, draftId);
      if (!deleted) return res.status(404).json({ success: false, error: "Draft not found" });

      res.json({ success: true, message: "Draft deleted successfully" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async submitDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { draftId } = req.params;
      const result = await PRService.submitDraftToDB(req.redisClient, ecno, draftId);
      if (!result) return res.status(404).json({ success: false, error: "Draft not found" });

      // Broadcast PR creation event to company rooms if needed
      const draft = result;
      res.json({ success: true, data: result, message: "Requisition submitted successfully" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default PRController;
