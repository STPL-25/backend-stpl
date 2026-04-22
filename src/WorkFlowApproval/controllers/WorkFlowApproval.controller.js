import WorkFlowApprovalService from "../services/WorkFlowApproval.service.js";

class WorkFlowApprovalController {
  // POST /saveFullWorkflow — creates all 3 tables in one SP call
  static async saveFullWorkflow(req, res) {
    try {
      const result = await WorkFlowApprovalService.saveFullWorkflow(req.body);
      res.status(201).json({ success: true, message: "Workflow saved successfully", data: result });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // GET /getWorkflows
  static async getWorkflows(req, res) {
    try {
      const data = await WorkFlowApprovalService.getWorkflows();
      res.json({ success: true, data });
    } catch (error) {
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
      res.json({ success: true, message: "Workflow updated", data: result });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // GET /getWorkflowTypes/:workflowId
  static async getWorkflowTypes(req, res) {
    try {
      const data = await WorkFlowApprovalService.getWorkflowTypes(req.params.workflowId);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // POST /saveWorkflowType
  static async saveWorkflowType(req, res) {
    try {
      const result = await WorkFlowApprovalService.saveWorkflowType(req.body);
      res.status(201).json({ success: true, message: "Workflow type saved", data: result });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // PUT /updateWorkflowType
  static async updateWorkflowType(req, res) {
    try {
      const result = await WorkFlowApprovalService.updateWorkflowType(req.body);
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
      res.status(201).json({ success: true, message: "Workflow stage saved", data: result });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // PUT /updateWorkflowStage
  static async updateWorkflowStage(req, res) {
    try {
      const result = await WorkFlowApprovalService.updateWorkflowStage(req.body);
      res.json({ success: true, message: "Workflow stage updated", data: result });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default WorkFlowApprovalController;
