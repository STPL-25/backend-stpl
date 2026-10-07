import express from "express";
import ServicePoController from "../controllers/ServicePo.controller.js";
import { upload } from "../../Utils/ImagesUpload/ImgUpload.js";

const ServicePoRouter = express.Router();

ServicePoRouter.post("/submitServicePoEntry", upload.any(), ServicePoController.submitServicePoEntry);
ServicePoRouter.post("/uploadInvoice", upload.any(), ServicePoController.uploadInvoice);
ServicePoRouter.post("/approveServicePoCycle", ServicePoController.approveServicePoCycle);
ServicePoRouter.get("/getServicePoCycles", ServicePoController.getServicePoCycles);
ServicePoRouter.get("/getServicePoCyclesForApproval", ServicePoController.getServicePoCyclesForApproval);

export default ServicePoRouter;
