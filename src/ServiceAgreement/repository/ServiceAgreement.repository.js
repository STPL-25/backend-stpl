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

  // ── Recurring PR job (spec §5, sql/13_recurring_pr_job.sql) ─────────────

  // Agreements whose recurrence_cadence boundary is today and haven't
  // already been billed (by this job or a manual PR) this period.
  async getAgreementsDueForRecurringPR() {
    try {
      const request = mssqlPool.request();
      const result = await request.execute("sp_nt_GetAgreementsDueForRecurringPR");
      console.log(result.recordset);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // Atomically claims (agreement_sno, billing_period_start) via the table's
  // UNIQUE constraint before the job attempts to create a PR for it. Returns
  // the new log_sno, or null if another process already claimed this exact
  // period first (2627/2601 = SQL Server's unique-constraint/index violation
  // — not a real error here, just "someone beat us to it").
  async reserveRecurringPRSlot(agreement_sno, billing_period_start) {
    try {
      const request = mssqlPool.request();
      request.input("agreement_sno", mssql.Int, agreement_sno);
      request.input("billing_period_start", mssql.Date, billing_period_start);
      const result = await request.query(
        `INSERT INTO service_agreement_recurring_pr_log (agreement_sno, billing_period_start, status)
         OUTPUT INSERTED.log_sno
         VALUES (@agreement_sno, @billing_period_start, 'PENDING')`
      );
      return result.recordset[0]?.log_sno ?? null;
    } catch (error) {
      if (error.number === 2627 || error.number === 2601) return null;
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async finalizeRecurringPRLog(log_sno, { status, pr_basic_sno, pr_no, error_message }) {
    try {
      const request = mssqlPool.request();
      request.input("log_sno", mssql.Int, log_sno);
      request.input("status", mssql.VarChar(20), status);
      request.input("pr_basic_sno", mssql.Int, pr_basic_sno ?? null);
      request.input("pr_no", mssql.VarChar(20), pr_no ?? null);
      request.input("error_message", mssql.NVarChar(500), error_message ?? null);
      await request.query(
        `UPDATE service_agreement_recurring_pr_log
         SET status = @status, pr_basic_sno = @pr_basic_sno, pr_no = @pr_no,
             error_message = @error_message, modified_at = GETDATE()
         WHERE log_sno = @log_sno`
      );
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

  // A recurring PR has no human picking a priority — reuses the existing
  // Masters pipeline's own procedure (sp_nt_GetPriorityRecords, wired as
  // "PriorityMaster" in CommonMasterRepo.js) rather than guessing at
  // priority_master's column names directly.
  async getDefaultPrioritySno() {
    try {
      const request = mssqlPool.request();
      const result = await request.execute("sp_nt_GetPriorityRecords");
      return result.recordset[0]?.priority_sno ?? null;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }
}

export default ServiceAgreementRepository;
