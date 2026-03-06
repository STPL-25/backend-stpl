import PRRepository from "../repository/PR.repository.js";

class PRService {
  static PRRepository = new PRRepository();

  static async createPrRecords(prData) {
    return this.PRRepository.createPrRecords(prData);
  }

  static async getPrRecords() {
    return this.PRRepository.getPrRecords();
  }

  // ── DRAFT OPERATIONS ─────────────────────────────────────────────────────

  static async saveDraft(redisClient, ecno, draftData) {
    return this.PRRepository.saveDraft(redisClient, ecno, draftData);
  }

  static async getDrafts(redisClient, ecno) {
    return this.PRRepository.getDrafts(redisClient, ecno);
  }

  static async getDraft(redisClient, ecno, draftId) {
    return this.PRRepository.getDraft(redisClient, ecno, draftId);
  }

  static async updateDraft(redisClient, ecno, draftId, draftData) {
    return this.PRRepository.updateDraft(redisClient, ecno, draftId, draftData);
  }

  static async deleteDraft(redisClient, ecno, draftId) {
    return this.PRRepository.deleteDraft(redisClient, ecno, draftId);
  }

  static async submitDraftToDB(redisClient, ecno, draftId) {
    return this.PRRepository.submitDraftToDB(redisClient, ecno, draftId);
  }
}

export default PRService;
