import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

/**
 * The RFQ procedures (sql/154_rfq.sql) report business-rule problems with THROW 53xxx. Those messages are written for
 * the buyer ("The due date has passed ..."), so they are passed through untouched with a 400 instead of being wrapped
 * as "Database error: ..." like an unexpected failure.
 */
function toError(error) {
  if (error?.number >= 53000 && error?.number < 54000) {
    return Object.assign(new Error(error.message), { status: 400 });
  }
  return new Error(`Database error: ${error.message}`);
}

function parseJson(value, fallback) {
  if (value == null) return fallback;
  if (typeof value !== "string") return value;
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

class RfqRepository {
  async runJson(procedureName, payload) {
    try {
      const request = mssqlPool.request();
      request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(payload ?? {}));
      return await request.execute(procedureName);
    } catch (error) {
      console.log(error);
      throw toError(error);
    }
  }

  async createRfq(payload) {
    const result = await this.runJson("sp_nt_CreateRfq", payload);
    return result.recordset[0];
  }

  // header, suppliers (where to send), items
  async getEmailPayload({ rfq_sno, rfq_supplier_sno }) {
    const result = await this.runJson("sp_nt_GetRfqEmailPayload", { rfq_sno, rfq_supplier_sno });
    const [header, suppliers, items] = result.recordsets;
    return { header: header?.[0] ?? null, suppliers: suppliers ?? [], items: items ?? [] };
  }

  async setEmailStatus(payload) {
    await this.runJson("sp_nt_SetRfqEmailStatus", payload);
  }

  async getRfqsForPR(prBasicSno, prNo) {
    try {
      const request = mssqlPool.request();
      request.input("pr_basic_sno", mssql.Int, prBasicSno);
      request.input("pr_no", mssql.VarChar(50), prNo || null);
      const result = await request.execute("sp_nt_GetRfqsForPR");
      return (result.recordset ?? []).map((row) => ({
        ...row,
        items: parseJson(row.items, []),
        suppliers: parseJson(row.suppliers, []),
      }));
    } catch (error) {
      console.log(error);
      throw toError(error);
    }
  }

  async getResponseVersions(rfqSupplierSno) {
    try {
      const request = mssqlPool.request();
      request.input("rfq_supplier_sno", mssql.Int, rfqSupplierSno);
      const result = await request.execute("sp_nt_GetRfqResponseVersions");
      const versions = (result.recordsets[0] ?? []).map((row) => ({ ...row, items: parseJson(row.items, []) }));
      return { versions, log: result.recordsets[1] ?? [] };
    } catch (error) {
      console.log(error);
      throw toError(error);
    }
  }

  async requestRevision(payload) {
    const result = await this.runJson("sp_nt_RequestRfqRevision", payload);
    return result.recordset[0];
  }

  async closeRfq(payload) {
    const result = await this.runJson("sp_nt_CloseRfq", payload);
    return result.recordset[0];
  }

  async takeResponse(payload) {
    const result = await this.runJson("sp_nt_TakeRfqResponse", payload);
    return result.recordset[0];
  }

  async getSupplierContacts() {
    try {
      const result = await mssqlPool.request().execute("sp_nt_GetRfqSupplierContacts");
      return result.recordset;
    } catch (error) {
      console.log(error);
      throw toError(error);
    }
  }
}

export default RfqRepository;
