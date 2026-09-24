import ServiceVendorKycRepository from "../repository/ServiceVendorKyc.repository.js";

class ServiceVendorKycService {
  static repo = new ServiceVendorKycRepository();

  static createServiceVendorKyc(payload) {
    return this.repo.createServiceVendorKyc(payload);
  }

  static approveServiceVendorKyc(payload) {
    return this.repo.approveServiceVendorKyc(payload);
  }

  static getServiceVendorKycs(filters) {
    return this.repo.getServiceVendorKycs(filters);
  }

  static getApprovedServiceVendorKycs() {
    return this.repo.getApprovedServiceVendorKycs();
  }

  static getServiceVendorKycsForApproval(ecno) {
    return this.repo.getServiceVendorKycsForApproval(ecno);
  }
}

export default ServiceVendorKycService;
