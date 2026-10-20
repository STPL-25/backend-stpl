import SpecialAgreementService from "../services/SpecialAgreement.service.js";
import { notifyApproversNow } from "../../ServiceAgreement/jobs/AgreementPoJob.js";
import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";

const DOC_SUBDIRECTORY = "NON_TRADE_DATAS/SPECIAL_AGREEMENTS";
const ROOM = "special_agreement:approval";
const EVENT = "special_agreement:approval:updated";

const notifyChange = (req, payload) => req.io?.to(ROOM).emit(EVENT, payload);

// The SPs raise validation problems as THROW 583xx - those are the user's to fix (400), anything else is a 500.
function sendError(res, error) {
  const message = String(error?.message ?? "").replace(/^Database error:\s*/, "");
  const isValidation = /^(Add at least|Every line|The same product|One or more products|A Fixed agreement|Maximum quantity|.* is already under |The supplier must|No Special Agreement workflow|The Special Agreement workflow|This agreement is |You are not an approver|Forwarding is not|There is no later|Sending back is not|Choose an earlier|A reason is required|A valid period|agreement_type must|Special agreement not found|special_agreement_sno|com_sno)/.test(message);
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
