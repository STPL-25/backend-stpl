import WorkFlowApprovalService from "../services/WorkFlowApproval.service.js";
import { invalidateCache, invalidateCacheByPattern } from "../../Middleware/redisCache.js";

class WorkFlowApprovalController {
  // POST /saveFullWorkflow — creates all 3 tables in one SP call
  static async saveFullWorkflow(req, res) {
    try {
      const result = await WorkFlowApprovalService.saveFullWorkflow(req.body);
      console.log(result)
      await invalidateCache(req.redisClient, "wf:workflows");
      await invalidateCacheByPattern(req.redisClient, "wf:by_entity:*");
      res.status(201).json({ success: true, message: "Workflow saved successfully", data: result });
    } catch (error) {
      console.log(error)
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // GET /getWorkflows
  static async getWorkflows(req, res) {
    try {
      const data = await WorkFlowApprovalService.getWorkflows();
      console.log(data)
      res.json({ success: true, data });
    } catch (error) {
      console.log(error)
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // GET /getWorkflowByEntity/:entityType
  static async getWorkflowByEntity(req, res) {
    try {
      const data = await WorkFlowApprovalService.getWorkflowByEntity(req.params.entityType);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // PUT /updateWorkflow
  static async updateWorkflow(req, res) {
    try {
      const result = await WorkFlowApprovalService.updateWorkflow(req.body);
      await invalidateCache(req.redisClient, "wf:workflows");
      await invalidateCacheByPattern(req.redisClient, "wf:by_entity:*");
      res.json({ success: true, message: "Workflow updated", data: result });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // GET /getWorkflowTypes/:workflowId
  static async getWorkflowTypes(req, res) {
    try {
      let raw = req.params.workflowId;
      try {
        const parsed = JSON.parse(raw);
        if (parsed && parsed.workflow_id !== undefined) raw = parsed.workflow_id;
      } catch { /* not JSON, use as-is */ }

      const workflowId = parseInt(raw, 10);
      if (isNaN(workflowId)) return res.status(400).json({ success: false, error: "Invalid workflow_id" });

      const data = await WorkFlowApprovalService.getWorkflowTypes(workflowId);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // POST /saveWorkflowType
  static async saveWorkflowType(req, res) {
    try {
      const result = await WorkFlowApprovalService.saveWorkflowType(req.body);
      await invalidateCache(req.redisClient, "wf:workflows", `wf:types:${req.body.workflow_id}`);
      res.status(201).json({ success: true, message: "Workflow type saved", data: result });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // PUT /updateWorkflowType
  static async updateWorkflowType(req, res) {
    try {
      const result = await WorkFlowApprovalService.updateWorkflowType(req.body);
      await invalidateCache(req.redisClient, "wf:workflows", `wf:types:${req.body.workflow_id}`);
      res.json({ success: true, message: "Workflow type updated", data: result });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // GET /getWorkflowStages/:workflowTypesId
  static async getWorkflowStages(req, res) {
    try {
      const data = await WorkFlowApprovalService.getWorkflowStages(req.params.workflowTypesId);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // POST /saveWorkflowStage
  static async saveWorkflowStage(req, res) {
    try {
      const result = await WorkFlowApprovalService.saveWorkflowStage(req.body);
      await invalidateCache(req.redisClient, `wf:stages:${req.body.workflow_types_id}`);
      res.status(201).json({ success: true, message: "Workflow stage saved", data: result });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // PUT /updateWorkflowStage
  static async updateWorkflowStage(req, res) {
    try {
      const result = await WorkFlowApprovalService.updateWorkflowStage(req.body);
      await invalidateCache(req.redisClient, `wf:stages:${req.body.workflow_types_id}`);
      res.json({ success: true, message: "Workflow stage updated", data: result });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default WorkFlowApprovalController;
