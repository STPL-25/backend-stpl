import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";
import { randomUUID } from "node:crypto";

let mssqlPool = await initializeDatabase();

const PO_DRAFT_TTL = 30 * 24 * 60 * 60; // 30 days

class StorePORepository {
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

  async createStorePO(poData) {
    return this.executeStoredProcedure("usp_CreateStorePO", poData);
  }

  async getStorePOs(filters = {}) {
    return this.executeStoredProcedure("sp_GetStorePOs", filters);
  }

  // ── DRAFT OPERATIONS (Redis) ──────────────────────────────────────────────

  async savePODraft(redisClient, ecno, draftData) {
    const draftId = randomUUID();
    const key = `po:draft:${ecno}:${draftId}`;
    const indexKey = `po:drafts:${ecno}`;

    const payload = {
      ...draftData,
      draftId,
      ecno,
      status: "Draft",
      savedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };

    await redisClient.setEx(key, PO_DRAFT_TTL, JSON.stringify(payload));
    await redisClient.sAdd(indexKey, draftId);
    await redisClient.expire(indexKey, PO_DRAFT_TTL);
    return { draftId, savedAt: payload.savedAt };
  }

  async getPODrafts(redisClient, ecno) {
    const indexKey = `po:drafts:${ecno}`;
    const draftIds = await redisClient.sMembers(indexKey);
    if (!draftIds || draftIds.length === 0) return [];

    const drafts = await Promise.all(
      draftIds.map(async (draftId) => {
        const key = `po:draft:${ecno}:${draftId}`;
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

  async getPODraft(redisClient, ecno, draftId) {
    const key = `po:draft:${ecno}:${draftId}`;
    const raw = await redisClient.get(key);
    if (!raw) return null;
    return JSON.parse(raw);
  }

  async updatePODraft(redisClient, ecno, draftId, draftData) {
    const key = `po:draft:${ecno}:${draftId}`;
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

    await redisClient.setEx(key, PO_DRAFT_TTL, JSON.stringify(updated));
    return { draftId, updatedAt: updated.updatedAt };
  }

  async deletePODraft(redisClient, ecno, draftId) {
    const key = `po:draft:${ecno}:${draftId}`;
    const indexKey = `po:drafts:${ecno}`;
    const deleted = await redisClient.del(key);
    await redisClient.sRem(indexKey, draftId);
    return deleted > 0;
  }

  async submitPODraftToDB(redisClient, ecno, draftId) {
    const draft = await this.getPODraft(redisClient, ecno, draftId);
    if (!draft) return null;
    const result = await this.createStorePO(draft);
    await this.deletePODraft(redisClient, ecno, draftId);
    return result;
  }
}

export default StorePORepository;
