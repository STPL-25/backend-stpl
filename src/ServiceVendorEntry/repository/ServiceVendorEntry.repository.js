import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

class ServiceVendorEntryRepository {
  async executeJsonProcedure(procedureName, parameters) {
    try {
      const request = mssqlPool.request();
      if (parameters !== undefined) {
        request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
      }
      const result = await request.execute(procedureName);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async createEntry(payload) {
    return this.executeJsonProcedure("sp_nt_CreateServiceVendorDailyEntry", payload);
  }

  async getEntries(filters = {}) {
    return this.executeJsonProcedure("sp_nt_GetServiceVendorDailyEntries", filters);
  }

  async lockEntries(payload) {
    return this.executeJsonProcedure("sp_nt_LockServiceVendorEntriesForConsolidation", payload);
  }

  async finalizeEntries(payload) {
    return this.executeJsonProcedure("sp_nt_FinalizeServiceVendorEntriesConsolidation", payload);
  }

  async releaseEntriesLock(payload) {
    return this.executeJsonProcedure("sp_nt_ReleaseServiceVendorEntriesLock", payload);
  }

  async cancelEntry(payload) {
    return this.executeJsonProcedure("sp_nt_CancelServiceVendorDailyEntry", payload);
  }
}

export default ServiceVendorEntryRepository;
