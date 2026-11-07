import VerificationService from "../../KycVerification/KycVerification.service.js";
import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";
import KYCServices from "../services/Kyc.service.js";
import { invalidateCache } from "../../Middleware/redisCache.js";
import { decryptFormPayload } from "../../Middleware/payloadCrypto.js";
import { validateKycCreate } from "../validation/kycValidation.js";
import CommonMasterServices from "../../Masters/Services/CommonMasterServices.js";
import { createInAppNotification, notifySupplier } from "../../Utils/Notify/notifyClient.js";

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

  static async getSupplierStatusList(req, res) {
    try {
      const data = await KYCServices.getSupplierStatusList();
      res.json({ success: true, data, count: data.length });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getSupplierStatusTimeline(req, res) {
    try {
      const { source } = req.params;
      const recordId = Number.parseInt(req.params.id, 10);
      if (!["KYC", "SERVICE_KYC"].includes(source)) {
        return res.status(400).json({ success: false, error: "source must be KYC or SERVICE_KYC" });
      }
      if (!Number.isInteger(recordId)) {
        return res.status(400).json({ success: false, error: "id must be a number" });
      }

      const data = await KYCServices.getSupplierStatusTimeline(source, recordId);
      if (!data.header) return res.status(404).json({ success: false, error: "Supplier not found" });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getSupplierFullDetails(req, res) {
    try {
      const { source } = req.params;
      const recordId = Number.parseInt(req.params.id, 10);
      if (!["KYC", "SERVICE_KYC"].includes(source)) {
        return res.status(400).json({ success: false, error: "source must be KYC or SERVICE_KYC" });
      }
      if (!Number.isInteger(recordId)) {
        return res.status(400).json({ success: false, error: "id must be a number" });
      }

      const data = await KYCServices.getSupplierFullDetails(source, recordId);
      if (!data.basic) return res.status(404).json({ success: false, error: "Supplier not found" });
      res.json({ success: true, data });
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
      console.log(error);
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

  // ── Supplier KYC change requests (grn sql/93) ─────────────────────────────────────────────────────
  static async getKycChangeRequests(req, res) {
    try {
      // req.user_ecno falls back to login_id for non-staff sessions, which have no ecno
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const data = await KYCServices.getKycChangeApprovals(ecno);
      res.json({ success: true, data, count: data.waiting.length });
    } catch (error) {
      res.status(error.userFacing ? 400 : 500).json({ success: false, error: error.message });
    }
  }

  static async actKycChangeRequest(req, res) {
    try {
      // The approver is always the authenticated session's ecno, never a client-supplied value.
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const kyc_modified_sno = Number(req.body?.kyc_modified_sno);
      const action = req.body?.action;
      const note = String(req.body?.note ?? "").trim();
      if (!Number.isInteger(kyc_modified_sno) || kyc_modified_sno <= 0) {
        return res.status(400).json({ success: false, error: "kyc_modified_sno is required" });
      }
      if (!["approve", "reject"].includes(action)) {
        return res.status(400).json({ success: false, error: "action must be 'approve' or 'reject'" });
      }
      if (action === "reject" && !note) {
        return res.status(400).json({ success: false, error: "Tell the supplier why the change is rejected." });
      }

      const row = await KYCServices.actKycChange({ kyc_modified_sno, ecno, action, note: note || undefined });
      if (row.status === "A") await invalidateCache(req.redisClient, "kyc:list", "kyc:pending");
      req.io?.to("kyc:approval").emit("kyc:approval:updated", { kyc_modified_sno, action, approved_by: ecno });

      const message =
        row.status === "A" ? "Approved - the change is now live on the supplier's KYC"
        : row.status === "R" ? "Rejected - the supplier has been told"
        : `Approved - now waiting for the next approver (stage ${row.stage_no} of ${row.stage_total})`;
      res.json({ success: true, data: row, message });

      // Best-effort alerts - never affect the response above.
      const who = `${row.company_name}${row.supp_code ? ` (${row.supp_code})` : ""}`;
      if (row.status === "P" && row.next_approver_ecno) {
        createInAppNotification({
          ecno: String(row.next_approver_ecno).trim(),
          type: "info",
          title: "Supplier KYC change to approve",
          message: `${who}: request ${row.version_no} is waiting at stage ${row.stage_no} of ${row.stage_total}${row.next_stage_name ? ` (${row.next_stage_name})` : ""}. Open KYC Approval to review it.`,
          data: { kind: "supplier_kyc_change_pending", kyc_modified_sno, version_no: row.version_no, screen: "KYCApprovalScreen" },
        }).catch(() => {});
      } else if (row.status === "A") {
        notifySupplier({
          supplier_sno: row.kyc_basic_info_sno,
          type: "success",
          title: "Your KYC change was approved",
          message: `Your request ${row.version_no} to change your KYC details has been approved and is now live.`,
          data: { view: "kyc", kyc_modified_sno, status: "A" },
        }).catch(() => {});
      } else if (row.status === "R") {
        notifySupplier({
          supplier_sno: row.kyc_basic_info_sno,
          type: "warning",
          title: "Your KYC change was rejected",
          message: `Your request ${row.version_no} to change your KYC details was rejected: ${row.decision_note ?? note}. Your KYC is unchanged - you can make the change again.`,
          data: { view: "kyc", kyc_modified_sno, status: "R" },
        }).catch(() => {});
      }
    } catch (error) {
      res.status(error.userFacing ? 400 : 500).json({ success: false, error: error.message });
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

      // Same rule the form checks up front, enforced again for direct API calls.
      const dup = await VerificationService.checkDuplicate(kycData);
      if (dup.exists) {
        return res.status(409).json({ success: false, error: dup.message, field: dup.field });
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
      // No certificate uploaded by hand but the Udyam number was verified through
      // Cashfree: attach the copy already saved to FTP so it shows in the KYC.
      if (kycData.msme_no && !kycData.document.some((d) => d.documentType === "msme_file")) {
        const verifiedCert = await VerificationService.latestCertificateUrl(kycData.msme_no).catch(() => "");
        if (verifiedCert) {
          kycData.document.push({
            documentType: "msme_file",
            url: verifiedCert,
            filename: `MSME certificate ${kycData.msme_no}.pdf`,
            mimetype: "application/pdf",
            size: 0,
          });
        }
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

      // Attach the Cashfree PAN/GST/MSME/bank responses looked up for this KYC.
      await VerificationService.linkToKyc(data.kyc_basic_info_sno, kycData).catch((e) =>
        console.error("[kyc-verification] link failed:", e.message)
      );

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

  // GST state-code -> state name reference data, so the anonymous form can
  // resolve a GSTIN's state without the login-protected /api/common_master route.
  static async getPublicGstStateCodes(req, res) {
    try {
      const data = await CommonMasterServices.getAllCommonMasters("GSTStateCodeMaster");
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getVerificationData(req, res) {
    try {
      const kycId = Number(req.params.kycId);
      if (!kycId) return res.status(400).json({ success: false, error: "kycId is required" });
      const rows = await VerificationService.getByKyc(kycId);
      res.json({
        success: true,
        data: rows.map(({ response_json, ...r }) => ({ ...r, response: JSON.parse(response_json) })),
      });
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
