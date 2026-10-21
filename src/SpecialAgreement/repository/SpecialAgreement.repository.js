import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

class SpecialAgreementRepository {
  async executeJsonProcedure(procedureName, parameters) {
    const request = mssqlPool.request();
    if (parameters !== undefined) {
      request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
    }
    const result = await request.execute(procedureName);
    return result.recordset;
  }

  create(payload) { return this.executeJsonProcedure("sp_nt_CreateSpecialAgreement", payload); }
  update(payload) { return this.executeJsonProcedure("sp_nt_UpdateSpecialAgreement", payload); }
  approve(payload) { return this.executeJsonProcedure("sp_approve_special_agreement", payload); }
  list(filters = {}) { return this.executeJsonProcedure("sp_nt_GetSpecialAgreements", filters); }
  prOptions(payload) { return this.executeJsonProcedure("sp_nt_GetSpecialAgreementOptionsForPR", payload); }
  applyToPR(payload) { return this.executeJsonProcedure("sp_nt_ApplySpecialAgreementToPR", payload); }
  getRate(payload) { return this.executeJsonProcedure("sp_nt_GetSpecialAgreementRate", payload); }
}

export default SpecialAgreementRepository;
