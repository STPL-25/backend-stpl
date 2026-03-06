import WorkFlowApprovalRepository from "../repository/WorkFlowApproval.repository.js";

class WorkFlowApprovalService {
  static commonMasterRepository = new WorkFlowApprovalRepository();

  static async createWorkFlowApproval(data) {
    return this.commonMasterRepository.createWorkFlowApproval(data);
  }

  static async getWorkflows() {
    return this.commonMasterRepository.getWorkflows();
  }

  static async getWorkflowByEntity(entityType) {
    return this.commonMasterRepository.getWorkflowByEntity(entityType);
  }
}

export default WorkFlowApprovalService;
