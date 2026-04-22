import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";
import KYCServices from "../services/Kyc.service.js";

class KYCControllers {
  static async getAllKYCRecords(req, res) {
    try {
      const data = await KYCServices.getAllKycRecord();
      res.json({ success: true, data, count: data.length });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async createKYCRecord(req, res) {
    try {
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

      kycData.is_gst_avail = kycData.is_gst_avail === "true";
      kycData.is_msme_avail = kycData.is_msme_avail === "true";

      const data = await KYCServices.createKYCRecord(kycData);
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
