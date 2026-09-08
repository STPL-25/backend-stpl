import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

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
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async createServiceVendorKyc(payload) {
    return this.executeJsonProcedure("sp_nt_CreateServiceVendorKyc", payload);
  }

  async approveServiceVendorKyc(approvalData) {
    return this.executeJsonProcedure("sp_approve_service_vendor_kyc", approvalData);
  }

  async getServiceVendorKycs(filters = {}) {
    return this.executeJsonProcedure("sp_nt_GetServiceVendorKycs", filters);
  }

  // Approved records only — for picking which one to map to a service on
  // Service Master (sql/45_service_master_supplier_and_product.sql).
  async getApprovedServiceVendorKycs() {
    try {
      const request = mssqlPool.request();
      const result = await request.execute("sp_nt_GetApprovedServiceVendorKycs");
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // Pending Service Vendor KYC records for the logged-in approver.
  async getServiceVendorKycsForApproval(ecno) {
    try {
      const request = mssqlPool.request();
      request.input("Ecno", mssql.VarChar(50), ecno);
      const result = await request.execute("sp_nt_GetServiceVendorKycsForApproval");
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }
}

export default ServiceVendorKycRepository;
