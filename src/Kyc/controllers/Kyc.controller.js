import { ftpUploader } from "../../Utils/ImagesUpload/ImgUpload.js";
import KYCServices from "../services/Kyc.service.js";
// import KYCServices from "../services/Kyc.service.js";
class KYCControllers {
  // Get all KYC records with optional filters
  static async getAllKYCRecords(req, res) {
    try {
      
      const data = await KYCServices.getAllKycRecord();

      res.json({
        success: true,
        data: data,
        count: data.length
      });
    } catch (error) {
      
      res.status(500).json({
        success: false,
        error: error.message,
      });
    }
  }

  // Get KYC record by supplier/customer ID
//   static async getKYCRecordById(req, res) {
//     try {
//       const { id } = req.params;
//       const data = await KYCServices.getKYCRecordById(id);

//       if (!data || data.length === 0) {
//         return res.status(404).json({
//           success: false,
//           error: "KYC record not found",
//         });
//       }

//       res.json({
//         success: true,
//         data: data,
//       });
//     } catch (error) {
//       res.status(500).json({
//         success: false,
//         error: error.message,
//       });
//     }
//   }

  // Create new KYC record
static async createKYCRecord(req, res) {
  try {
    const kycData = { ...req.body };

    
    // if (!req.files || Object.keys(req.files).length === 0) {
    //   return res.status(400).json({
    //     success: false,
    //     message: "No files uploaded"
    //   });
    // }

    // CORRECT WAY 2: Using for...of for sequential uploads
//   kycData.document = {};

// for (const fieldName of Object.keys(req.files)) {
//   const file = req.files[fieldName][0];
  
//   // Upload file and get URL
//   const fileUrl = await ftpUploader.uploadFileIfExists(
//     file,
//     "NON_TRADE_DATAS/KYC_DATAS"
//   );
  
//   // Store URL, filename, and file type
//   kycData.document[fieldName] = {
//     url: fileUrl,
//     filename: file.originalname,  // Original filename from user's computer
//     mimetype: file.mimetype,      // MIME type (e.g., 'application/pdf', 'image/jpeg')
//     size: file.size               // Optional: file size in bytes
//   };
// }

kycData.document = [];

for (const file of req.files) {
  const fieldName = file.fieldname;

  // Upload file
  const fileUrl = await ftpUploader.uploadFileIfExists(
    file,
    "NON_TRADE_DATAS/KYC_DATAS"
  );

  // Push each file as a separate object in the array
  kycData.document.push({
    documentType: fieldName,
    url: fileUrl,
    filename: file.originalname,
    mimetype: file.mimetype,
    size: file.size
  });
}
kycData.document = JSON.stringify(kycData.document);



    // Convert booleans
    kycData.is_gst_avail = kycData.is_gst_avail === 'true';
    kycData.is_msme_avail = kycData.is_msme_avail === 'true';
    const data = await KYCServices.createKYCRecord(kycData);
    res.status(201).json({
      success: true,
      data: data,
      message: "KYC record created successfully",
    });

  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
}


  // Update KYC record
//   static async updateKYCRecord(req, res) {
//     try {
//       const { id } = req.params;
//       const updateData = {
//         ...req.body,
//         modifiedBy: req.user?.userId,
//         modifiedDate: new Date()
//       };

//       const data = await KYCServices.updateKYCRecord(id, updateData);

//       if (!data) {
//         return res.status(404).json({
//           success: false,
//           error: "KYC record not found",
//         });
//       }

//       res.json({
//         success: true,
//         data: data,
//         message: "KYC record updated successfully",
//       });
//     } catch (error) {
//       res.status(500).json({
//         success: false,
//         error: error.message,
//       });
//     }
//   }

  // Update KYC verification status
//   static async updateKYCStatus(req, res) {
//     try {
//       const { id } = req.params;
//       const { status, remarks, verifiedBy } = req.body;

//       // Validate status values
//       const validStatuses = ['PENDING', 'APPROVED', 'REJECTED', 'UNDER_REVIEW', 'EXPIRED'];
//       if (!validStatuses.includes(status)) {
//         return res.status(400).json({
//           success: false,
//           error: "Invalid status value",
//         });
//       }

//       const data = await KYCServices.updateKYCStatus(id, {
//         status,
//         remarks,
//         verifiedBy: verifiedBy || req.user?.userId,
//         verificationDate: new Date()
//       });

//       res.json({
//         success: true,
//         data: data,
//         message: `KYC status updated to ${status}`,
//       });
//     } catch (error) {
//       res.status(500).json({
//         success: false,
//         error: error.message,
//       });
//     }
//   }

//   // Upload KYC documents
//   static async uploadKYCDocuments(req, res) {
//     try {
//       const { id } = req.params;
//       const documents = req.files; // From multer middleware

//       if (!documents || documents.length === 0) {
//         return res.status(400).json({
//           success: false,
//           error: "No documents uploaded",
//         });
//       }

//       const data = await KYCServices.uploadDocuments(id, documents, req.user?.userId);

//       res.json({
//         success: true,
//         data: data,
//         message: "Documents uploaded successfully",
//       });
//     } catch (error) {
//       res.status(500).json({
//         success: false,
//         error: error.message,
//       });
//     }
//   }

//   // Get KYC documents by record ID
//   static async getKYCDocuments(req, res) {
//     try {
//       const { id } = req.params;
//       const data = await KYCServices.getKYCDocuments(id);

//       res.json({
//         success: true,
//         data: data,
//       });
//     } catch (error) {
//       res.status(500).json({
//         success: false,
//         error: error.message,
//       });
//     }
//   }

//   // Get KYC expiry alerts
//   static async getExpiryAlerts(req, res) {
//     try {
//       const { daysBeforeExpiry } = req.query;
//       const days = parseInt(daysBeforeExpiry) || 30;

//       const data = await KYCServices.getExpiryAlerts(days);

//       res.json({
//         success: true,
//         data: data,
//         count: data.length
//       });
//     } catch (error) {
//       res.status(500).json({
//         success: false,
//         error: error.message,
//       });
//     }
//   }

//   // Bulk KYC verification
//   static async bulkVerifyKYC(req, res) {
//     try {
//       const { kycIds, status, remarks } = req.body;

//       if (!Array.isArray(kycIds) || kycIds.length === 0) {
//         return res.status(400).json({
//           success: false,
//           error: "Invalid KYC IDs array",
//         });
//       }

//       const data = await KYCServices.bulkVerifyKYC({
//         kycIds,
//         status,
//         remarks,
//         verifiedBy: req.user?.userId
//       });

//       res.json({
//         success: true,
//         data: data,
//         message: `${kycIds.length} KYC records updated successfully`,
//       });
//     } catch (error) {
//       res.status(500).json({
//         success: false,
//         error: error.message,
//       });
//     }
//   }

//   // Delete/Archive KYC record
//   static async deleteKYCRecord(req, res) {
//     try {
//       const { id } = req.params;
//       const { hardDelete } = req.query; // Soft delete by default

//       const result = await KYCServices.deleteKYCRecord(id, hardDelete === 'true');

//       if (!result) {
//         return res.status(404).json({
//           success: false,
//           error: "KYC record not found",
//         });
//       }

//       res.json({
//         success: true,
//         message: hardDelete === 'true' ? "KYC record deleted permanently" : "KYC record archived successfully",
//       });
//     } catch (error) {
//       res.status(500).json({
//         success: false,
//         error: error.message,
//       });
//     }
//   }

//   // Get KYC statistics/dashboard data
//   static async getKYCStatistics(req, res) {
//     try {
//       const { companyId, divisionId, fromDate, toDate } = req.query;

//       const data = await KYCServices.getKYCStatistics({
//         companyId,
//         divisionId,
//         fromDate,
//         toDate
//       });

//       res.json({
//         success: true,
//         data: data,
//       });
//     } catch (error) {
//       res.status(500).json({
//         success: false,
//         error: error.message,
//       });
//     }
//   }
}

export default KYCControllers;
