import WorkFlowApprovalService from "../services/WorkFlowApproval.service.js";

class WorkFlowApprovalController {
  static async createWorkFlowApproval(req, res) {
    try {
      const data = req.body;
      const result = await WorkFlowApprovalService.createWorkFlowApproval(data);
      res.status(201).json({ success: true, message: "Workflow created successfully", data: result });
    } catch (error) {
      res.status(500).json({ success: false, message: "Internal Server Error", error: error.message });
    }
  }

  static async getWorkflows(req, res) {
    try {
      const data = await WorkFlowApprovalService.getWorkflows();
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getWorkflowByEntity(req, res) {
    try {
      const { entityType } = req.params;
      const data = await WorkFlowApprovalService.getWorkflowByEntity(entityType);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default WorkFlowApprovalController;
