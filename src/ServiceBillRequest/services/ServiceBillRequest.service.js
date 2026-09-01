import ServiceBillRequestRepository from "../repository/ServiceBillRequest.repository.js";

class ServiceBillRequestService {
  static repo = new ServiceBillRequestRepository();

  static async createServiceBillRequest(payload) {
    return this.repo.createServiceBillRequest(payload);
  }

  static async approveServiceBillRequest(approvalData) {
    return this.repo.approveServiceBillRequest(approvalData);
  }

  static async getServiceBillRequests(filters) {
    return this.repo.getServiceBillRequests(filters);
  }

  static async getActiveCeilingAgreementsForBilling(scope) {
    return this.repo.getActiveCeilingAgreementsForBilling(scope);
  }

  static async retryPOIssue(payload) {
    return this.repo.retryPOIssue(payload);
  }

  static async getServiceBillRequestsForApproval(ecno) {
    return this.repo.getServiceBillRequestsForApproval(ecno);
  }
}

export default ServiceBillRequestService;
