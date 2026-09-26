import PRService from "../services/PR.service.js";
import PurchaseTeamService from "../../PurchaseTeam/services/PurchaseTeam.service.js";
import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";
import { invalidateCacheByPattern } from "../../Middleware/redisCache.js";

// Helper: extract authenticated user from JWT payload (array or object)
function getAuthUser(req) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  return user;
}

class PRController {
  static async createPrRecords(req, res) {
    try {
      let payload;

      // Multipart/form-data from direct submission (files sent separately)
      if (typeof req.body.basicInfo === "string") {
        const basicInfo = JSON.parse(req.body.basicInfo);
        const items = JSON.parse(req.body.items || "[]");
        // Upload each item's file to FTP and replace with URL. Vendor-driven
        // requisitions instead carry one "attachment" file for the whole
        // requisition (see usp_InsertVendorDrivenPurchaseRequest).
        if (req.files && req.files.length > 0) {
          for (const file of req.files) {
            const itemMatch = file.fieldname.match(/^item_attachment_(\d+)$/);
            if (itemMatch) {
              const idx = parseInt(itemMatch[1], 10);
              if (items[idx]) {
                items[idx].item_attachment = await ftpUploader.uploadFileIfExists(
                  file,
                  "NON_TRADE_DATAS/PR_ITEMS"
                );
              }
            } else if (file.fieldname === "attachment") {
              basicInfo.attachment = await ftpUploader.uploadFileIfExists(
                file,
                "NON_TRADE_DATAS/PR_ITEMS"
              );
            }
          }
        }

        payload = { basicInfo, items };
      } else {
        payload = req.body;
      }

      // ecno comes from the session, never the request body.
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      payload.ecno = ecno;

      const isVendorDriven = payload?.basicInfo?.request_mode === "VENDOR_DRIVEN";
      if (isVendorDriven) {
        payload.basicInfo.created_by = ecno;
        if (!payload.basicInfo.vendor_sno || !Array.isArray(payload.items) || payload.items.length === 0 || !payload.basicInfo.attachment) {
          return res.status(400).json({
            success: false,
            error: "Vendor-driven requisitions require a supplier, at least one item, and a verification document.",
          });
        }
      }

      const data = isVendorDriven
        ? await PRService.createVendorDrivenPrRecords(payload)
        : await PRService.createPrRecords(payload);
      await invalidateCacheByPattern(req.redisClient, "pr:list:*");
      res.json({ success: true, data });
    } catch (error) {

      console.log(error)
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getPrRecords(req, res) {
    try {
      const ecno = req.user_ecno; // Use the authenticated user's ecno from JWT payload
      console.log("Authenticated user ecno:", ecno);
      const data = await PRService.getPrRecords(ecno, req.hierarchyJson);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async approvePr(req, res) {
    try {
      const { pr_no, comments, approval_stages, action } = req.body;
      // approved_by comes from the session, never the request body — a
      // client-supplied ecno would let anyone forge who approved a PR.
      const ecno = req.user_ecno;

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
      await invalidateCacheByPattern(req.redisClient, "pr:list:*");

      // Vendor-driven PRs auto-raise their child PO the instant final
      // approval is reached — the dedicated VendorDrivenPurchaseRequisition
      // workflow already gated the PR itself, so the PO issues directly
      // (sp_nt_CreateVendorDrivenPOFromPR), no separate PO-level approval.
      // A PO-issuance failure must not fail this response — the PR approval
      // already committed — so it's caught and surfaced as auto_po.result
      // ==='ERROR' instead, same tolerance sp_approve_service_agreement
      // uses for its own auto-issue step.
      const approvalRow = data?.[0];
      let auto_po;
      if (
        action === "approve" &&
        approvalRow?.result === "SUCCESS" &&
        approvalRow?.next_approver === "FINAL_STAGE" &&
        approvalRow?.request_mode === "VENDOR_DRIVEN"
      ) {
        try {
          const poResult = await PurchaseTeamService.createVendorDrivenPO({
            pr_basic_sno: approvalRow.pr_basic_sno,
            created_by: ecno,
          });
          auto_po = poResult?.[0];
          await invalidateCacheByPattern(req.redisClient, "pt:approved_prs*");
          await invalidateCacheByPattern(req.redisClient, "grn:pending_pos*");
        } catch (poError) {
          console.log("Auto child-PO creation failed after vendor-driven PR approval:", poError.message);
          auto_po = { result: "ERROR", error: poError.message };
        }
      }

      // req.io.emit("pr:approval:updated", { pr_no, action, approved_by: ecno });

      // Additive PR-tracking push for the requester's tracking page.
      if (req.io) {
        req.io.to(`pr:track:${pr_no}`).emit("pr:track:updated", {
          pr_no,
          stage: action === "approve" ? "PR Approval" : "PR Rejected",
          status: action,
          payload: { approved_by: ecno, comments },
        });
      }

      res.json({ success: true, data, auto_po, message:  `successfully`});
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

      await invalidateCacheByPattern(req.redisClient, "pr:list:*");
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

      await invalidateCacheByPattern(req.redisClient, "pr:list:*");
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
      await invalidateCacheByPattern(req.redisClient, "pr:list:*");
      req.io.to(`pr:scope:${scopeKey}`).emit("pr:draft:all_submitted", { scopeKey, results });
      res.json({ success: true, data: results, message: `Submitted ${results.length} drafts` });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default PRController;
