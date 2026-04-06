import express from "express";
import WorkFlowApprovalController from "../controllers/WorkFlowApproval.controller.js";

const WorkFlowApprovalrouter = express.Router();

// approval_workflow_master
WorkFlowApprovalrouter.post("/saveFullWorkflow",               WorkFlowApprovalController.saveFullWorkflow);
WorkFlowApprovalrouter.get("/getWorkflows",                    WorkFlowApprovalController.getWorkflows);
WorkFlowApprovalrouter.get("/getWorkflowByEntity/:entityType", WorkFlowApprovalController.getWorkflowByEntity);
WorkFlowApprovalrouter.put("/updateWorkflow",                  WorkFlowApprovalController.updateWorkflow);

// workflow_types
WorkFlowApprovalrouter.post("/saveWorkflowType",               WorkFlowApprovalController.saveWorkflowType);
WorkFlowApprovalrouter.get("/getWorkflowTypes/:workflowId",    WorkFlowApprovalController.getWorkflowTypes);
WorkFlowApprovalrouter.put("/updateWorkflowType",              WorkFlowApprovalController.updateWorkflowType);

// workflow_stage
WorkFlowApprovalrouter.post("/saveWorkflowStage",              WorkFlowApprovalController.saveWorkflowStage);
WorkFlowApprovalrouter.get("/getWorkflowStages/:workflowTypesId", WorkFlowApprovalController.getWorkflowStages);
WorkFlowApprovalrouter.put("/updateWorkflowStage",             WorkFlowApprovalController.updateWorkflowStage);

export default WorkFlowApprovalrouter;
