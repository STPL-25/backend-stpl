import express from "express";
import SpecialAgreementController from "../controllers/SpecialAgreement.controller.js";
import { upload } from "../../Utils/ImagesUpload/ImgUpload.js";

const SpecialAgreementRouter = express.Router();

SpecialAgreementRouter.post("/createSpecialAgreement", upload.any(), SpecialAgreementController.create);
SpecialAgreementRouter.post("/updateSpecialAgreement", upload.any(), SpecialAgreementController.update);
SpecialAgreementRouter.post("/approveSpecialAgreement", SpecialAgreementController.approve);
SpecialAgreementRouter.get("/getSpecialAgreements", SpecialAgreementController.list);
SpecialAgreementRouter.get("/getSpecialAgreementsForApproval", SpecialAgreementController.listForApproval);
SpecialAgreementRouter.get("/getSpecialAgreementRate", SpecialAgreementController.getRate);

export default SpecialAgreementRouter;
