import express from "express";
import KycController from "../controllers/Kyc.controller.js";
import { ftpUploader, upload } from "../../Utils/ImagesUpload/ImgUpload.js";
import KYCControllers from "../controllers/Kyc.controller.js";
import { cacheMiddleware } from "../../Middleware/redisCache.js";

const Kycrouter = express.Router();

Kycrouter.post("/create_kyc_records", upload.any(), KycController.createKYCRecord);

Kycrouter.get('/get_all_kycs', cacheMiddleware("kyc:list", 120), KYCControllers.getAllKYCRecords)
// Kycrouter.get('/get_kyc_approvals', cacheMiddleware("kyc:list", 120), KYCControllers.getKycApproval)

Kycrouter.get('/get_pending_approvals', cacheMiddleware("kyc:pending", 60), KYCControllers.getPendingApprovals)
Kycrouter.post('/approve_kyc', KYCControllers.approveKyc)
export default Kycrouter;

