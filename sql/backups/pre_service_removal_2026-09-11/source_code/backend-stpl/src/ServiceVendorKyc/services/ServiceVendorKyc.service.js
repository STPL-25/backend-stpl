import ServiceVendorKycRepository from "../repository/ServiceVendorKyc.repository.js";

class ServiceVendorKycService {
  static repo = new ServiceVendorKycRepository();

  static async createServiceVendorKyc(payload) {
    return this.repo.createServiceVendorKyc(payload);
  }

  static async approveServiceVendorKyc(approvalData) {
    return this.repo.approveServiceVendorKyc(approvalData);
  }

  static async getServiceVendorKycs(filters) {
    return this.repo.getServiceVendorKycs(filters);
  }

  static async getApprovedServiceVendorKycs() {
    return this.repo.getApprovedServiceVendorKycs();
  }

  static async getServiceVendorKycsForApproval(ecno) {
    return this.repo.getServiceVendorKycsForApproval(ecno);
  }
}

export default ServiceVendorKycService;
