import express from "express";
import ServiceGrnController from "../controllers/ServiceGrn.controller.js";
import { attachHierarchyScope } from "../../Middleware/hierarchyScope.js";

const ServiceGrnRouter = express.Router();

ServiceGrnRouter.post("/createServiceGrn", ServiceGrnController.createServiceGrn);
ServiceGrnRouter.post("/approveServiceGrn", ServiceGrnController.approveServiceGrn);
ServiceGrnRouter.get("/getPendingServiceGrnPOs", attachHierarchyScope, ServiceGrnController.getPendingServiceGrnPOs);
ServiceGrnRouter.get("/getServiceGrns", attachHierarchyScope, ServiceGrnController.getServiceGrns);

export default ServiceGrnRouter;
