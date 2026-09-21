import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";

class ServiceEntryRepository {
  async executeStoredProcedure(procedureName, parameters = {}) {
    try {
      const pool = await initializeDatabase();
      const request = pool.request();
      if (Object.keys(parameters).length > 0) {
        request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
      }
      const result = await request.execute(procedureName);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async getPendingServicePOs(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetPendingServicePOsForServiceEntry", filters);
  }

  async getServiceEntriesByPO(po_basic_sno) {
    return this.executeStoredProcedure("sp_nt_GetServiceEntriesByPO", { po_basic_sno });
  }

  async createServiceEntry(payload) {
    return this.executeStoredProcedure("sp_nt_CreateServiceEntry", payload);
  }

  async approveServiceEntry(approvalData) {
    return this.executeStoredProcedure("sp_nt_ApproveServiceEntry", approvalData);
  }

  async getAllServiceEntries(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetAllServiceEntries", filters);
  }
}

export default ServiceEntryRepository;
