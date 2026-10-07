import express from "express";
import KycController from "../controllers/Kyc.controller.js";
import { upload } from "../../Utils/ImagesUpload/ImgUpload.js";
import VerifyController from "../../KycVerification/KycVerification.controller.js";

// Public, unauthenticated counterpart to Kyc.routes.js — reachable by a
// supplier who has no staff login at all. Mounted WITHOUT verifyJWT in
// index.js (unlike Kycrouter, which is wrapped router-wide), same pattern
// as NonStaffUser.routes.js's public /login route. Deliberately exposes
// only record creation + the small set of master options the create form
// needs, never listing/approval/vendor-data endpoints.
const PublicKycRouter = express.Router();

PublicKycRouter.post("/master_options", KycController.getPublicMasterOptions);
PublicKycRouter.get("/gst_state_codes", KycController.getPublicGstStateCodes);
// Each lookup is a paid Cashfree call on an unauthenticated route, so cap it per IP.
const hits = new Map();
const limitLookups = (req, res, next) => {
  const now = Date.now();
  const recent = (hits.get(req.ip) || []).filter((t) => now - t < 10 * 60_000);
  if (recent.length >= 60) {
    return res.status(429).json({ success: false, error: "Too many verification requests. Please try again in a few minutes." });
  }
  recent.push(now);
  hits.set(req.ip, recent);
  next();
};
PublicKycRouter.post("/Get_GSTN_Details", limitLookups, VerifyController.verifyGstin);
PublicKycRouter.post("/verify_pan", limitLookups, VerifyController.verifyPan);
PublicKycRouter.post("/verify_msme", limitLookups, VerifyController.verifyUdyam);
PublicKycRouter.post("/verify_bank_account", limitLookups, VerifyController.verifyBank);
PublicKycRouter.post("/verify_ifsc", limitLookups, VerifyController.verifyIfsc);
PublicKycRouter.post("/check_duplicate", limitLookups, VerifyController.checkDuplicate);
PublicKycRouter.post("/create_kyc_records", upload.any(), KycController.createKYCRecord);

export default PublicKycRouter;
