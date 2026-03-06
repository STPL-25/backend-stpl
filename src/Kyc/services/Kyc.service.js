import KYCRepo from "../repository/Kyc.repository.js";
class KYCServices {
  static kycRepository = new KYCRepo();

  static async createKYCRecord(data) {
    return this.kycRepository.createKYCRecord(data);
  }
  static getAllKycRecord(){
    return this.kycRepository.getAllKYCRecords();

  }
  
}

export default KYCServices;
