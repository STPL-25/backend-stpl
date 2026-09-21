import express from "express";
import ServicePoController from "../controllers/ServicePo.controller.js";

const ServicePoRouter = express.Router();

ServicePoRouter.post("/submitServicePoEntry", ServicePoController.submitServicePoEntry);
ServicePoRouter.post("/approveServicePoCycle", ServicePoController.approveServicePoCycle);
ServicePoRouter.get("/getServicePoCycles", ServicePoController.getServicePoCycles);
ServicePoRouter.get("/getServicePoCyclesForApproval", ServicePoController.getServicePoCyclesForApproval);

export default ServicePoRouter;
