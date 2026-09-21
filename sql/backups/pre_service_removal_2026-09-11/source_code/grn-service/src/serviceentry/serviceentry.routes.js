import express from "express";
import ServiceEntryController from "./serviceentry.controller.js";

const ServiceEntryRouter = express.Router();

ServiceEntryRouter.get("/getPendingServicePOs", ServiceEntryController.getPendingServicePOs);
ServiceEntryRouter.get("/getServiceEntriesByPO/:po_basic_sno", ServiceEntryController.getServiceEntriesByPO);
ServiceEntryRouter.post("/createServiceEntry", ServiceEntryController.createServiceEntry);
ServiceEntryRouter.post("/approveServiceEntry", ServiceEntryController.approveServiceEntry);
ServiceEntryRouter.get("/getAllServiceEntries", ServiceEntryController.getAllServiceEntries);

export default ServiceEntryRouter;
