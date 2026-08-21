import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

class ServicePORepository {
  constructor() {
    this.storedProcedureMap = {
      getServicePORecords: "sp_nt_GetServicePOsForApproval",
      getAllServicePOs: "sp_nt_GetAllServicePOs",
      getEligiblePrLines: "sp_nt_GetEligiblePrLinesForServicePO",
    };
  }

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

  async createServicePO(payload) {
    return this.executeJsonProcedure("sp_nt_CreateServicePO", payload);
  }

  async createCallOffPO(payload) {
    return this.executeJsonProcedure("sp_nt_CreateCallOffPO", payload);
  }

  async approveServicePO(approvalData) {
    return this.executeJsonProcedure("sp_nt_ApproveServicePO", approvalData);
  }

  // Pending Service POs for the logged-in approver.
  async getServicePORecords(ecno) {
    try {
      const request = mssqlPool.request();
      request.input("Ecno", mssql.VarChar(50), ecno);
      const result = await request.execute(this.storedProcedureMap["getServicePORecords"]);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async getAllServicePOs(filters = {}) {
    return this.executeJsonProcedure(this.storedProcedureMap["getAllServicePOs"], filters);
  }

  async getEligiblePrLines(pr_basic_sno) {
    return this.executeJsonProcedure(this.storedProcedureMap["getEligiblePrLines"], { pr_basic_sno });
  }

  // Vendor contact for the direct-issue "PO generated" email — vendor_sno on
  // a PO is the same key as kyc_basic_info_sno (see PurchaseTeam.repository.js's
  // getVendorContact, same pattern).
  async getVendorContact(vendor_sno) {
    try {
      const request = mssqlPool.request();
      request.input("vendor_sno", mssql.Int, vendor_sno);
      const result = await request.query(
        `SELECT company_name, email
         FROM kyc_basic_info
         WHERE kyc_basic_info_sno = @vendor_sno`
      );
      return result.recordset[0];
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // Item lines for the direct-issue email, in buildPOGeneratedEmail's
  // expected shape (prod_name/unit_name/unit_price/total_amount) rather than
  // po_item_details' own column names.
  async getPoItemsForEmail(po_basic_sno) {
    try {
      const request = mssqlPool.request();
      request.input("po_basic_sno", mssql.Int, po_basic_sno);
      const result = await request.query(
        `SELECT sm.service_name AS prod_name, pid.qty, um.uom_name AS unit_name,
                pid.agreed_unit_price AS unit_price, pid.net_cost AS total_amount
         FROM po_item_details pid
         LEFT JOIN service_master sm ON sm.service_sno = pid.service_sno
         LEFT JOIN uom_master um     ON um.uom_sno = pid.unit
         WHERE pid.po_basic_sno = @po_basic_sno AND pid.is_active = '1'`
      );
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }
}

export default ServicePORepository;
