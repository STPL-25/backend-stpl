import express from "express";
import ServiceAgreementController from "../controllers/ServiceAgreement.controller.js";
import { upload } from "../../Utils/ImagesUpload/ImgUpload.js";

const ServiceAgreementRouter = express.Router();

ServiceAgreementRouter.post("/createServiceAgreement", upload.any(), ServiceAgreementController.createServiceAgreement);
ServiceAgreementRouter.post("/updateServiceAgreement", upload.any(), ServiceAgreementController.updateServiceAgreement);
ServiceAgreementRouter.post("/approveServiceAgreement", ServiceAgreementController.approveServiceAgreement);
ServiceAgreementRouter.get("/getServiceAgreements", ServiceAgreementController.getServiceAgreements);
ServiceAgreementRouter.get("/getActiveServiceAgreement", ServiceAgreementController.getActiveServiceAgreement);
ServiceAgreementRouter.get("/getApprovedSuppliersForService", ServiceAgreementController.getApprovedSuppliersForService);
ServiceAgreementRouter.get("/getServiceAgreementsForApproval", ServiceAgreementController.getServiceAgreementsForApproval);

export default ServiceAgreementRouter;
