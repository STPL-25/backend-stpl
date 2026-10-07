import express from "express";
import KycController from "../controllers/Kyc.controller.js";
import { ftpUploader, upload } from "../../Utils/ImagesUpload/ImgUpload.js";
import KYCControllers from "../controllers/Kyc.controller.js";
import { cacheMiddleware } from "../../Middleware/redisCache.js";
import VerifyController from "../../KycVerification/KycVerification.controller.js";

const Kycrouter = express.Router();

Kycrouter.post("/create_kyc_records", upload.any(), KycController.createKYCRecord);

Kycrouter.get('/get_all_kycs', cacheMiddleware("kyc:list", 120), KYCControllers.getAllKYCRecords)
Kycrouter.get('/get_kyc_org_mappings/:kycId', KYCControllers.getKYCOrgMappings)
// Supplier Status screen — deliberately NOT cached: an approval that just happened must show at once.
Kycrouter.get('/supplier_status', KYCControllers.getSupplierStatusList)
Kycrouter.get('/supplier_status/:source/:id', KYCControllers.getSupplierStatusTimeline)
Kycrouter.get('/supplier_details/:source/:id', KYCControllers.getSupplierFullDetails)
// Kycrouter.get('/get_kyc_approvals', cacheMiddleware("kyc:list", 120), KYCControllers.getKycApproval)

Kycrouter.get('/get_pending_approvals',  KYCControllers.getPendingApprovals)
Kycrouter.post('/approve_kyc', KYCControllers.approveKyc)

Kycrouter.get('/fetch_vendor_datas', cacheMiddleware("kyc:vendors", 120), KYCControllers.fetchVendorDatas)
// GST / PAN / Udyam / bank lookups go through Cashfree (replaces the old SOAP GST service).
Kycrouter.post('/Get_GSTN_Details', VerifyController.verifyGstin)
Kycrouter.post('/verify_pan', VerifyController.verifyPan)
Kycrouter.post('/verify_msme', VerifyController.verifyUdyam)
Kycrouter.post('/verify_bank_account', VerifyController.verifyBank)
Kycrouter.post('/verify_ifsc', VerifyController.verifyIfsc)
Kycrouter.post('/check_duplicate', VerifyController.checkDuplicate)
Kycrouter.get('/verification_data/:kycId', KYCControllers.getVerificationData)

export default Kycrouter;

