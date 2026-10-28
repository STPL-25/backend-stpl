import ServiceGrnRepository from "../repository/ServiceGrn.repository.js";

class ServiceGrnService {
  static repo = new ServiceGrnRepository();

  static async createServiceGrn(payload) {
    return this.repo.createServiceGrn(payload);
  }

  static async approveServiceGrn(payload) {
    return this.repo.approveServiceGrn(payload);
  }

  // hierarchy = the caller's allowed org rows ([] = nothing); ecno only decides which GRNs are "mine to act on"
  static async getPendingServiceGrnPOs({ hierarchy }) {
    return this.repo.getPendingServiceGrnPOs({ hierarchy });
  }

  static async getServiceGrns({ hierarchy, ecno }) {
    return this.repo.getServiceGrns({ hierarchy, ecno });
  }
}

export default ServiceGrnService;
