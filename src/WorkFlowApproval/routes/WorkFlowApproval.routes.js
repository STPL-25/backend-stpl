import express from "express";
import WorkFlowApprovalController from "../controllers/WorkFlowApproval.controller.js";

const WorkFlowApprovalrouter = express.Router();

WorkFlowApprovalrouter.post("/createWorkFlowApproval", WorkFlowApprovalController.createWorkFlowApproval);
WorkFlowApprovalrouter.get("/getWorkflows", WorkFlowApprovalController.getWorkflows);
WorkFlowApprovalrouter.get("/getWorkflowByEntity/:entityType", WorkFlowApprovalController.getWorkflowByEntity);

export default WorkFlowApprovalrouter;
