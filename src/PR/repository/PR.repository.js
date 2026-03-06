import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";
import { randomUUID } from "node:crypto";

let mssqlPool = await initializeDatabase();

const DRAFT_TTL_SECONDS = 7 * 24 * 60 * 60; // 7 days

class PRRepository {
  constructor() {
    this.storedProcedureMap = {
      getPrRecords: "sp_get_pr_details",
    };

    this.createProcedureMap = {
      createPrRecords: "usp_InsertPurchaseRequest",
    };
  }

  async executeStoredProcedure(procedureName, parameters = {}) {
    try {
      const request = mssqlPool.request();
      if (Object.keys(parameters).length > 0) {
        request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
      }
      const result = await request.execute(procedureName);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async createPrRecords(prData) {
    return this.executeStoredProcedure(this.createProcedureMap["createPrRecords"], prData);
  }

  async getPrRecords() {
    return this.executeStoredProcedure(this.storedProcedureMap["getPrRecords"]);
  }

  // ── DRAFT OPERATIONS (Redis) ──────────────────────────────────────────────

  async saveDraft(redisClient, ecno, draftData) {
    const draftId = randomUUID();
    const key = `pr:draft:${ecno}:${draftId}`;
    const indexKey = `pr:drafts:${ecno}`;

    const payload = {
      ...draftData,
      draftId,
      ecno,
      savedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };

    await redisClient.setEx(key, DRAFT_TTL_SECONDS, JSON.stringify(payload));
    await redisClient.sAdd(indexKey, draftId);
    await redisClient.expire(indexKey, DRAFT_TTL_SECONDS);

    return { draftId, savedAt: payload.savedAt };
  }

  async getDrafts(redisClient, ecno) {
    const indexKey = `pr:drafts:${ecno}`;
    const draftIds = await redisClient.sMembers(indexKey);

    if (!draftIds || draftIds.length === 0) return [];

    const drafts = await Promise.all(
      draftIds.map(async (draftId) => {
        const key = `pr:draft:${ecno}:${draftId}`;
        const raw = await redisClient.get(key);
        if (!raw) {
          await redisClient.sRem(indexKey, draftId);
          return null;
        }
        return JSON.parse(raw);
      })
    );

    return drafts
      .filter(Boolean)
      .sort((a, b) => new Date(b.updatedAt) - new Date(a.updatedAt));
  }

  async getDraft(redisClient, ecno, draftId) {
    const key = `pr:draft:${ecno}:${draftId}`;
    const raw = await redisClient.get(key);
    if (!raw) return null;
    return JSON.parse(raw);
  }

  async updateDraft(redisClient, ecno, draftId, draftData) {
    const key = `pr:draft:${ecno}:${draftId}`;
    const existing = await redisClient.get(key);
    if (!existing) return null;

    const prev = JSON.parse(existing);
    const updated = {
      ...prev,
      ...draftData,
      draftId,
      ecno,
      savedAt: prev.savedAt,
      updatedAt: new Date().toISOString(),
    };

    await redisClient.setEx(key, DRAFT_TTL_SECONDS, JSON.stringify(updated));
    return { draftId, updatedAt: updated.updatedAt };
  }

  async deleteDraft(redisClient, ecno, draftId) {
    const key = `pr:draft:${ecno}:${draftId}`;
    const indexKey = `pr:drafts:${ecno}`;
    const deleted = await redisClient.del(key);
    await redisClient.sRem(indexKey, draftId);
    return deleted > 0;
  }

  async submitDraftToDB(redisClient, ecno, draftId) {
    const draft = await this.getDraft(redisClient, ecno, draftId);
    if (!draft) return null;

    const result = await this.createPrRecords(draft);
    // Remove draft from Redis on successful submission
    await this.deleteDraft(redisClient, ecno, draftId);
    return result;
  }
}

export default PRRepository;
