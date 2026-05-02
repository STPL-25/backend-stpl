import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

class WorkFlowApprovalRepository {
  async #executeIntQuery(procedureName, paramName, value) {
    try {
      const request = mssqlPool.request();
      request.input(paramName, mssql.Int, value);
      const result = await request.execute(procedureName);
      return result.recordset;
    } catch (error) {
      console.error(`Error executing stored procedure ${procedureName}:`, error);
      const detail =
        error?.originalError?.message ||
        error?.message ||
        error?.toString() ||
        "Unknown DB error";
      throw new Error(`Database error [${procedureName}]: ${detail}`);
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
      console.error(`Error executing stored procedure ${procedureName}:`, error);
      // Capture full SQL error details (mssql wraps the original error)
      const detail =
        error?.originalError?.message ||
        error?.message ||
        error?.toString() ||
        "Unknown DB error";
      throw new Error(`Database error [${procedureName}]: ${detail}`);
    }
  }

  // approval_workflow_master
  async saveFullWorkflow(data) {
    console.log(data);
    return this.#executeQuery("sp_nt_SaveFullWorkflow", data);
  }

  async getWorkflows() {
    try {
      return await this.#executeQuery("sp_nt_GetWorkflowMasters");
    } catch {
      return [];
    }
  }

  async getWorkflowByEntity(entityType) {
    try {
      return await this.#executeQuery("sp_nt_GetWorkflowByEntity", { entity_type: entityType });
    } catch {
      return [];
    }
  }

  async updateWorkflow(data) {
    return this.#executeQuery("sp_nt_UpdateWorkflowMaster", data);
  }

  // workflow_types
  async saveWorkflowType(data) {
    return this.#executeQuery("sp_nt_SaveWorkflowType", data);
  }

  async getWorkflowTypes(workflowId) {
    try {
      return await this.#executeIntQuery("sp_nt_GetWorkflowTypes", "workflow_id", workflowId);
    } catch {
      return [];
    }
  }

  async updateWorkflowType(data) {
    return this.#executeQuery("sp_nt_UpdateWorkflowType", data);
  }

  // workflow_stage
  async saveWorkflowStage(data) {
    return this.#executeQuery("sp_nt_SaveWorkflowStage", data);
  }

  async getWorkflowStages(workflowTypesId) {
    try {
      return await this.#executeQuery("sp_nt_GetWorkflowStages", { workflow_types_id: workflowTypesId });
    } catch {
      return [];
    }
  }

  async updateWorkflowStage(data) {
    return this.#executeQuery("sp_nt_UpdateWorkflowStage", data);
  }
}

export default WorkFlowApprovalRepository;
