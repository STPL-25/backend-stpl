import express from "express";
import ServiceBillRequestController from "../controllers/ServiceBillRequest.controller.js";
import { upload } from "../../Utils/ImagesUpload/ImgUpload.js";

const ServiceBillRequestRouter = express.Router();

ServiceBillRequestRouter.post("/createServiceBillRequest", upload.any(), ServiceBillRequestController.createServiceBillRequest);
ServiceBillRequestRouter.post("/approveServiceBillRequest", ServiceBillRequestController.approveServiceBillRequest);
ServiceBillRequestRouter.post("/retryPOIssue", ServiceBillRequestController.retryPOIssue);
ServiceBillRequestRouter.get("/getServiceBillRequests", ServiceBillRequestController.getServiceBillRequests);
ServiceBillRequestRouter.get("/getActiveCeilingAgreementsForBilling", ServiceBillRequestController.getActiveCeilingAgreementsForBilling);
ServiceBillRequestRouter.get("/getServiceBillRequestsForApproval", ServiceBillRequestController.getServiceBillRequestsForApproval);

export default ServiceBillRequestRouter;
