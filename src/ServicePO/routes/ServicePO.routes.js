import express from "express";
import ServicePOController from "../controllers/ServicePO.controller.js";

const ServicePOrouter = express.Router();

ServicePOrouter.post("/createServicePO", ServicePOController.createServicePO);
ServicePOrouter.post("/createCallOffPO", ServicePOController.createCallOffPO);
ServicePOrouter.post("/approveServicePO", ServicePOController.approveServicePO);
ServicePOrouter.get("/getServicePORecords", ServicePOController.getServicePORecords);
ServicePOrouter.get("/getAllServicePOs", ServicePOController.getAllServicePOs);
ServicePOrouter.get("/getEligiblePrLinesForServicePO", ServicePOController.getEligiblePrLines);

export default ServicePOrouter;
