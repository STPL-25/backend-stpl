import express from "express";
import CommonMasterControllers from "../Controllers/CommonMasterControllers.js";

const commonBasicDetailsRouter = express.Router();

// IMPORTANT: Place specific routes BEFORE parameterized routes
commonBasicDetailsRouter.post("/",  CommonMasterControllers.getBasicDetailsByFields);
commonBasicDetailsRouter.post("/getEmployee",  CommonMasterControllers.getBasicDetailsEmployee);




export default commonBasicDetailsRouter;
