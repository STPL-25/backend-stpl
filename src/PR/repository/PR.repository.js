import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";
import { randomUUID } from "node:crypto";

let mssqlPool = await initializeDatabase();

const DRAFT_TTL_SECONDS = 7 * 24 * 60 * 60; // 7 days

class PRRepository {
  constructor() {
    this.storedProcedureMap = {
      // getPrRecords: "sp_get_pr_details",
      getPrRecords: "sp_get_pr_details_for_approval",
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
    try {
      console.log(prData)
      const request = mssqlPool.request();
      request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(prData));
      request.output("pr_no", mssql.VarChar(20));
      const result = await request.execute(this.createProcedureMap["createPrRecords"]);
      return {
        recordset: result.recordset,
        pr_no: result.output.pr_no,
      };
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async getPrRecords(ecno) {
    try {
      const request = mssqlPool.request();
      request.input("Ecno", mssql.VarChar(50), ecno);
      const result = await request.execute(this.storedProcedureMap["getPrRecords"]);
      return result.recordset;
    } catch (error) {
      console.log(error)
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async approvePr(approvalData) {
    try {
 
      const request = mssqlPool.request();
      request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(approvalData));
      const result = await request.execute("sp_approve_pr_datas");
      console.log("Approval result:", result);
      return result.recordset;
    } catch (error) {
            console.log(error)

      throw new Error(`Database error: ${error.message}`);
    }
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

  // ── DEPT-SCOPED SHARED DRAFT OPERATIONS (Redis) ───────────────────────────

  buildScopeKey(com_sno, div_sno, brn_sno) {
    return `${com_sno || "x"}:${div_sno || "x"}:${brn_sno || "x"}`;
  }

  async saveDeptDraft(redisClient, ecno, userName, draftData) {
    const { basicInfo = {} } = draftData;
    const scopeKey = this.buildScopeKey(basicInfo.com_sno, basicInfo.div_sno, basicInfo.brn_sno);
    const draftId = randomUUID();
    const key = `pr:deptdraft:${scopeKey}:${draftId}`;
    const indexKey = `pr:deptdrafts:${scopeKey}`;

    const payload = {
      ...draftData,
      draftId,
      scopeKey,
      enteredBy: { ecno, name: userName },
      updatedBy: { ecno, name: userName },
      savedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };

    await redisClient.setEx(key, DRAFT_TTL_SECONDS, JSON.stringify(payload));
    await redisClient.sAdd(indexKey, draftId);
    await redisClient.expire(indexKey, DRAFT_TTL_SECONDS);
    return { draftId, scopeKey, savedAt: payload.savedAt };
  }

  async getDeptDrafts(redisClient, scopeKey) {
    const indexKey = `pr:deptdrafts:${scopeKey}`;
    const draftIds = await redisClient.sMembers(indexKey);
    if (!draftIds || draftIds.length === 0) return [];

    const drafts = await Promise.all(
      draftIds.map(async (draftId) => {
        const key = `pr:deptdraft:${scopeKey}:${draftId}`;
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

  async getDeptDraft(redisClient, scopeKey, draftId) {
    const key = `pr:deptdraft:${scopeKey}:${draftId}`;
    const raw = await redisClient.get(key);
    if (!raw) return null;
    return JSON.parse(raw);
  }

  async updateDeptDraft(redisClient, ecno, userName, scopeKey, draftId, draftData) {
    const key = `pr:deptdraft:${scopeKey}:${draftId}`;
    const existing = await redisClient.get(key);
    if (!existing) return null;

    const prev = JSON.parse(existing);
    const updated = {
      ...prev,
      ...draftData,
      draftId,
      scopeKey,
      updatedBy: { ecno, name: userName },
      savedAt: prev.savedAt,
      updatedAt: new Date().toISOString(),
    };

    await redisClient.setEx(key, DRAFT_TTL_SECONDS, JSON.stringify(updated));
    return updated;
  }

  async deleteDeptDraft(redisClient, scopeKey, draftId) {
    const key = `pr:deptdraft:${scopeKey}:${draftId}`;
    const indexKey = `pr:deptdrafts:${scopeKey}`;
    const deleted = await redisClient.del(key);
    await redisClient.sRem(indexKey, draftId);
    return deleted > 0;
  }

  async submitDeptDraftToDB(redisClient, scopeKey, draftId) {
    const draft = await this.getDeptDraft(redisClient, scopeKey, draftId);
    if (!draft) return null;
    console.log("Submitting dept draft to DB:", { scopeKey, draftId, draft });
    const result = await this.createPrRecords(draft);
    console.log("DB submission result:", result);
    await this.deleteDeptDraft(redisClient, scopeKey, draftId);
    return result;
  }

  async submitAllDeptDraftsToDB(redisClient, scopeKey) {
    const drafts = await this.getDeptDrafts(redisClient, scopeKey);
    if (!drafts.length) return [];

    const results = await Promise.allSettled(
      drafts.map((draft) => this.submitDeptDraftToDB(redisClient, scopeKey, draft.draftId))
    );

    return results.map((r, i) => ({
      draftId: drafts[i].draftId,
      enteredBy: drafts[i].enteredBy,
      status: r.status,
      value: r.value,
      error: r.reason?.message,
    }));
  }
}

export default PRRepository;
