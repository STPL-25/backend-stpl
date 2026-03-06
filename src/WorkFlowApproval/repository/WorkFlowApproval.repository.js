import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

class WorkFlowApprovalRepository {
  async #executeStoredProcedure(procedureName, parameters = {}) {
    try {
      const request = mssqlPool.request();

      if (Object.keys(parameters).length > 0) {
        request.input("workflow_json", mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
        request.input("created_by", mssql.VarChar(20), parameters.created_by || "SYSTEM");
      }

      request.output("workflow_id", mssql.Int);
      request.output("success", mssql.Bit);
      request.output("message", mssql.NVarChar(500));

      const result = await request.execute(procedureName);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async #executeQuery(procedureName, parameters = {}) {
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

  createWorkFlowApproval(data) {
    return this.#executeStoredProcedure("sp_SaveWorkflowMaster", data);
  }

  async getWorkflows() {
    try {
      return await this.#executeQuery("sp_GetWorkflowMasters");
    } catch {
      // SP may not exist yet — return empty
      return [];
    }
  }

  async getWorkflowByEntity(entityType) {
    try {
      return await this.#executeQuery("sp_GetWorkflowByEntity", { entity_type: entityType });
    } catch {
      return [];
    }
  }
}

export default WorkFlowApprovalRepository;
