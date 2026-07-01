import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

class PORepository {
  constructor() {
    this.storedProcedureMap = {
      // Pending supplier quotations awaiting the logged-in approver
      getPoRecords: "sp_nt_GetQuotationsForApproval",
      // Approve / reject a supplier quotation (advances the workflow stage)
      approvePo: "sp_nt_ApproveSupplierQuotation",
    };
  }

  

  // Pending quotations for the logged-in approver. The SP returns one row per
  // quotation with header + vendor columns plus JSON columns:
  //   quotation_item_details, stage_order_json, quotation_history,
  //   pr_header, original_pr_item_details
  async getPoRecords(ecno) {
    try {
      const request = mssqlPool.request();
      request.input("Ecno", mssql.VarChar(50), ecno);
      const result = await request.execute(this.storedProcedureMap["getPoRecords"]);
      return result.recordset;
    } catch (error) {
      console.log(error);
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // approvalData: { sq_basic_sno, quotation_ref_no, approved_by, comments, approval_stages, action }
  async approvePo(approvalData) {
    try {
      console.log("approvalData", approvalData);
      const request = mssqlPool.request();
      request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(approvalData));
      const result = await request.execute(this.storedProcedureMap["approvePo"]);
      console.log("approvePo result", result.recordset);
      return result.recordset;
    } catch (error) {
      console.log(error);
      throw new Error(`Database error: ${error.message}`);
    }
  }
}

export default PORepository;
