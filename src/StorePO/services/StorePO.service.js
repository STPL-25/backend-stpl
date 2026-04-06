import StorePORepository from "../repository/StorePO.repository.js";

class StorePOService {
  static repo = new StorePORepository();

  static async createStorePO(poData) {
    return this.repo.createStorePO(poData);
  }

  static async getStorePOs(filters) {
    return this.repo.getStorePOs(filters);
  }

  static async savePODraft(redisClient, ecno, draftData) {
    return this.repo.savePODraft(redisClient, ecno, draftData);
  }

  static async getPODrafts(redisClient, ecno) {
    return this.repo.getPODrafts(redisClient, ecno);
  }

  static async getPODraft(redisClient, ecno, draftId) {
    return this.repo.getPODraft(redisClient, ecno, draftId);
  }

  static async updatePODraft(redisClient, ecno, draftId, draftData) {
    return this.repo.updatePODraft(redisClient, ecno, draftId, draftData);
  }

  static async deletePODraft(redisClient, ecno, draftId) {
    return this.repo.deletePODraft(redisClient, ecno, draftId);
  }

  static async submitPODraftToDB(redisClient, ecno, draftId) {
    return this.repo.submitPODraftToDB(redisClient, ecno, draftId);
  }
}

export default StorePOService;
