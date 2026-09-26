import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

class PRTrackingRepository {
  async getMyPRTracking(ecno) {
    try {
      const request = mssqlPool.request();
      request.input("ecno", mssql.VarChar(20), ecno);
      const result = await request.execute("sp_nt_GetMyPRTracking");
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async getOrgPRTracking({ com_sno, div_sno, brn_sno, dept_sno }) {
    try {
      const request = mssqlPool.request();
      request.input("com_sno", mssql.Int, com_sno);
      request.input("div_sno", mssql.Int, div_sno ?? null);
      request.input("brn_sno", mssql.Int, brn_sno ?? null);
      request.input("dept_sno", mssql.Int, dept_sno ?? null);
      const result = await request.execute("sp_nt_GetOrgPRTracking");
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // Multiple result sets: PR header, quotation, quotation history, PO,
  // PO history, dispatch, dispatch delivery, gate entry, GRN, GRN history,
  // inventory movements, PR stage chain, PR approval history, quotation stage
  // chains, PR core row — see sql/96_pr_tracking_po_approval_and_names.sql for the
  // exact order (the service destructures by position).
  async getPRTrackingTimeline(pr_no) {
    try {
      const request = mssqlPool.request();
      request.input("pr_no", mssql.VarChar(30), pr_no);
      const result = await request.execute("sp_nt_GetPRTrackingTimeline");
      return result.recordsets;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async getPrNoByPoBasicSno(po_basic_sno) {
    try {
      const request = mssqlPool.request();
      request.input("po_basic_sno", mssql.Int, po_basic_sno);
      const result = await request.execute("sp_nt_GetPrNoByPoBasicSno");
      return result.recordset[0]?.pr_no ?? null;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async hasScreenPermission(ecno, screen_comp, permission_id) {
    try {
      const request = mssqlPool.request();
      request.input("ecno", mssql.VarChar(20), ecno);
      request.input("screen_comp", mssql.VarChar(100), screen_comp);
      request.input("permission_id", mssql.Int, permission_id);
      const result = await request.execute("sp_nt_HasScreenPermission");
      return !!result.recordset[0]?.has_permission;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }
}

export default PRTrackingRepository;
