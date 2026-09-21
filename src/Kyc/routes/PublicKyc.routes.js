import express from "express";
import KycController from "../controllers/Kyc.controller.js";
import { upload } from "../../Utils/ImagesUpload/ImgUpload.js";

// Public, unauthenticated counterpart to Kyc.routes.js — reachable by a
// supplier who has no staff login at all. Mounted WITHOUT verifyJWT in
// index.js (unlike Kycrouter, which is wrapped router-wide), same pattern
// as NonStaffUser.routes.js's public /login route. Deliberately exposes
// only record creation + the small set of master options the create form
// needs, never listing/approval/vendor-data endpoints.
const PublicKycRouter = express.Router();

PublicKycRouter.post("/master_options", KycController.getPublicMasterOptions);
PublicKycRouter.post("/Get_GSTN_Details", KycController.getGSTNDetails);
PublicKycRouter.post("/create_kyc_records", upload.any(), KycController.createKYCRecord);

export default PublicKycRouter;
