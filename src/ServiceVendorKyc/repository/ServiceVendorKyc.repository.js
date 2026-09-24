import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

// The Service Vendor KYC procs (sql/91) raise their own user-facing messages
// with THROW numbers in the 58xxx range. Those are validation outcomes, not
// database failures, so they are passed on verbatim with a 400 status instead
// of being wrapped as "Database error: ...".
function toApiError(error) {
  const number = error?.number ?? error?.originalError?.info?.number;
  if (Number.isInteger(number) && number >= 58000 && number < 59000) {
    const validation = new Error(error.message);
    validation.status = 400;
    return validation;
  }
  return new Error(`Database error: ${error.message}`);
}

class ServiceVendorKycRepository {
  async executeJsonProcedure(procedureName, parameters) {
    try {
      const request = mssqlPool.request();
      if (parameters !== undefined) {
        request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
      }
      const result = await request.execute(procedureName);
      return result.recordset;
    } catch (error) {
      throw toApiError(error);
    }
  }

  createServiceVendorKyc(payload) {
    return this.executeJsonProcedure("sp_nt_CreateServiceVendorKyc", payload);
  }

  approveServiceVendorKyc(payload) {
    return this.executeJsonProcedure("sp_approve_service_vendor_kyc", payload);
  }

  getServiceVendorKycs(filters = {}) {
    return this.executeJsonProcedure("sp_nt_GetServiceVendorKycs", filters);
  }

  getApprovedServiceVendorKycs() {
    return this.executeJsonProcedure("sp_nt_GetApprovedServiceVendorKycs");
  }

  // Pending records for the logged-in approver — takes a bare @Ecno, not the
  // generic @jsonInput wrapper, same as LoanVoucher's ...ForApproval query.
  async getServiceVendorKycsForApproval(ecno) {
    try {
      const request = mssqlPool.request();
      request.input("Ecno", mssql.VarChar(50), ecno);
      const result = await request.execute("sp_nt_GetServiceVendorKycsForApproval");
      return result.recordset;
    } catch (error) {
      throw toApiError(error);
    }
  }
}

export default ServiceVendorKycRepository;
