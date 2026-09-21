import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

class ServiceBillRequestRepository {
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

  async createServiceBillRequest(payload) {
    return this.executeJsonProcedure("sp_nt_CreateServiceBillRequest", payload);
  }

  async approveServiceBillRequest(approvalData) {
    return this.executeJsonProcedure("sp_nt_ApproveServiceBillRequest", approvalData);
  }

  async getServiceBillRequests(filters = {}) {
    return this.executeJsonProcedure("sp_nt_GetServiceBillRequests", filters);
  }

  // Approved, in-period Variable Recurring ceiling agreements for an org
  // scope — feeds the entry screen's agreement picker.
  async getActiveCeilingAgreementsForBilling(scope) {
    return this.executeJsonProcedure("sp_nt_GetActiveCeilingAgreementsForBilling", scope);
  }

  // Retries PO auto-issuance for an Approved bill request whose PO failed to
  // issue at approval time (see sp_nt_ApproveServiceBillRequest's own
  // swallow-and-log-instead-of-fail-the-approval behavior).
  async retryPOIssue(payload) {
    return this.executeJsonProcedure("sp_nt_RetryServiceBillRequestPOIssue", payload);
  }

  // Pending bill requests for the logged-in approver.
  async getServiceBillRequestsForApproval(ecno) {
    try {
      const request = mssqlPool.request();
      request.input("Ecno", mssql.VarChar(50), ecno);
      const result = await request.execute("sp_nt_GetServiceBillRequestsForApproval");
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }
}

export default ServiceBillRequestRepository;
