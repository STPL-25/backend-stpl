import express from "express";
import ServiceVendorKycController from "../controllers/ServiceVendorKyc.controller.js";
import { upload } from "../../Utils/ImagesUpload/ImgUpload.js";

const ServiceVendorKycRouter = express.Router();

ServiceVendorKycRouter.post("/createServiceVendorKyc", upload.any(), ServiceVendorKycController.createServiceVendorKyc);
ServiceVendorKycRouter.post("/approveServiceVendorKyc", ServiceVendorKycController.approveServiceVendorKyc);
ServiceVendorKycRouter.get("/getServiceVendorKycs", ServiceVendorKycController.getServiceVendorKycs);
ServiceVendorKycRouter.get("/getApprovedServiceVendorKycs", ServiceVendorKycController.getApprovedServiceVendorKycs);
ServiceVendorKycRouter.get("/getServiceVendorKycsForApproval", ServiceVendorKycController.getServiceVendorKycsForApproval);

export default ServiceVendorKycRouter;
