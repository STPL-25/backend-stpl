import PORepository from "../repository/PO.repository.js";

class POService {
  static PORepository = new PORepository();

  static async getPoRecords(ecno, hierarchyJson) {
    return this.PORepository.getPoRecords(ecno, hierarchyJson);
  }

  static async approvePo(approvalData) {
    return this.PORepository.approvePo(approvalData);
  }
}

export default POService;
