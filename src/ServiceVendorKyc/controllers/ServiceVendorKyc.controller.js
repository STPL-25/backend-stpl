import ServiceVendorKycService from "../services/ServiceVendorKyc.service.js";
import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";

const ROOM = "service_vendor_kyc:approval";
const EVENT = "service_vendor_kyc:approval:updated";
const DOC_SUBDIRECTORY = "NON_TRADE_DATAS/SERVICE_VENDOR_KYC";

// Validation outcomes from the SPs carry status 400 (see the repository);
// everything else is a 500.
function fail(res, error, context) {
  if (!error.status) console.error(`Error in ${context}:`, error);
  res.status(error.status || 500).json({ success: false, error: error.message });
}

const toId = (v) => {
  const n = Number(v);
  return Number.isInteger(n) && n > 0 ? n : null;
};

const REQUIRED_FIELDS = ["com_sno", "div_sno", "brn_sno", "dept_sno", "company_name", "contact_person", "mobile_number", "email", "business_type", "pan_no", "ac_holder_name", "ac_number", "ac_type", "ifsc", "bank_name", "bank_branch_name", "bank_address"];

class ServiceVendorKycController {
  static async createServiceVendorKyc(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const payload = { ...req.body };
      const missing = REQUIRED_FIELDS.filter((f) => !payload[f] || String(payload[f]).trim() === "");
      if (missing.length) {
        return res.status(400).json({ success: false, error: `Missing required field(s): ${missing.join(", ")}` });
      }

      const document = [];
      for (const file of req.files ?? []) {
        const fileUrl = await ftpUploader.uploadFileIfExists(file, DOC_SUBDIRECTORY);
        document.push({
          documentType: file.fieldname,
          url: fileUrl,
          filename: file.originalname,
          mimetype: file.mimetype,
          size: file.size,
        });
      }

      payload.document = JSON.stringify(document);
      payload.is_gst_avail = payload.is_gst_avail === true || payload.is_gst_avail === "true" ? "Y" : "N";
      payload.is_msme_avail = payload.is_msme_avail === true || payload.is_msme_avail === "true" ? "Y" : "N";
      // created_by is always the authenticated session's ecno, never client-supplied
      payload.created_by = ecno;

      const data = await ServiceVendorKycService.createServiceVendorKyc(payload);

      req.io.to(ROOM).emit(EVENT, {
        service_vendor_kyc_sno: data?.[0]?.service_vendor_kyc_sno,
        action: "created",
        company_name: payload.company_name,
      });

      res.status(201).json({ success: true, data });
    } catch (error) {
      fail(res, error, "createServiceVendorKyc");
    }
  }

  static async approveServiceVendorKyc(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { service_vendor_kyc_sno, action, comments, approval_stages } = req.body;
      if (!toId(service_vendor_kyc_sno) || !action) {
        return res.status(400).json({ success: false, error: "service_vendor_kyc_sno and action are required" });
      }
      if (action === "reject" && !comments?.trim()) {
        return res.status(400).json({ success: false, error: "comments are required when rejecting" });
      }

      // The stage list is read from the workflow client-side (round-tripped from
      // getServiceVendorKycsForApproval's stage_order_json) and re-validated inside
      // the procedure — approved_by comes from the session, never the request body.
      const data = await ServiceVendorKycService.approveServiceVendorKyc({
        service_vendor_kyc_sno, action, comments: comments || "", approval_stages, approved_by: ecno,
      });

      req.io.to(ROOM).emit(EVENT, { service_vendor_kyc_sno, action, approved_by: ecno });
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error, "approveServiceVendorKyc");
    }
  }

  static async getServiceVendorKycs(req, res) {
    try {
      const { com_sno, div_sno, brn_sno, dept_sno, status } = req.query;
      const data = await ServiceVendorKycService.getServiceVendorKycs({ com_sno, div_sno, brn_sno, dept_sno, status });
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error, "getServiceVendorKycs");
    }
  }

  static async getApprovedServiceVendorKycs(req, res) {
    try {
      const data = await ServiceVendorKycService.getApprovedServiceVendorKycs();
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error, "getApprovedServiceVendorKycs");
    }
  }

  static async getServiceVendorKycsForApproval(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const data = await ServiceVendorKycService.getServiceVendorKycsForApproval(ecno);
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error, "getServiceVendorKycsForApproval");
    }
  }
}

export default ServiceVendorKycController;
