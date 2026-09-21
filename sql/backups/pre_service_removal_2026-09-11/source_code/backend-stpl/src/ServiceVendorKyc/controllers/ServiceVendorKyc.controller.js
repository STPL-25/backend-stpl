import ServiceVendorKycService from "../services/ServiceVendorKyc.service.js";
import { invalidateCacheByPattern } from "../../Middleware/redisCache.js";
import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";

const DOC_SUBDIRECTORY = "NON_TRADE_DATAS/SERVICE_VENDOR_KYC";

class ServiceVendorKycController {
  static async createServiceVendorKyc(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const {
        com_sno, div_sno, brn_sno, dept_sno,
        company_name, contact_person, email, mobile_number, business_type,
        is_gst_avail, gst_no, is_msme_avail, msme_no, pan_no, supplier_cat_code, remarks,
        // GST-fetch-derived (optional — populated client-side only when an
        // auto-fetch via apiGetGSTNDetails succeeded before submission)
        legal_name, trade_name, gst_status, gst_blk_status, date_of_reg,
        // Bank details — required by sp_nt_CreateServiceVendorKyc v2
        ac_holder_name, ac_number, ac_type, ifsc, bank_name, bank_branch_name, bank_address,
        preferred_payment_mode,
      } = req.body;

      if (!com_sno || !div_sno || !brn_sno || !dept_sno) {
        return res.status(400).json({ success: false, error: "com_sno, div_sno, brn_sno and dept_sno are required" });
      }
      if (!company_name || !contact_person || !mobile_number || !email || !business_type || !pan_no) {
        return res.status(400).json({
          success: false,
          error: "company_name, contact_person, mobile_number, email, business_type and pan_no are required",
        });
      }

      // Multiple supporting documents (PAN card, GST certificate, etc.) —
      // same per-file upload loop Kyc.controller.js#createKYCRecord uses for
      // the existing goods/trade vendor KYC, since this is KYC-shaped too.
      const document = [];
      if (Array.isArray(req.files)) {
        for (const file of req.files) {
          const fileUrl = await ftpUploader.uploadFileIfExists(file, DOC_SUBDIRECTORY);
          document.push({
            documentType: file.fieldname,
            url: fileUrl,
            filename: file.originalname,
            mimetype: file.mimetype,
            size: file.size,
          });
        }
      }

      const data = await ServiceVendorKycService.createServiceVendorKyc({
        com_sno, div_sno, brn_sno, dept_sno,
        company_name, contact_person, email, mobile_number, business_type,
        is_gst_avail: is_gst_avail === true || is_gst_avail === "true" ? "Y" : "N",
        gst_no,
        is_msme_avail: is_msme_avail === true || is_msme_avail === "true" ? "Y" : "N",
        msme_no, pan_no, supplier_cat_code, remarks,
        document,
        legal_name, trade_name, gst_status, gst_blk_status, date_of_reg,
        ac_holder_name, ac_number, ac_type, ifsc, bank_name, bank_branch_name, bank_address,
        preferred_payment_mode,
        // created_by is always the authenticated session's ecno, never client-supplied
        created_by: ecno,
      });

      res.json({ success: true, data });
    } catch (error) {
      console.error("Error in createServiceVendorKyc:", error);
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async approveServiceVendorKyc(req, res) {
    try {
      const { service_vendor_kyc_sno, comments, approval_stages, action } = req.body;
      const ecno = req.user_ecno;

      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      if (!service_vendor_kyc_sno || !action) {
        return res.status(400).json({ success: false, error: "service_vendor_kyc_sno and action are required" });
      }
      if (action === "reject" && !comments?.trim()) {
        return res.status(400).json({ success: false, error: "comments are required when rejecting" });
      }

      const data = await ServiceVendorKycService.approveServiceVendorKyc({
        service_vendor_kyc_sno,
        // approved_by comes from the session, never the request body — a
        // client-supplied ecno would let anyone forge who approved a record
        approved_by: ecno,
        comments: comments || "",
        approval_stages,
        action,
      });

      await invalidateCacheByPattern(req.redisClient, "service_vendor_kyc:list:*");

      req.io.to("service_vendor_kyc:approval").emit("service_vendor_kyc:approval:updated", {
        service_vendor_kyc_sno,
        action,
        approved_by: ecno,
      });

      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getServiceVendorKycs(req, res) {
    try {
      const data = await ServiceVendorKycService.getServiceVendorKycs(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getApprovedServiceVendorKycs(req, res) {
    try {
      const data = await ServiceVendorKycService.getApprovedServiceVendorKycs();
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getServiceVendorKycsForApproval(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const data = await ServiceVendorKycService.getServiceVendorKycsForApproval(ecno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default ServiceVendorKycController;
