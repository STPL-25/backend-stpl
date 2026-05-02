import KYCRepo from "../repository/Kyc.repository.js";
class KYCServices {
  static kycRepository = new KYCRepo();

  static async createKYCRecord(data) {
    return this.kycRepository.createKYCRecord(data);
  }
  static getAllKycRecord() {
    return this.kycRepository.getAllKYCRecords();
  }
  static getKycApproval(ecno) {
    return this.kycRepository.getKycApproval(ecno);
  }

  static getPendingApprovals(ecno) {
    return this.kycRepository.getPendingApprovals(ecno);
  }

  static approveKyc(data) {
    return this.kycRepository.approveKyc(data);
  }
}

export default KYCServices;
