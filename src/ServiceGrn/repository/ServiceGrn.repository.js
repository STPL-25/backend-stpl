import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

class ServiceGrnRepository {
  async executeJsonProcedure(procedureName, parameters) {
    try {
      const request = mssqlPool.request();
      if (parameters !== undefined) {
        request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
      }
      const result = await request.execute(procedureName);
      return result.recordset;
    } catch (error) {
      // the SPs THROW readable business errors (no workflow, not your approval, ...): keep the bare message
      throw new Error(error.message);
    }
  }

  async createServiceGrn(payload) {
    return this.executeJsonProcedure("sp_nt_CreateServiceGrn", payload);
  }

  async approveServiceGrn(payload) {
    return this.executeJsonProcedure("sp_nt_ApproveServiceGrn", payload);
  }

  async getPendingServiceGrnPOs(filters = {}) {
    return this.executeJsonProcedure("sp_nt_GetPendingServiceGrnPOs", filters);
  }

  async getServiceGrns(filters = {}) {
    return this.executeJsonProcedure("sp_nt_GetServiceGrns", filters);
  }
}

export default ServiceGrnRepository;
