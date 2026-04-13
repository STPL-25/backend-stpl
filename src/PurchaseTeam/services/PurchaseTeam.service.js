import PurchaseTeamRepository from "../repository/PurchaseTeam.repository.js";

class PurchaseTeamService {
  static repo = new PurchaseTeamRepository();

  static async getApprovedPRs(filters) {
    return this.repo.getApprovedPRs(filters);
  }

  static async getApprovedVendors(filters) {
    return this.repo.getApprovedVendors(filters);
  }

  static async createSupplierQuotation(quotationData) {
    return this.repo.createSupplierQuotation(quotationData);
  }

  static async getSupplierQuotations(prBasicSno) {
    return this.repo.getSupplierQuotations(prBasicSno);
  }

  static async selectQuotation(selectedQuotation, selectedBy) {
    return this.repo.selectQuotation(selectedQuotation, selectedBy);
  }

  static async createPOFromQuotation(poData) {
    return this.repo.createPOFromQuotation(poData);
  }

  static async updateItemQuantity(updateData) {
    return this.repo.updateItemQuantity(updateData);
  }

  static async saveQuotationDraft(redisClient, ecno, draftData) {
    return this.repo.saveQuotationDraft(redisClient, ecno, draftData);
  }

  static async getQuotationDrafts(redisClient, ecno) {
    return this.repo.getQuotationDrafts(redisClient, ecno);
  }

  static async deleteQuotationDraft(redisClient, ecno, draftId) {
    return this.repo.deleteQuotationDraft(redisClient, ecno, draftId);
  }
}

export default PurchaseTeamService;
