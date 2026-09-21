import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";
import KYCServices from "../services/Kyc.service.js";
import { invalidateCache } from "../../Middleware/redisCache.js";
import { decryptFormPayload } from "../../Middleware/payloadCrypto.js";
import { validateKycCreate } from "../validation/kycValidation.js";
import CommonMasterServices from "../../Masters/Services/CommonMasterServices.js";

// Only these masters are exposed to anonymous /api/public_kyc callers —
// the underlying getRequiredMasterForOptions is otherwise unrestricted
// (any staff-authenticated masterField), so a public request must be
// filtered down explicitly rather than trusting the client's field list.
const PUBLIC_KYC_MASTER_FIELDS = ["SupplierCatagoryMaster", "BusinessDetailsMatster", "BankAccountTypeMaster"];

class KYCControllers {
  static async getAllKYCRecords(req, res) {
    try {
      const data = await KYCServices.getAllKycRecord();
      res.json({ success: true, data, count: data.length });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getPendingApprovals(req, res) {
    try {
      // req.user_ecno falls back to login_id for non-staff sessions, which have no ecno
      console.log("Authenticated user ecno:", req.user_ecno);
      const data = await KYCServices.getPendingApprovals(req.user_ecno);
      res.json({ success: true, data, count: data.length });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async approveKyc(req, res) {
    try {
      const { kyc_basic_info_sno, comments, approval_stages, action } = req.body;
      // ecno (the approver) is always the authenticated session's ecno, never
      // a client-supplied value — otherwise anyone could forge who approved
      // a supplier's KYC.
      const ecno = req.user_ecno;

      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      if (!kyc_basic_info_sno || !action) {
        return res.status(400).json({ success: false, error: "kyc_basic_info_sno and action are required" });
      }
      if (!["approve", "reject"].includes(action)) {
        return res.status(400).json({ success: false, error: "action must be 'approve' or 'reject'" });
      }
      if (action === "reject" && !comments?.trim()) {
        return res.status(400).json({ success: false, error: "comments are required when rejecting" });
      }

      const data = await KYCServices.approveKyc({
        kyc_basic_info_sno,
        ecno: ecno,
        comments: comments || "",
        action,
      });
      await invalidateCache(req.redisClient, "kyc:list", "kyc:pending");

      req.io.to("kyc:approval").emit("kyc:approval:updated", {
        kyc_basic_info_sno,
        action,
        approved_by: ecno,
      });

      res.json({ success: true, data, message: `KYC ${action === "approve" ? "approved" : "rejected"} successfully` });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async fetchVendorDatas(req, res) {
    try {
      const { status, is_active, search } = req.query;
      const filters = {};
      if (status)    filters.status    = status;
      if (is_active) filters.is_active = is_active;
      if (search)    filters.search    = search;

      const data = await KYCServices.fetchVendorDatas(filters);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getGSTNDetails(req, res) {
    try {
      const gst = String(req.body?.gst ?? "").trim();

      if (!gst) {
        return res
          .status(400)
          .json({ success: false, error: "gst is required" });
      }

      const data = await KYCServices.getGSTNDetails(gst);
      res.json({ success: true, data });
    } catch (error) {
      console.log(error)
      res
        .status(error.statusCode ?? 500)
        .json({ success: false, error: error.message });
    }
  }

  static async createKYCRecord(req, res) {
    try {
      // Decrypt the encrypted metadata field injected by the frontend FormData upload
      try {
        decryptFormPayload(req);
      } catch {
        return res.status(400).json({ success: false, error: "Invalid encrypted form payload." });
      }

      const kycData = { ...req.body };

      // Required-field enforcement runs before any file leaves for FTP —
      // checked BEFORE the is_gst_avail / is_msme_avail coercion below, so
      // an unanswered field is caught as missing rather than silently
      // normalised into "No" first.
      const { valid, errors } = validateKycCreate(kycData, req.files);
      if (!valid) {
        return res.status(422).json({
          success: false,
          error: `Missing required field${errors.length > 1 ? "s" : ""}: ${errors.join(", ")}`,
          fields: errors,
        });
      }

      kycData.document = [];

      for (const file of req.files) {
        const fileUrl = await ftpUploader.uploadFileIfExists(
          file,
          "NON_TRADE_DATAS/KYC_DATAS"
        );
        kycData.document.push({
          documentType: file.fieldname,
          url: fileUrl,
          filename: file.originalname,
          mimetype: file.mimetype,
          size: file.size,
        });
      }
      kycData.document = JSON.stringify(kycData.document);

      kycData.is_gst_avail  = kycData.is_gst_avail  === true || kycData.is_gst_avail  === "true";
      kycData.is_msme_avail = kycData.is_msme_avail === true || kycData.is_msme_avail === "true";

      const data = await KYCServices.createKYCRecord(kycData);

      // A 201 must mean a KYC record actually exists now. If the stored
      // procedure returned nothing, that is a failure — telling the
      // submitter "created successfully" here would be a lie.
      if (!data?.kyc_basic_info_sno) {
        return res.status(500).json({
          success: false,
          error: "KYC record was not created — the database returned no record.",
        });
      }

      await invalidateCache(req.redisClient, "kyc:list", "kyc:pending");

      req.io.to("kyc:approval").emit("kyc:submitted", {
        company_name: kycData.company_name,
        created_by:   kycData.created_by,
      });

      res.status(201).json({
        success: true,
        data,
        message: "KYC record created successfully",
      });
    } catch (error) {
      console.log(error)
      res.status(error.statusCode ?? 500).json({ success: false, error: error.message });
    }
  }

  // Public master-option lookup for the anonymous /supplier_kyc form — same
  // underlying service as /api/common_master/getRequiredMasterForOptions
  // (verifyJWT-protected), restricted to PUBLIC_KYC_MASTER_FIELDS so a
  // public visitor can't fish for unrelated master data through this route.
  static async getPublicMasterOptions(req, res) {
    try {
      const requested = Array.isArray(req.body?.masterFields) ? req.body.masterFields : [];
      const masterFields = requested.filter((f) => PUBLIC_KYC_MASTER_FIELDS.includes(f));

      if (masterFields.length === 0) {
        return res.status(400).json({ success: false, error: "No valid masterFields requested" });
      }

      const data = await CommonMasterServices.getRequiredMasterForOptions(masterFields);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getKYCOrgMappings(req, res) {
    try {
      const kycId = Number(req.params.kycId);
      if (!kycId) {
        return res.status(400).json({ success: false, error: "kycId is required" });
      }
      const data = await KYCServices.getKYCOrgMappings(kycId);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default KYCControllers;
