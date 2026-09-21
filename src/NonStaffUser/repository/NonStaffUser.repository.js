import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

class NonStaffUserRepository {
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

  // login_id is generated server-side by the stored procedure (dbo.seq_nonstaff_login_id) —
  // never accepted from the caller, so it can't collide with a staff ecno.
  async createLogin({ full_name, designation_sno, email, phone, password_hash, created_by }) {
    return this.executeStoredProcedure("sp_nt_CreateNonStaffLogin", {
      full_name, designation_sno, email, phone, password_hash, created_by,
    });
  }

  async findLoginById(login_id) {
    return this.executeStoredProcedure("sp_nt_GetNonStaffLoginById", { login_id });
  }

  async setPassword({ login_id, password_hash }) {
    return this.executeStoredProcedure("sp_nt_SetNonStaffPassword", { login_id, password_hash });
  }

  async listUsers() {
    return this.executeStoredProcedure("sp_nt_GetNonStaffUsers");
  }
}

export default NonStaffUserRepository;
