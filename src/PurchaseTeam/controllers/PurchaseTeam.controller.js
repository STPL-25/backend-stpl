import PurchaseTeamService from "../services/PurchaseTeam.service.js";
import { invalidateCache, invalidateCacheByPattern } from "../../Middleware/redisCache.js";
import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";
import { decryptFormPayload } from "../../Middleware/payloadCrypto.js";

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
      // Multipart upload (quotation document attached): decrypt the `_ep`
      // metadata field that multer parsed, merging it back into req.body.
      const isMultipart = req.is("multipart/form-data");
      if (isMultipart) {
        try {
          decryptFormPayload(req);
        } catch {
          return res.status(400).json({ success: false, error: "Invalid encrypted form payload." });
        }
      }

      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      // Upload the quotation document (image/PDF) to FTP if present.
      let quotationFileUrl = req.body.sq_quotation_file || "";
      if (Array.isArray(req.files) && req.files.length) {
        const quotationFile =
          req.files.find((f) => f.fieldname === "quotation_file") || req.files[0];
        if (quotationFile) {
          quotationFileUrl = await ftpUploader.uploadFileIfExists(
            quotationFile,
            "NON_TRADE_DATAS/QUOTATION_DATAS"
          );
        }
      }

      const data = await PurchaseTeamService.createSupplierQuotation({
        ...req.body,
        sq_quotation_file: quotationFileUrl,
        created_by: ecno,
      });
      const prSno = req.body.pr_basic_sno;
      if (prSno) await invalidateCache(req.redisClient, `pt:quotations:${prSno}`);
      await invalidateCache(req.redisClient, "pt:approved_prs");
      res.json({ success: true, data, message: "Supplier quotation created" });
    } catch (error) {
      console.log(error);
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getSupplierQuotations(req, res) {
    try {
      let { prBasicSno ,pr_no} = req.params;
      pr_no=atob(pr_no);
      console.log(pr_no)
      if (!prBasicSno) return res.status(400).json({ success: false, error: "pr_basic_sno required" });

      const data = await PurchaseTeamService.getSupplierQuotations(Number(prBasicSno),pr_no);
      res.json({ success: true, data });
    } catch (error) {
      console.log(error);
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async selectQuotation(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      // if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { selectedQuotation } = req.body;
      const data = await PurchaseTeamService.selectQuotation(selectedQuotation, ecno);
      // const prSno = selectedQuotation?.pr_basic_sno;
      // if (prSno) await invalidateCache(req.redisClient, `pt:quotations:${prSno}`);
      // await invalidateCache(req.redisClient, "pt:approved_prs");

      // Real-time: a quotation selection can change a PR's state, so refresh the
      // approved-PR list on every Purchase Team screen live (across clients) —
      // same mechanism as saveSplitGroup.
      const approvedPRs = await PurchaseTeamService.getApprovedPRs();
      req.io?.to("purchase-team").emit("pt:split:updated", { data: approvedPRs });

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
      // if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

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

  // ── SPLIT GROUPS ────────────────────────────────────────────────────────
  static async saveSplitGroup(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      const data = await PurchaseTeamService.saveSplitGroup({ ...req.body, created_by: ecno });
      const prSno = req.body.pr_basic_sno;
      // if (prSno) await invalidateCache(req.redisClient, `pt:split_groups:${prSno}`);

      // Real-time: notify everyone on the Purchase Team screen so their PR
      // sidebar reflects the new split group live (across clients).
      const approvedPRs = await PurchaseTeamService.getApprovedPRs();
      req.io?.to("purchase-team").emit("pt:split:updated", {
        data: approvedPRs,
        // pr_basic_sno: prSno,
        // group_no: req.body.group_no,
        // item_count: Array.isArray(req.body.items) ? req.body.items.length : 0,
        // updated_by: ecno,
        // updated_by_name: user?.ename ?? user?.emp_name ?? user?.username ?? "",
      });

      res.json({ success: true, data, message: "Split group saved" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getSplitGroups(req, res) {
    try {
      const { prBasicSno } = req.params;
      if (!prBasicSno) return res.status(400).json({ success: false, error: "pr_basic_sno required" });
      const data = await PurchaseTeamService.getSplitGroups(Number(prBasicSno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async updateSplitGroupOrg(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      const { pr_basic_sno } = req.body;
      const data = await PurchaseTeamService.updateSplitGroupOrg({ ...req.body, modified_by: ecno });
      if (pr_basic_sno) await invalidateCache(req.redisClient, `pt:split_groups:${pr_basic_sno}`);
      res.json({ success: true, data, message: "Split group org updated" });
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
