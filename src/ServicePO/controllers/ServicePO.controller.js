import ServicePoService from "../services/ServicePo.service.js";
import { dispatchServicePo } from "../../ServiceAgreement/services/ServicePoDispatch.service.js";
import { notifyApproversNow } from "../../ServiceAgreement/jobs/AgreementPoJob.js";
import { invalidateCacheByPattern } from "../../Middleware/redisCache.js";
import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";

const INVOICE_SUBDIRECTORY = "NON_TRADE_DATAS/SERVICE_PO_INVOICES";

class ServicePoController {
  // Unfixed only — rate/discount/GST entry for a Pending Entry cycle.
  // sp_nt_SubmitServicePoEntry throws if the cycle isn't Pending Entry, or
  // if the entered amount exceeds the agreement's ceiling_amount.
  static async submitServicePoEntry(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { cycle_sno, rate_amount, discount_pct, gst_pct, remarks, invoice_no, invoice_date, invoice_amount } = req.body;
      if (!cycle_sno || !rate_amount) {
        return res.status(400).json({ success: false, error: "cycle_sno and rate_amount are required" });
      }
      // The supplier invoice is uploaded together with the rate. Checked up front so a missing
      // file is rejected before the entry is saved; the SP re-validates the fields.
      const invoiceFile = Array.isArray(req.files) ? req.files.find((f) => f.fieldname === "invoice_document") || req.files[0] : null;
      if (!invoiceFile) return res.status(400).json({ success: false, error: "The supplier invoice file is required" });
      if (!invoice_no || !invoice_date || !invoice_amount) {
        return res.status(400).json({ success: false, error: "invoice_no, invoice_date and invoice_amount are required" });
      }

      const data = await ServicePoService.submitServicePoEntry({
        cycle_sno, rate_amount, discount_pct, gst_pct, remarks,
        // submitted_by is always the authenticated session's ecno, never client-supplied
        submitted_by: ecno,
      });

      const invoice_doc_url = await ftpUploader.uploadFileIfExists(invoiceFile, INVOICE_SUBDIRECTORY);
      if (!invoice_doc_url) {
        return res.status(500).json({ success: false, error: "Rate was saved but the invoice upload failed — upload the invoice from the PO list" });
      }
      await ServicePoService.attachEntryInvoice({
        cycle_sno: Number(cycle_sno), invoice_no, invoice_date, invoice_amount: Number(invoice_amount),
        invoice_doc_url, remarks, uploaded_by: ecno,
      });

      await invalidateCacheByPattern(req.redisClient, "service_po:list:*");

      req.io.to("service_po:approval").emit("service_po:approval:updated", { cycle_sno, action: "entry_submitted" });
      notifyApproversNow(req.io);

      res.json({ success: true, data });
    } catch (error) {
      console.error("Error in submitServicePoEntry:", error);
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async approveServicePoCycle(req, res) {
    try {
      const { cycle_sno, comments, approval_stages, action, send_back_to } = req.body;
      const ecno = req.user_ecno;

      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      if (!cycle_sno || !action) {
        return res.status(400).json({ success: false, error: "cycle_sno and action are required" });
      }
      if ((action === "reject" || action === "send_back") && !comments?.trim()) {
        return res.status(400).json({ success: false, error: `comments are required when ${action === "reject" ? "rejecting" : "sending back"}` });
      }
      if (action === "send_back" && !send_back_to) {
        return res.status(400).json({ success: false, error: "send_back_to is required when sending back" });
      }

      const data = await ServicePoService.approveServicePoCycle({
        cycle_sno,
        // approved_by comes from the session, never the request body — a
        // client-supplied ecno would let anyone forge who approved a cycle
        approved_by: ecno,
        comments: comments || "",
        approval_stages,
        action,
        send_back_to,
      });

      // The SP reports validation/runtime failures as an ERROR row rather than throwing.
      if (data?.[0]?.result === "ERROR") {
        return res.status(400).json({ success: false, error: data[0].error_message || "Action failed" });
      }

      await invalidateCacheByPattern(req.redisClient, "service_po:list:*");

      req.io.to("service_po:approval").emit("service_po:approval:updated", { cycle_sno, action, approved_by: ecno });
      notifyApproversNow(req.io);

      res.json({ success: true, data });

      // Additive-only, fires after the response above is already sent — a
      // dispatch failure must never affect the approval result itself. Same
      // helper the ServiceAgreement flow already uses for the Supplier path.
      // A cycle split across several suppliers raises one PO per supplier
      // (po_basic_snos, comma-separated); each supplier gets their own PO.
      const result = data?.[0];
      const po_basic_snos = String(result?.po_basic_snos ?? result?.po_basic_sno ?? "")
        .split(",")
        .map((s) => Number(s))
        .filter((n) => Number.isInteger(n) && n > 0);
      for (const po_basic_sno of po_basic_snos) {
        dispatchServicePo(po_basic_sno).catch((err) =>
          console.error(`Service PO dispatch failed for PO ${po_basic_sno}:`, err.message)
        );
      }
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // Supplier invoice against an approved (PO raised) cycle's PO.
  static async uploadInvoice(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { po_basic_sno, invoice_no, invoice_date, invoice_amount, remarks } = req.body;
      if (!po_basic_sno || !invoice_no || !invoice_date || !invoice_amount) {
        return res.status(400).json({ success: false, error: "po_basic_sno, invoice_no, invoice_date and invoice_amount are required" });
      }
      const file = Array.isArray(req.files) ? req.files.find((f) => f.fieldname === "invoice_document") || req.files[0] : null;
      if (!file) return res.status(400).json({ success: false, error: "The invoice file is required" });

      const invoice_doc_url = await ftpUploader.uploadFileIfExists(file, INVOICE_SUBDIRECTORY);
      if (!invoice_doc_url) return res.status(500).json({ success: false, error: "File upload failed, please try again" });

      const data = await ServicePoService.uploadInvoice({
        po_basic_sno: Number(po_basic_sno), invoice_no, invoice_date, invoice_amount: Number(invoice_amount),
        invoice_doc_url, remarks, uploaded_by: ecno,
      });

      await invalidateCacheByPattern(req.redisClient, "service_po:list:*");
      req.io?.to("service_po:approval").emit("service_po:approval:updated", { po_basic_sno: Number(po_basic_sno), action: "invoice_uploaded", approved_by: ecno });

      res.json({ success: true, data });
    } catch (error) {
      console.error("Error in uploadInvoice:", error);
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getServicePoCycles(req, res) {
    try {
      const data = await ServicePoService.getServicePoCycles(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getServicePoCyclesForApproval(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const data = await ServicePoService.getServicePoCyclesForApproval(ecno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default ServicePoController;
