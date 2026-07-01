import PORepository from "../repository/PO.repository.js";

class POService {
  static PORepository = new PORepository();

  static async getPoRecords(ecno) {
    return this.PORepository.getPoRecords(ecno);
  }

  static async approvePo(approvalData) {
    return this.PORepository.approvePo(approvalData);
  }
}

export default POService;
