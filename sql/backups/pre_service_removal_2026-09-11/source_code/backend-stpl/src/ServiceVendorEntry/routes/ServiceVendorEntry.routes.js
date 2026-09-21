import express from "express";
import ServiceVendorEntryController from "../controllers/ServiceVendorEntry.controller.js";
import { upload } from "../../Utils/ImagesUpload/ImgUpload.js";

const ServiceVendorEntryRouter = express.Router();

ServiceVendorEntryRouter.post("/createEntry", upload.any(), ServiceVendorEntryController.createEntry);
ServiceVendorEntryRouter.get("/getEntries", ServiceVendorEntryController.getEntries);
ServiceVendorEntryRouter.post("/cancelEntry", ServiceVendorEntryController.cancelEntry);
ServiceVendorEntryRouter.post("/approveEntry", ServiceVendorEntryController.approveEntry);
ServiceVendorEntryRouter.post("/consolidate", ServiceVendorEntryController.consolidate);

export default ServiceVendorEntryRouter;
