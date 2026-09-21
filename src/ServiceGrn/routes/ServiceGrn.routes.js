import express from "express";
import ServiceGrnController from "../controllers/ServiceGrn.controller.js";
import { upload } from "../../Utils/ImagesUpload/ImgUpload.js";

const ServiceGrnRouter = express.Router();

ServiceGrnRouter.post("/createServiceGrn", upload.any(), ServiceGrnController.createServiceGrn);
ServiceGrnRouter.get("/getPendingServiceGrnPOs", ServiceGrnController.getPendingServiceGrnPOs);
ServiceGrnRouter.get("/getServiceGrns", ServiceGrnController.getServiceGrns);

export default ServiceGrnRouter;
