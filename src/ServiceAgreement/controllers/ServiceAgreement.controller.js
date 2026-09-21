import ServiceAgreementService from "../services/ServiceAgreement.service.js";
import { dispatchServicePo } from "../services/ServicePoDispatch.service.js";
import { invalidateCacheByPattern } from "../../Middleware/redisCache.js";
import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";

const AGREEMENT_DOC_SUBDIRECTORY = "NON_TRADE_DATAS/SERVICE_AGREEMENTS";

// The create/edit forms post multipart FormData, so the supplier split and the
// Statutory facility block arrive as JSON strings (or already-parsed values when
// the client posts JSON). Returns undefined for absent/blank, throws on garbage.
function parseJsonField(value, fieldName) {
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value !== "string") return value;
  try {
    return JSON.parse(value);
  } catch {
    throw new Error(`${fieldName} must be valid JSON`);
  }
}

// vendors: [{ vendor_sno, share_amount }]. The SP re-validates everything (approved
// vendors, no duplicates, shares must add up to rate x qty) — this only guards the
// shape so a malformed post gets a clean 400 instead of a confusing SQL error.
function readSuppliers(body) {
  const vendors = parseJsonField(body.vendors, "vendors");
  if (vendors === undefined) {
    // Legacy single-supplier clients: the SP falls back to vendor_sno at 100%.
    return body.vendor_sno ? { vendors: undefined } : { error: "At least one supplier is required" };
  }
  if (!Array.isArray(vendors) || vendors.length === 0) {
    return { error: "vendors must be a non-empty list of { vendor_sno, share_amount }" };
  }
  if (vendors.some((v) => !v?.vendor_sno || !(Number(v.share_amount) > 0))) {
    return { error: "Every supplier needs a vendor and a share amount greater than zero" };
  }
  return { vendors };
}

// A loan (Statutory agreement) is priced by its facility terms and billed through Bank
// Payment Vouchers, so it has no rate, quantity or PO cadence of its own. The agreement
// row still needs them (sp_nt_CreateServiceAgreement validates each), so they are derived
// here instead of being asked for: one lender carrying the whole sanctioned amount,
// "billed" monthly on the interest payment day. Fixed and Unfixed pass through untouched.
async function withLoanDefaults(body, statutory) {
  const service_sno = Number(body.service_sno);
  if (!statutory || !Number.isInteger(service_sno)) return null;
  if ((await ServiceAgreementService.getServiceTypeCode(service_sno)) !== "STATUTORY") return null;

  const sanctioned = Number(statutory.sanctioned_amount);
  if (!(sanctioned > 0)) return { error: "The sanctioned loan amount is required" };

  const lender = body.vendor_sno || parseJsonField(body.vendors, "vendors")?.[0]?.vendor_sno;
  if (!lender) return { error: "The lender (bank / NBFC) is required" };

  const recurrence_cadence_sno = await ServiceAgreementService.getMonthlyCadenceSno();
  if (!recurrence_cadence_sno) return { error: "No active Monthly recurrence cadence is configured" };

  return {
    qty: 1,
    rate_amount: sanctioned,
    recurrence_cadence_sno,
    po_generation_day: statutory.interest_payment_day,
    notify_days_before: 0,
    vendor_sno: lender,
    vendors: [{ vendor_sno: Number(lender), share_amount: sanctioned }],
  };
}

class ServiceAgreementController {
  static async createServiceAgreement(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      let {
        com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
        qty, rate_amount, rate_uom_sno, recurrence_cadence_sno,
        po_generation_day, notify_days_before,
        period_start_date, period_end_date, remarks, terms_conditions,
      } = req.body;

      if (!com_sno || !div_sno || !brn_sno || !dept_sno || !service_sno) {
        return res.status(400).json({ success: false, error: "com_sno, div_sno, brn_sno, dept_sno and service_sno are required" });
      }
      const statutory = parseJsonField(req.body.statutory, "statutory");
      const loan = await withLoanDefaults(req.body, statutory);
      if (loan?.error) return res.status(400).json({ success: false, error: loan.error });
      if (loan) ({ qty, rate_amount, recurrence_cadence_sno, po_generation_day, notify_days_before, vendor_sno } = loan);
      const { vendors, error: supplierError } = loan ? { vendors: loan.vendors } : readSuppliers(req.body);
      if (supplierError) return res.status(400).json({ success: false, error: supplierError });
      if (!qty || !rate_amount) {
        return res.status(400).json({ success: false, error: "qty and rate_amount are required (an approximate rate is fine for an Unfixed or Statutory agreement)" });
      }
      if (!recurrence_cadence_sno) {
        return res.status(400).json({ success: false, error: "recurrence_cadence_sno is required" });
      }
      if (!period_start_date || !period_end_date) {
        return res.status(400).json({ success: false, error: "period_start_date and period_end_date are required" });
      }

      // Upload the agreement/contract document to FTP. Required — an
      // agreement can't be submitted without one (sp_nt_CreateServiceAgreement
      // THROWs 58105 otherwise).
      let agreement_doc_url = "";
      if (Array.isArray(req.files) && req.files.length) {
        const doc = req.files.find((f) => f.fieldname === "agreement_document") || req.files[0];
        if (doc) {
          agreement_doc_url = await ftpUploader.uploadFileIfExists(doc, AGREEMENT_DOC_SUBDIRECTORY);
        }
      }
      if (!agreement_doc_url) {
        return res.status(400).json({ success: false, error: "Agreement document upload failed or was not provided" });
      }

      const data = await ServiceAgreementService.createServiceAgreement({
        com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno, vendors, statutory,
        qty, rate_amount, rate_uom_sno, recurrence_cadence_sno,
        po_generation_day, notify_days_before,
        period_start_date, period_end_date, remarks, terms_conditions,
        agreement_doc_url,
        // created_by is always the authenticated session's ecno, never client-supplied
        created_by: ecno,
      });

      res.json({ success: true, data });
    } catch (error) {
      console.error("Error in createServiceAgreement:", error);
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // Edits an existing Approved/Rejected agreement, or RENEWS an Expired one
  // (sp_nt_UpdateServiceAgreement treats status X as a renewal: new version,
  // same agreement_no). Either way it re-enters approval (status goes back to
  // 'P' and the first approver is re-resolved), it does not take effect
  // immediately, and every submit keeps a version snapshot for the History view.
  // The document is optional here (unlike create): if no new file is
  // attached, req.body.agreement_doc_url (the existing URL the list screen
  // already had from sp_nt_GetServiceAgreements) is carried forward as-is.
  static async updateServiceAgreement(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      let {
        agreement_sno,
        com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno,
        qty, rate_amount, rate_uom_sno, recurrence_cadence_sno,
        po_generation_day, notify_days_before,
        period_start_date, period_end_date, remarks, terms_conditions,
        agreement_doc_url: existingDocUrl,
      } = req.body;

      if (!agreement_sno) {
        return res.status(400).json({ success: false, error: "agreement_sno is required" });
      }
      if (!com_sno || !div_sno || !brn_sno || !dept_sno || !service_sno) {
        return res.status(400).json({ success: false, error: "com_sno, div_sno, brn_sno, dept_sno and service_sno are required" });
      }
      const statutory = parseJsonField(req.body.statutory, "statutory");
      const loan = await withLoanDefaults(req.body, statutory);
      if (loan?.error) return res.status(400).json({ success: false, error: loan.error });
      if (loan) ({ qty, rate_amount, recurrence_cadence_sno, po_generation_day, notify_days_before, vendor_sno } = loan);
      const { vendors, error: supplierError } = loan ? { vendors: loan.vendors } : readSuppliers(req.body);
      if (supplierError) return res.status(400).json({ success: false, error: supplierError });
      if (!qty || !rate_amount) {
        return res.status(400).json({ success: false, error: "qty and rate_amount are required" });
      }
      if (!period_start_date || !period_end_date) {
        return res.status(400).json({ success: false, error: "period_start_date and period_end_date are required" });
      }

      let agreement_doc_url = existingDocUrl || "";
      if (Array.isArray(req.files) && req.files.length) {
        const doc = req.files.find((f) => f.fieldname === "agreement_document") || req.files[0];
        if (doc) {
          agreement_doc_url = await ftpUploader.uploadFileIfExists(doc, AGREEMENT_DOC_SUBDIRECTORY);
        }
      }
      if (!agreement_doc_url) {
        return res.status(400).json({ success: false, error: "Agreement document is required (upload a new one, or keep the existing one)" });
      }

      const data = await ServiceAgreementService.updateServiceAgreement({
        agreement_sno,
        com_sno, div_sno, brn_sno, dept_sno, service_sno, vendor_sno, vendors, statutory,
        qty, rate_amount, rate_uom_sno, recurrence_cadence_sno,
        po_generation_day, notify_days_before,
        period_start_date, period_end_date, remarks, terms_conditions,
        agreement_doc_url,
        // edited_by is always the authenticated session's ecno, never client-supplied
        edited_by: ecno,
      });

      res.json({ success: true, data });
    } catch (error) {
      console.error("Error in updateServiceAgreement:", error);
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async approveServiceAgreement(req, res) {
    try {
      const { agreement_sno, comments, approval_stages, action } = req.body;
      const ecno = req.user_ecno;

      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      if (!agreement_sno || !action) {
        return res.status(400).json({ success: false, error: "agreement_sno and action are required" });
      }
      if (action === "reject" && !comments?.trim()) {
        return res.status(400).json({ success: false, error: "comments are required when rejecting" });
      }

      const data = await ServiceAgreementService.approveServiceAgreement({
        agreement_sno,
        // approved_by comes from the session, never the request body — a
        // client-supplied ecno would let anyone forge who approved an agreement
        approved_by: ecno,
        comments: comments || "",
        approval_stages,
        action,
      });

      await invalidateCacheByPattern(req.redisClient, "service_agreement:list:*");

      req.io.to("service_agreement:approval").emit("service_agreement:approval:updated", {
        agreement_sno,
        action,
        approved_by: ecno,
      });

      res.json({ success: true, data });

      // Additive-only, fires after the response above is already sent — a
      // dispatch failure must never affect the approval result itself.
      const auto_po_basic_sno = data?.[0]?.auto_po_basic_sno;
      if (auto_po_basic_sno) {
        dispatchServicePo(auto_po_basic_sno).catch((err) =>
          console.error(`Service PO dispatch failed for PO ${auto_po_basic_sno}:`, err.message)
        );
      }
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getServiceAgreements(req, res) {
    try {
      const data = await ServiceAgreementService.getServiceAgreements(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // Whole life of one agreement: every version (terms + approval trail) and
  // every recurring cycle with the PO(s) raised for it.
  static async getServiceAgreementHistory(req, res) {
    try {
      const agreement_sno = Number(req.query.agreement_sno);
      if (!Number.isInteger(agreement_sno) || agreement_sno <= 0) {
        return res.status(400).json({ success: false, error: "agreement_sno is required" });
      }
      const data = await ServiceAgreementService.getServiceAgreementHistory(agreement_sno);
      if (!data) return res.status(404).json({ success: false, error: "Service agreement not found" });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getServiceAgreementsForApproval(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const data = await ServiceAgreementService.getServiceAgreementsForApproval(ecno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default ServiceAgreementController;
