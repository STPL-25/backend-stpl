import WorkFlowApprovalRepository from "../repository/WorkFlowApproval.repository.js";

class WorkFlowApprovalService {
  static repo = new WorkFlowApprovalRepository();

  // approval_workflow_master
  static saveFullWorkflow(data)          { return this.repo.saveFullWorkflow(data); }
  static getWorkflows()                  { return this.repo.getWorkflows(); }
  static getWorkflowByEntity(entityType) { return this.repo.getWorkflowByEntity(entityType); }
  static updateWorkflow(data)            { return this.repo.updateWorkflow(data); }

  static deleteWorkflow(data) {
    if (!data?.workflow_id) throw new Error("workflow_id is required");
    return this.repo.deleteWorkflow(data);
  }

  // workflow_types
  static saveWorkflowType(data)          { return this.repo.saveWorkflowType(data); }
  static getWorkflowTypes(workflowId)    { return this.repo.getWorkflowTypes(workflowId); }
  static updateWorkflowType(data)        { return this.repo.updateWorkflowType(data); }

  static deleteWorkflowType(data) {
    if (!data?.workflow_types_id) throw new Error("workflow_types_id is required");
    return this.repo.deleteWorkflowType(data);
  }

  // workflow_stage
  static saveWorkflowStage(data)         { return this.repo.saveWorkflowStage(data); }
  static getWorkflowStages(typeId)       { return this.repo.getWorkflowStages(typeId); }
  static updateWorkflowStage(data)       { return this.repo.updateWorkflowStage(data); }

  static deleteWorkflowStage(data) {
    if (!data?.stage_id && !data?.workflow_types_id) {
      throw new Error("stage_id or workflow_types_id is required");
    }
    return this.repo.deleteWorkflowStage(data);
  }
}

export default WorkFlowApprovalService;
