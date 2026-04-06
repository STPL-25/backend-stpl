import PRRepository from "../repository/PR.repository.js";

class PRService {
  static PRRepository = new PRRepository();

  static async createPrRecords(prData) {
    return this.PRRepository.createPrRecords(prData);
  }

  static async getPrRecords(ecno) {
    return this.PRRepository.getPrRecords(ecno);
  }

  static async approvePr(approvalData) {
    return this.PRRepository.approvePr(approvalData);
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

  // ── DEPT-SCOPED SHARED DRAFT OPERATIONS ──────────────────────────────────

  static async saveDeptDraft(redisClient, ecno, userName, draftData) {
    return this.PRRepository.saveDeptDraft(redisClient, ecno, userName, draftData);
  }

  static async getDeptDrafts(redisClient, scopeKey) {
    return this.PRRepository.getDeptDrafts(redisClient, scopeKey);
  }

  static async getDeptDraft(redisClient, scopeKey, draftId) {
    return this.PRRepository.getDeptDraft(redisClient, scopeKey, draftId);
  }

  static async updateDeptDraft(redisClient, ecno, userName, scopeKey, draftId, draftData) {
    return this.PRRepository.updateDeptDraft(redisClient, ecno, userName, scopeKey, draftId, draftData);
  }

  static async deleteDeptDraft(redisClient, scopeKey, draftId) {
    return this.PRRepository.deleteDeptDraft(redisClient, scopeKey, draftId);
  }

  static async submitDeptDraftToDB(redisClient, scopeKey, draftId) {
    return this.PRRepository.submitDeptDraftToDB(redisClient, scopeKey, draftId);
  }

  static async submitAllDeptDraftsToDB(redisClient, scopeKey) {
    return this.PRRepository.submitAllDeptDraftsToDB(redisClient, scopeKey);
  }
}

export default PRService;
