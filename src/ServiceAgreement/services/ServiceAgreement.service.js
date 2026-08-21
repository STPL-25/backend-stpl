import ServiceAgreementRepository from "../repository/ServiceAgreement.repository.js";

class ServiceAgreementService {
  static repo = new ServiceAgreementRepository();

  static async createServiceAgreement(payload) {
    return this.repo.createServiceAgreement(payload);
  }

  static async approveServiceAgreement(approvalData) {
    return this.repo.approveServiceAgreement(approvalData);
  }

  static async getServiceAgreements(filters) {
    return this.repo.getServiceAgreements(filters);
  }

  static async getActiveServiceAgreement(scope) {
    return this.repo.getActiveServiceAgreement(scope);
  }

  static async getServiceAgreementsForApproval(ecno) {
    return this.repo.getServiceAgreementsForApproval(ecno);
  }
}

export default ServiceAgreementService;
