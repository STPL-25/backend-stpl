import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";
import { randomUUID } from "node:crypto";

let mssqlPool = await initializeDatabase();

const DRAFT_TTL = 30 * 24 * 60 * 60; // 30 days

class PurchaseTeamRepository {
  async executeStoredProcedure(procedureName, parameters = {}) {
    try {
      const request = mssqlPool.request();
      if (Object.keys(parameters).length > 0) {
        request.input(
          "jsonInput",
          mssql.NVarChar(mssql.MAX),
          JSON.stringify(parameters)
        );
      }
      const result = await request.execute(procedureName);
      return result.recordset;
    } catch (error) {
      console.log(error)
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // ── GET APPROVED PRs FOR PURCHASE TEAM ──────────────────────────────────
  async getApprovedPRs(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetApprovedPRsForPurchase", filters);
  }

  // ── GET APPROVED VENDORS (from KYC) ─────────────────────────────────────
  async getApprovedVendors(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetApprovedVendors", filters);
  }

  // ── SUPPLIER QUOTATION ──────────────────────────────────────────────────
  async createSupplierQuotation(quotationData) {

    console.log("Creating supplier quotation with data:", quotationData);
    return this.executeStoredProcedure("sp_nt_CreateSupplierQuotation", quotationData);
  }

  async getSupplierQuotations(prBasicSno) {
    try {
      const request = mssqlPool.request();
      request.input("pr_basic_sno", mssql.Int, prBasicSno);
      const result = await request.execute("sp_nt_GetSupplierQuotations");
      return result.recordset;
    } catch (error) {
      console.log(error)
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async selectQuotation(selectedQuotation, selectedBy) {
    try {
      console.log();
      const request = mssqlPool.request();
      request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(selectedQuotation));
      const result = await request.execute("sp_nt_SelectSupplierQuotation");
      console.log(result)
      return result.recordset;
    } catch (error) {
      console.log(error);
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // ── CREATE PO FROM QUOTATION ────────────────────────────────────────────
  async createPOFromQuotation(poData) {
    return this.executeStoredProcedure("sp_nt_CreatePOFromQuotation", poData);
  }

  // ── UPDATE ITEM QUANTITY ────────────────────────────────────────────────
  async updateItemQuantity(updateData) {
    return this.executeStoredProcedure("sp_nt_UpdatePOItemQuantity", updateData);
  }

  // ── DRAFT OPERATIONS (Redis) ────────────────────────────────────────────

  async saveQuotationDraft(redisClient, ecno, draftData) {
    const draftId = randomUUID();
    const key = `purchase_team:quotation_draft:${ecno}:${draftId}`;
    const indexKey = `purchase_team:quotation_drafts:${ecno}`;

    const payload = {
      ...draftData,
      draftId,
      ecno,
      status: "Draft",
      savedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };

    await redisClient.setEx(key, DRAFT_TTL, JSON.stringify(payload));
    await redisClient.sAdd(indexKey, draftId);
    await redisClient.expire(indexKey, DRAFT_TTL);
    return { draftId, savedAt: payload.savedAt };
  }

  async getQuotationDrafts(redisClient, ecno) {
    const indexKey = `purchase_team:quotation_drafts:${ecno}`;
    const draftIds = await redisClient.sMembers(indexKey);
    if (!draftIds || draftIds.length === 0) return [];

    const drafts = await Promise.all(
      draftIds.map(async (draftId) => {
        const key = `purchase_team:quotation_draft:${ecno}:${draftId}`;
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

  async deleteQuotationDraft(redisClient, ecno, draftId) {
    const key = `purchase_team:quotation_draft:${ecno}:${draftId}`;
    const indexKey = `purchase_team:quotation_drafts:${ecno}`;
    const deleted = await redisClient.del(key);
    await redisClient.sRem(indexKey, draftId);
    return deleted > 0;
  }
}

export default PurchaseTeamRepository;
