import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";
import KYCServices from "../services/Kyc.service.js";
import { invalidateCache } from "../../Middleware/redisCache.js";
import { decryptFormPayload } from "../../Middleware/payloadCrypto.js";

function getAuthUser(req) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  return user;
}

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
      const user = getAuthUser(req);
      const data = await KYCServices.getPendingApprovals(user?.ecno);
      res.json({ success: true, data, count: data.length });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async approveKyc(req, res) {
    try {
      const user = getAuthUser(req);
      const { kyc_basic_info_sno, ecno, comments, approval_stages, action } = req.body;

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
        approved_by: ecno,
        comments: comments || "",
        approval_stages,
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

  static async createKYCRecord(req, res) {
    try {
      // Decrypt the encrypted metadata field injected by the frontend FormData upload
      try {
        decryptFormPayload(req);
      } catch {
        return res.status(400).json({ success: false, error: "Invalid encrypted form payload." });
      }

      const kycData = { ...req.body };
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
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default KYCControllers;
