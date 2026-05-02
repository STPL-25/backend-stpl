import express from "express";
import WorkFlowApprovalController from "../controllers/WorkFlowApproval.controller.js";
import { cacheMiddleware } from "../../Middleware/redisCache.js";

const WorkFlowApprovalrouter = express.Router();

// approval_workflow_master
WorkFlowApprovalrouter.post("/saveFullWorkflow",               WorkFlowApprovalController.saveFullWorkflow);
WorkFlowApprovalrouter.get("/getWorkflows",                    cacheMiddleware("wf:workflows", 600), WorkFlowApprovalController.getWorkflows);
WorkFlowApprovalrouter.get("/getWorkflowByEntity/:entityType", cacheMiddleware((req) => `wf:by_entity:${req.params.entityType}`, 600), WorkFlowApprovalController.getWorkflowByEntity);
WorkFlowApprovalrouter.put("/updateWorkflow",                  WorkFlowApprovalController.updateWorkflow);

// workflow_types
WorkFlowApprovalrouter.post("/saveWorkflowType",               WorkFlowApprovalController.saveWorkflowType);
WorkFlowApprovalrouter.get("/getWorkflowTypes/:workflowId",    cacheMiddleware((req) => `wf:types:${req.params.workflowId}`, 600), WorkFlowApprovalController.getWorkflowTypes);
WorkFlowApprovalrouter.put("/updateWorkflowType",              WorkFlowApprovalController.updateWorkflowType);

// workflow_stage
WorkFlowApprovalrouter.post("/saveWorkflowStage",              WorkFlowApprovalController.saveWorkflowStage);
WorkFlowApprovalrouter.get("/getWorkflowStages/:workflowTypesId", cacheMiddleware((req) => `wf:stages:${req.params.workflowTypesId}`, 600), WorkFlowApprovalController.getWorkflowStages);
WorkFlowApprovalrouter.put("/updateWorkflowStage",             WorkFlowApprovalController.updateWorkflowStage);

export default WorkFlowApprovalrouter;
