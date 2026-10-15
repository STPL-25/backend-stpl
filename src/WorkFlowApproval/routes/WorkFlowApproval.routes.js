import express from "express";
import WorkFlowApprovalController from "../controllers/WorkFlowApproval.controller.js";
import { cacheMiddleware } from "../../Middleware/redisCache.js";

const WorkFlowApprovalrouter = express.Router();

// approval_workflow_master
WorkFlowApprovalrouter.post("/saveFullWorkflow",               WorkFlowApprovalController.saveFullWorkflow);
WorkFlowApprovalrouter.get("/getWorkflows",                     WorkFlowApprovalController.getWorkflows);//cacheMiddleware("wf:workflows", 600),
WorkFlowApprovalrouter.get("/getEntityTypes",                   WorkFlowApprovalController.getEntityTypes);
WorkFlowApprovalrouter.get("/getConditionFields",               WorkFlowApprovalController.getConditionFields);
WorkFlowApprovalrouter.get("/getApprovalRoutes",                WorkFlowApprovalController.getApprovalRoutes);
WorkFlowApprovalrouter.post("/saveApprovalRoute",               WorkFlowApprovalController.saveApprovalRoute);
WorkFlowApprovalrouter.post("/saveApprovalModule",              WorkFlowApprovalController.saveApprovalModule);
WorkFlowApprovalrouter.post("/saveApprovalVariant",             WorkFlowApprovalController.saveApprovalVariant);
WorkFlowApprovalrouter.post("/createApprovalVariantEntity",     WorkFlowApprovalController.createApprovalVariantEntity);
WorkFlowApprovalrouter.get("/getWorkflowByEntity/:entityType",  WorkFlowApprovalController.getWorkflowByEntity);
WorkFlowApprovalrouter.put("/updateWorkflow",                  WorkFlowApprovalController.updateWorkflow);
WorkFlowApprovalrouter.delete("/deleteWorkflow",               WorkFlowApprovalController.deleteWorkflow);

// workflow_types
WorkFlowApprovalrouter.post("/saveWorkflowType",               WorkFlowApprovalController.saveWorkflowType);
WorkFlowApprovalrouter.get("/getWorkflowTypes/:workflowId",   WorkFlowApprovalController.getWorkflowTypes);
WorkFlowApprovalrouter.put("/updateWorkflowType",              WorkFlowApprovalController.updateWorkflowType);
WorkFlowApprovalrouter.delete("/deleteWorkflowType",           WorkFlowApprovalController.deleteWorkflowType);

// workflow_stage
WorkFlowApprovalrouter.post("/saveWorkflowStage",              WorkFlowApprovalController.saveWorkflowStage);
WorkFlowApprovalrouter.get("/getWorkflowStages/:workflowTypesId", WorkFlowApprovalController.getWorkflowStages);
WorkFlowApprovalrouter.put("/updateWorkflowStage",             WorkFlowApprovalController.updateWorkflowStage);
WorkFlowApprovalrouter.delete("/deleteWorkflowStage",          WorkFlowApprovalController.deleteWorkflowStage);

export default WorkFlowApprovalrouter;
