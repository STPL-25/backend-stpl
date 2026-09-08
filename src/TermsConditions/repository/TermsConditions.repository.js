import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

class TermsConditionsRepository {
  async #executeQuery(procedureName, parameters) {
    try {
      const request = mssqlPool.request();
      if (parameters !== undefined) {
        request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
      }
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

  async getAll() {
    return this.#executeQuery("sp_nt_GetTermsConditionsRecords");
  }

  async create(data) {
    return this.#executeQuery("sp_nt_CreateTermsConditions", data);
  }

  async update(data) {
    return this.#executeQuery("sp_nt_UpdateTermsConditions", data);
  }

  // Soft delete — is_active flips to 'N', the row stays for history.
  async delete(data) {
    return this.#executeQuery("sp_nt_DeleteTermsConditions", data);
  }

  async getDefault(scope) {
    return this.#executeQuery("sp_nt_GetDefaultTermsConditions", scope);
  }
}

export default TermsConditionsRepository;
