import ServiceGrnRepository from "../repository/ServiceGrn.repository.js";

class ServiceGrnService {
  static repo = new ServiceGrnRepository();

  static async createServiceGrn(payload) {
    return this.repo.createServiceGrn(payload);
  }

  static async getPendingServiceGrnPOs(filters) {
    return this.repo.getPendingServiceGrnPOs(filters);
  }

  static async getServiceGrns(filters) {
    return this.repo.getServiceGrns(filters);
  }
}

export default ServiceGrnService;
