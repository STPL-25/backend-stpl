import express from "express";
import KycController from "../controllers/Kyc.controller.js";
import { ftpUploader, upload } from "../../Utils/ImagesUpload/ImgUpload.js";
import KYCControllers from "../controllers/Kyc.controller.js";

const Kycrouter = express.Router();

Kycrouter.post(  "/create_kyc_records", 
//     upload.fields([
//   { name: "gst_file", maxCount: 1 },
//   { name: "pan_file", maxCount: 1 },
//   { name: "msme_file", maxCount: 1 },
//   { name: "cancel_cheque_file", maxCount: 1 },
//   { name: "auth_contact_file", maxCount: 1 },
//   { name: "auth_person_file", maxCount: 1 },
//   { name: "auth_accounts_file", maxCount: 1 },
// ]),
upload.any(),

  KycController.createKYCRecord
);

Kycrouter.get('/get_all_kycs',KYCControllers.getAllKYCRecords)

export default Kycrouter;

