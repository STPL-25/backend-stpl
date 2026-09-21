import ServiceEntryRepository from "./serviceentry.repository.js";

class ServiceEntryService {
  static repo = new ServiceEntryRepository();

  static async getPendingServicePOs(filters) {
    return this.repo.getPendingServicePOs(filters);
  }

  static async getServiceEntriesByPO(po_basic_sno) {
    return this.repo.getServiceEntriesByPO(po_basic_sno);
  }

  static async createServiceEntry(payload) {
    return this.repo.createServiceEntry(payload);
  }

  static async approveServiceEntry(approvalData) {
    return this.repo.approveServiceEntry(approvalData);
  }

  static async getAllServiceEntries(filters) {
    return this.repo.getAllServiceEntries(filters);
  }
}

export default ServiceEntryService;
