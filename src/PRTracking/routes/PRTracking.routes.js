import express from "express";
import PRTrackingController from "../controllers/PRTracking.controller.js";

const PRTrackingRouter = express.Router();

PRTrackingRouter.get("/getMyTracking", PRTrackingController.getMyTracking);
PRTrackingRouter.get("/canViewOrgTracking", PRTrackingController.canViewOrgTracking);
PRTrackingRouter.get("/getOrgTracking", PRTrackingController.getOrgTracking);
PRTrackingRouter.get("/getTimeline/:pr_no", PRTrackingController.getTimeline);

export default PRTrackingRouter;
