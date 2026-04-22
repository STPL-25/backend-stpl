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
      const ecno = req.query.ecno;
      const data = await PRService.getPrRecords(ecno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async approvePr(req, res) {
    try {
      const user = getAuthUser(req);

      const { pr_no, ecno, comments, approval_stages, action } = req.body;

      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      if (!pr_no || !action) {
        return res.status(400).json({ success: false, error: "pr_no and action are required" });
      }
      if (!["approve", "reject"].includes(action)) {
        return res.status(400).json({ success: false, error: "action must be 'approve' or 'reject'" });
      }
      if (action === "reject" && !comments?.trim()) {
        return res.status(400).json({ success: false, error: "comments are required when rejecting" });
      }

      const data = await PRService.approvePr({ pr_no,approved_by: ecno, comments: comments || "",approval_stages,action  });

      // req.io.emit("pr:approval:updated", { pr_no, action, approved_by: ecno });

      res.json({ success: true, data, message:  `successfully`});
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

      res.json({ success: true, data: result, message: "Requisition submitted successfully" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // ── DEPT-SCOPED SHARED DRAFT CONTROLLERS ─────────────────────────────────

  static async saveDeptDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      if (!req.body || Object.keys(req.body).length === 0)
        return res.status(400).json({ success: false, error: "Draft data is required" });

      const userName = user?.emp_name || user?.name || ecno;
      const result = await PRService.saveDeptDraft(req.redisClient, ecno, userName, req.body);

      const draft = await PRService.getDeptDraft(req.redisClient, result.scopeKey, result.draftId);
      req.io.to(`pr:scope:${result.scopeKey}`).emit("pr:draft:new", draft);

      res.json({ success: true, ...result, message: "Shared draft saved" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getDeptDrafts(req, res) {
    try {
      const user = getAuthUser(req);
      if (!user?.ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { com_sno, div_sno, brn_sno } = req.query;
      if (!com_sno || !div_sno || !brn_sno)
        return res.status(400).json({ success: false, error: "com_sno, div_sno, brn_sno are required" });

      const scopeKey = `${com_sno}:${div_sno}:${brn_sno}`;
      const drafts = await PRService.getDeptDrafts(req.redisClient, scopeKey);
      res.json({ success: true, data: drafts, count: drafts.length, scopeKey });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async updateDeptDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { draftId } = req.params;
      const { scopeKey } = req.body;
      if (!scopeKey) return res.status(400).json({ success: false, error: "scopeKey is required" });

      const userName = user?.emp_name || user?.name || ecno;
      const updated = await PRService.updateDeptDraft(req.redisClient, ecno, userName, scopeKey, draftId, req.body);
      if (!updated) return res.status(404).json({ success: false, error: "Draft not found" });

      req.io.to(`pr:scope:${scopeKey}`).emit("pr:draft:updated", updated);
      res.json({ success: true, draftId, updatedAt: updated.updatedAt, message: "Draft updated" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async deleteDeptDraft(req, res) {
    try {
      const user = getAuthUser(req);
      if (!user?.ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { draftId } = req.params;
      const { scopeKey } = req.query;
      if (!scopeKey) return res.status(400).json({ success: false, error: "scopeKey is required" });

      const deleted = await PRService.deleteDeptDraft(req.redisClient, scopeKey, draftId);
      if (!deleted) return res.status(404).json({ success: false, error: "Draft not found" });

      req.io.to(`pr:scope:${scopeKey}`).emit("pr:draft:deleted", { draftId, scopeKey });
      res.json({ success: true, message: "Shared draft deleted" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async submitDeptDraft(req, res) {
    try {
      const user = getAuthUser(req);
      if (!user?.ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { draftId } = req.params;
      const { scopeKey } = req.body;
      if (!scopeKey) return res.status(400).json({ success: false, error: "scopeKey is required" });

      const result = await PRService.submitDeptDraftToDB(req.redisClient, scopeKey, draftId);
      if (!result) return res.status(404).json({ success: false, error: "Draft not found" });

      req.io.to(`pr:scope:${scopeKey}`).emit("pr:draft:submitted", { draftId, scopeKey });
      res.json({ success: true, data: result, message: "Draft submitted successfully" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async submitAllDeptDrafts(req, res) {
    try {
      const user = getAuthUser(req);
      if (!user?.ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { scopeKey } = req.body;
      if (!scopeKey) return res.status(400).json({ success: false, error: "scopeKey is required" });

      const results = await PRService.submitAllDeptDraftsToDB(req.redisClient, scopeKey);
      req.io.to(`pr:scope:${scopeKey}`).emit("pr:draft:all_submitted", { scopeKey, results });
      res.json({ success: true, data: results, message: `Submitted ${results.length} drafts` });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default PRController;
