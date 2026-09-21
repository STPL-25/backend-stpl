import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

class ServicePoRepository {
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

  async submitServicePoEntry(payload) {
    return this.executeJsonProcedure("sp_nt_SubmitServicePoEntry", payload);
  }

  async approveServicePoCycle(approvalData) {
    return this.executeJsonProcedure("sp_nt_ApproveServicePoCycle", approvalData);
  }

  async getServicePoCycles(filters = {}) {
    return this.executeJsonProcedure("sp_nt_GetServicePoCycles", filters);
  }

  // Pending Service PO cycles for the logged-in approver.
  async getServicePoCyclesForApproval(ecno) {
    try {
      const request = mssqlPool.request();
      request.input("Ecno", mssql.VarChar(50), ecno);
      const result = await request.execute("sp_nt_GetServicePoCyclesForApproval");
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }
}

export default ServicePoRepository;
