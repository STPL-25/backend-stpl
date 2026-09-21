import ServiceAgreementRepository from "../repository/ServiceAgreement.repository.js";

class ServiceAgreementService {
  static repo = new ServiceAgreementRepository();

  static async createServiceAgreement(payload) {
    return this.repo.createServiceAgreement(payload);
  }

  static async updateServiceAgreement(payload) {
    return this.repo.updateServiceAgreement(payload);
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

  static async getApprovedSuppliersForService(service_sno) {
    return this.repo.getApprovedSuppliersForService(service_sno);
  }

  static async getServiceAgreementsForApproval(ecno) {
    return this.repo.getServiceAgreementsForApproval(ecno);
  }

  static async getAgreementsDueForNotification() {
    return this.repo.getAgreementsDueForNotification();
  }

  static async markAgreementNotificationSent(payload) {
    return this.repo.markAgreementNotificationSent(payload);
  }
}

export default ServiceAgreementService;
