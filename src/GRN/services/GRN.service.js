import GRNRepository from "../repository/GRN.repository.js";

class GRNService {
  static repo = new GRNRepository();

  static async getPendingPOs(filters) {
    return this.repo.getPendingPOs(filters);
  }

  static async getGRNsByPO(po_basic_sno) {
    return this.repo.getGRNsByPO(po_basic_sno);
  }

  static async createGRN(grnData) {
    return this.repo.createGRN(grnData);
  }

  static async getAllGRNs(filters) {
    return this.repo.getAllGRNs(filters);
  }

  static async saveGRNDraft(redisClient, ecno, draftData) {
    return this.repo.saveGRNDraft(redisClient, ecno, draftData);
  }

  static async getGRNDrafts(redisClient, ecno) {
    return this.repo.getGRNDrafts(redisClient, ecno);
  }

  static async getGRNDraft(redisClient, ecno, draftId) {
    return this.repo.getGRNDraft(redisClient, ecno, draftId);
  }

  static async updateGRNDraft(redisClient, ecno, draftId, draftData) {
    return this.repo.updateGRNDraft(redisClient, ecno, draftId, draftData);
  }

  static async deleteGRNDraft(redisClient, ecno, draftId) {
    return this.repo.deleteGRNDraft(redisClient, ecno, draftId);
  }

  static async submitGRNDraftToDB(redisClient, ecno, draftId) {
    return this.repo.submitGRNDraftToDB(redisClient, ecno, draftId);
  }
}

export default GRNService;
