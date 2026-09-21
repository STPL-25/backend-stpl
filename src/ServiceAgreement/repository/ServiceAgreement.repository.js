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

  async updateServiceAgreement(payload) {
    return this.executeJsonProcedure("sp_nt_UpdateServiceAgreement", payload);
  }

  async getServiceTypeCode(service_sno) {
    try {
      const request = mssqlPool.request();
      request.input("service_sno", mssql.Int, service_sno);
      const result = await request.query(
        `SELECT st.service_type_code
           FROM dbo.service_master sm
           JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
          WHERE sm.service_sno = @service_sno`
      );
      return result.recordset[0]?.service_type_code ?? null;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // A loan (Statutory agreement) has no per-cycle rate or PO cadence of its own, but the
  // agreement row still needs one — it is the monthly cadence, keyed by its code rather
  // than a hardcoded sno since master snos aren't stable.
  async getMonthlyCadenceSno() {
    try {
      const result = await mssqlPool.request().query(
        "SELECT TOP 1 recurrence_cadence_sno FROM dbo.recurrence_cadence_master WHERE cadence_code = 'MONTHLY' AND is_active = 'Y'"
      );
      return result.recordset[0]?.recurrence_cadence_sno ?? null;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async approveServiceAgreement(approvalData) {
    return this.executeJsonProcedure("sp_approve_service_agreement", approvalData);
  }

  async getServiceAgreements(filters = {}) {
    return this.executeJsonProcedure("sp_nt_GetServiceAgreements", filters);
  }

  // One agreement's whole life (versions, approval trail, cycles + POs) —
  // a single row of three JSON columns, parsed by the service layer.
  async getServiceAgreementHistory(agreement_sno) {
    try {
      const request = mssqlPool.request();
      request.input("agreement_sno", mssql.Int, agreement_sno);
      const result = await request.execute("sp_nt_GetServiceAgreementHistory");
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
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

  // ── Recurring service PO sweep (sql/72_service_agreement_rebuild.sql) ──────
  // The whole PR-auto-create+auto-approve, PO-auto-issue cycle happens
  // server-side in one procedure call — this repo method (and the job that
  // polls it) doesn't orchestrate any of it from Node.
  // Two result sets since sql/81_service_agreement_dispatch_grn.sql: the
  // aggregate summary (unchanged) plus one row per PO actually issued this
  // run, so the caller can dispatch (email/in-app) each individually.
  async processDueRecurringServiceAgreements() {
    try {
      const request = mssqlPool.request();
      const result = await request.execute("sp_nt_ProcessDueRecurringServiceAgreements");
      return {
        summary: result.recordsets?.[0]?.[0] ?? null,
        issued: result.recordsets?.[1] ?? [],
      };
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // Flips Approved agreements past period_end_date to Expired.
  async expireServiceAgreements() {
    try {
      const request = mssqlPool.request();
      const result = await request.execute("sp_nt_ExpireServiceAgreements");
      return result.recordset[0]?.expired_count ?? 0;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // ── Notify-before-generation sweep ──────────────────────────────────────
  // Claims due reminders as PENDING and returns them; the job then creates an
  // in-app notification per row and reports back via markAgreementNotificationSent.
  async getAgreementsDueForNotification() {
    try {
      const request = mssqlPool.request();
      const result = await request.execute("sp_nt_GetAgreementsDueForNotification");
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async markAgreementNotificationSent(payload) {
    return this.executeJsonProcedure("sp_nt_MarkAgreementNotificationSent", payload);
  }

  // ── Supplier/Incharge dispatch (sql/81_service_agreement_dispatch_grn.sql) ─
  async getServicePoDispatchInfo(po_basic_sno) {
    try {
      const request = mssqlPool.request();
      request.input("po_basic_sno", mssql.Int, po_basic_sno);
      const result = await request.execute("sp_nt_GetServicePoDispatchInfo");
      return result.recordset?.[0] ?? null;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // Same shared po_history_data audit row the regular PO-email flow already
  // logs via sp_nt_LogPOSentToSupplier (sql/29_pr_tracking.sql,
  // PurchaseTeamRepository.logPOSentToSupplier) — reused as-is for the
  // Supplier dispatch path so both PO flows show up in the same history.
  async logPOSentToSupplier(po_basic_sno, status_by, comment) {
    try {
      const request = mssqlPool.request();
      request.input("po_basic_sno", mssql.Int, po_basic_sno);
      request.input("status_by", mssql.VarChar(20), status_by);
      request.input("comment", mssql.VarChar(250), comment ?? null);
      const result = await request.execute("sp_nt_LogPOSentToSupplier");
      return result.recordset[0];
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async logServiceDispatchToIncharge(po_basic_sno, status_by, comment) {
    try {
      const request = mssqlPool.request();
      request.input("po_basic_sno", mssql.Int, po_basic_sno);
      request.input("status_by", mssql.VarChar(20), status_by);
      request.input("comment", mssql.VarChar(250), comment ?? null);
      const result = await request.execute("sp_nt_LogServicePoDispatchedToIncharge");
      return result.recordset[0];
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }
}

export default ServiceAgreementRepository;
