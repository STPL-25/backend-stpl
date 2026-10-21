import SpecialAgreementService from "../services/SpecialAgreement.service.js";
import { invalidateCache, invalidateCacheByPattern } from "../../Middleware/redisCache.js";
import { notifyApproversNow } from "../../ServiceAgreement/jobs/AgreementPoJob.js";
import PurchaseTeamService from "../../PurchaseTeam/services/PurchaseTeam.service.js";
import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";

const DOC_SUBDIRECTORY = "NON_TRADE_DATAS/SPECIAL_AGREEMENTS";
const ROOM = "special_agreement:approval";
const EVENT = "special_agreement:approval:updated";

const notifyChange = (req, payload) => req.io?.to(ROOM).emit(EVENT, payload);

// The SPs raise validation problems as THROW 583xx - those are the user's to fix (400), anything else is a 500.
function sendError(res, error) {
  const message = String(error?.message ?? "").replace(/^Database error:\s*/, "");
  const isValidation = /^(Add at least|Every line|The same product|One or more products|A Fixed agreement|Maximum quantity|.* is already under |The supplier must|No Special Agreement workflow|The Special Agreement workflow|This agreement is |You are not an approver|Forwarding is not|There is no later|Sending back is not|Choose an earlier|A reason is required|A valid period|agreement_type must|Special agreement not found|special_agreement_sno|com_sno|The requisition is not|No active PO approval|Nothing to allocate|Every allocation|Enter the GST|The same line|One or more lines|A quotation already|An agreement is not live|An allocation is above|Enter a rate|The allocated quantities)/.test(message);
  res.status(isValidation ? 400 : 500).json({ success: false, error: message || "Request failed" });
}

// Multipart posts send items as a JSON string; JSON posts send the array itself.
function readItems(body) {
  let items = body.items;
  if (typeof items === "string") {
    try { items = JSON.parse(items); } catch { return { error: "items must be valid JSON" }; }
  }
  if (!Array.isArray(items) || items.length === 0) return { error: "Add at least one product to the agreement." };
  return {
    items: items.map((i) => ({
      prod_sno: i.prod_sno,
      rate_amount: i.rate_amount === "" ? null : i.rate_amount,
      max_qty: i.max_qty === "" ? null : i.max_qty,
      remarks: i.remarks,
    })),
  };
}

async function uploadDoc(req) {
  if (!Array.isArray(req.files) || !req.files.length) return "";
  const doc = req.files.find((f) => f.fieldname === "agreement_document") || req.files[0];
  return (await ftpUploader.uploadFileIfExists(doc, DOC_SUBDIRECTORY)) || "";
}

function readCommon(body) {
  const { com_sno, div_sno, brn_sno, dept_sno, agreement_type, vendor_sno, period_start_date, period_end_date, remarks, terms_conditions } = body;
  return { com_sno, div_sno, brn_sno, dept_sno, agreement_type, vendor_sno, period_start_date, period_end_date, remarks, terms_conditions };
}

class SpecialAgreementController {
  static async create(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const { items, error } = readItems(req.body);
      if (error) return res.status(400).json({ success: false, error });

      const agreement_doc_url = await uploadDoc(req);
      const data = await SpecialAgreementService.create({
        ...readCommon(req.body), items, agreement_doc_url,
        // always the session's ecno, never client-supplied
        created_by: ecno,
      });
      notifyChange(req, { action: "created", approved_by: ecno });
      notifyApproversNow(req.io);
      res.json({ success: true, data });
    } catch (error) {
      console.error("Error in createSpecialAgreement:", error.message);
      sendError(res, error);
    }
  }

  // Resubmits a rejected / approved / expired agreement - it goes back through approval.
  static async update(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const { special_agreement_sno, agreement_doc_url: existingDoc } = req.body;
      if (!special_agreement_sno) return res.status(400).json({ success: false, error: "special_agreement_sno is required" });
      const { items, error } = readItems(req.body);
      if (error) return res.status(400).json({ success: false, error });

      // a new file replaces the old one; no file keeps the existing document
      const uploaded = await uploadDoc(req);
      const data = await SpecialAgreementService.update({
        ...readCommon(req.body), special_agreement_sno, items,
        agreement_doc_url: uploaded || existingDoc || "",
        modified_by: ecno,
      });
      notifyChange(req, { special_agreement_sno, action: "updated", approved_by: ecno });
      notifyApproversNow(req.io);
      res.json({ success: true, data });
    } catch (error) {
      console.error("Error in updateSpecialAgreement:", error.message);
      sendError(res, error);
    }
  }

  static async approve(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const { special_agreement_sno, comments, action, send_back_to } = req.body;
      if (!special_agreement_sno || !action) {
        return res.status(400).json({ success: false, error: "special_agreement_sno and action are required" });
      }
      const data = await SpecialAgreementService.approve({
        special_agreement_sno,
        // from the session - a client-supplied ecno would let anyone forge who approved
        approved_by: ecno,
        comments: comments || "",
        action,
        send_back_to,
      });
      notifyChange(req, { special_agreement_sno, action, approved_by: ecno });
      notifyApproversNow(req.io);
      res.json({ success: true, data });
    } catch (error) {
      console.error("Error in approveSpecialAgreement:", error.message);
      sendError(res, error);
    }
  }

  static async list(req, res) {
    try {
      res.json({ success: true, data: await SpecialAgreementService.list({}) });
    } catch (error) {
      sendError(res, error);
    }
  }

  static async listForApproval(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      res.json({ success: true, data: await SpecialAgreementService.listForApproval(ecno) });
    } catch (error) {
      sendError(res, error);
    }
  }

  // Purchase page: PR lines of one entry that a live agreement covers, with the agreement suppliers.
  static async prOptions(req, res) {
    try {
      const pr_basic_sno = Number(req.query.pr_basic_sno);
      if (!Number.isInteger(pr_basic_sno) || pr_basic_sno <= 0) return res.status(400).json({ success: false, error: "pr_basic_sno is required" });
      const group = req.query.group === undefined || req.query.group === "" || req.query.group === "null" ? null : Number(req.query.group);
      res.json({ success: true, data: await SpecialAgreementService.prOptions({ pr_basic_sno, group }) });
    } catch (error) {
      sendError(res, error);
    }
  }

  // Purchase page: allocate PR lines to agreement suppliers (qty split allowed) and raise one quotation per
  // supplier. The split is committed first (one transaction); the quotations are then created with the
  // existing quotation procedure so they enter normal PO approval. A failed quotation leaves its (valid)
  // PR group in place for Purchase to quote by hand, and is reported back.
  static async applyToPR(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const { pr_basic_sno, group, allocations } = req.body;
      if (!pr_basic_sno || !Array.isArray(allocations) || allocations.length === 0) {
        return res.status(400).json({ success: false, error: "pr_basic_sno and allocations are required" });
      }
      const groups = await SpecialAgreementService.applyToPR({
        pr_basic_sno, group: group ?? null, allocations, created_by: ecno,
      });

      const today = new Date().toISOString().slice(0, 10);
      const results = [];
      for (const g of groups) {
        try {
          const rows = await PurchaseTeamService.createSupplierQuotation({
            pr_basic_sno, pr_no: g.pr_no, vendor_sno: g.vendor_sno,
            quotation_ref_no: g.quotation_ref_no, quotation_date: today, valid_upto: String(g.valid_upto).slice(0, 10),
            currency_code: "INR", delivery_days: 0,
            remarks: `Raised from Special Agreement ${g.quotation_ref_no}`,
            // the agreement document is the supplier's quotation document
            sq_quotation_file: g.agreement_doc_url || "",
            com_sno: g.com_sno, div_sno: g.div_sno, brn_sno: g.brn_sno, dept_sno: g.dept_sno,
            items: g.items, created_by: ecno,
          });
          const ok = rows?.[0]?.success === 1 || rows?.[0]?.success === true;
          results.push({ pr_no: g.pr_no, vendor_sno: g.vendor_sno, ok, sq_basic_sno: rows?.[0]?.sq_basic_sno, error: ok ? undefined : rows?.[0]?.message });
        } catch (err) {
          results.push({ pr_no: g.pr_no, vendor_sno: g.vendor_sno, ok: false, error: err.message });
        }
      }

      await invalidateCacheByPattern(req.redisClient, "pt:quotations:*");
      await invalidateCache(req.redisClient, "pt:approved_prs");
      // the Purchase list is regrouped (PR/<n> entries) - push the fresh list like a split does
      try {
        const approvedPRs = await PurchaseTeamService.getApprovedPRs();
        req.io?.to("purchase-team").emit("pt:split:updated", { data: approvedPRs });
      } catch (err) {
        console.error("pt:split:updated refresh failed:", err.message);
      }
      notifyApproversNow(req.io);

      res.json({ success: true, data: results });
    } catch (error) {
      console.error("Error in applyToPR:", error.message);
      sendError(res, error);
    }
  }

  // Live approved rate/supplier for a product on a date (for PR / PO to use later).
  static async getRate(req, res) {
    try {
      const prod_sno = Number(req.query.prod_sno);
      if (!Number.isInteger(prod_sno) || prod_sno <= 0) return res.status(400).json({ success: false, error: "prod_sno is required" });
      res.json({ success: true, data: await SpecialAgreementService.getRate(prod_sno, req.query.on_date) });
    } catch (error) {
      sendError(res, error);
    }
  }
}

export default SpecialAgreementController;
