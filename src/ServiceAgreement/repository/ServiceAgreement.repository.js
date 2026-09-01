import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

class ServiceAgreementRepository {
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

  async createServiceAgreement(payload) {
    console.log("Creating service agreement with payload:", payload);
    return this.executeJsonProcedure("sp_nt_CreateServiceAgreement", payload);
  }

  async approveServiceAgreement(approvalData) {
    return this.executeJsonProcedure("sp_approve_service_agreement", approvalData);
  }

  async getServiceAgreements(filters = {}) {
    return this.executeJsonProcedure("sp_nt_GetServiceAgreements", filters);
  }

  // The PR-line auto-fill lookup (spec §5) — always all five scope fields.
  async getActiveServiceAgreement(scope) {
    return this.executeJsonProcedure("sp_nt_GetActiveServiceAgreement", scope);
  }

  // Pending Service Agreements for the logged-in approver.
  async getServiceAgreementsForApproval(ecno) {
    try {
      const request = mssqlPool.request();
      request.input("Ecno", mssql.VarChar(50), ecno);
      const result = await request.execute("sp_nt_GetServiceAgreementsForApproval");
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // ── Recurring service PO sweep (sql/23_service_recurring_flow_redesign.sql) ─
  // Supersedes the old getAgreementsDueForRecurringPR/reserveRecurringPRSlot/
  // finalizeRecurringPRLog/getDefaultPrioritySno dance (sql/13_recurring_pr_job.sql)
  // — the whole PR-create+auto-approve+PO-issue cycle now happens server-side
  // in one procedure call instead of being orchestrated from Node.

  async processDueRecurringServiceAgreements() {
    try {
      const request = mssqlPool.request();
      const result = await request.execute("sp_nt_ProcessDueRecurringServiceAgreements");
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // Flips Approved agreements past period_end_date to Expired (sql/10_service_agreement.sql).
  async expireServiceAgreements() {
    try {
      const request = mssqlPool.request();
      const result = await request.execute("sp_nt_ExpireServiceAgreements");
      return result.recordset[0]?.expired_count ?? 0;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }
}

export default ServiceAgreementRepository;
