import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

// The loan procs (sql/89) raise their own user-facing messages with THROW numbers
// in the 58xxx range ("The payment date must be after 01 Jan 2026 ..."). Those are
// validation outcomes, not database failures, so they are passed on verbatim with a
// 400 status instead of being wrapped as "Database error: ...".
function toApiError(error) {
  const number = error?.number ?? error?.originalError?.info?.number;
  if (Number.isInteger(number) && number >= 58000 && number < 59000) {
    const validation = new Error(error.message);
    validation.status = 400;
    return validation;
  }
  return new Error(`Database error: ${error.message}`);
}

class LoanVoucherRepository {
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

  getLoanAccounts(filters = {}) {
    return this.executeJsonProcedure("sp_nt_GetLoanAccounts", filters);
  }

  getLoanDetail(agreement_sno) {
    return this.executeJsonProcedure("sp_nt_GetLoanDetail", { agreement_sno });
  }

  previewLoanInterest(payload) {
    return this.executeJsonProcedure("sp_nt_PreviewLoanInterest", payload);
  }

  addLoanRatePeriod(payload) {
    return this.executeJsonProcedure("sp_nt_AddLoanRatePeriod", payload);
  }

  deleteLoanRatePeriod(payload) {
    return this.executeJsonProcedure("sp_nt_DeleteLoanRatePeriod", payload);
  }

  addLoanPrincipalTxn(payload) {
    return this.executeJsonProcedure("sp_nt_AddLoanPrincipalTxn", payload);
  }

  deleteLoanPrincipalTxn(payload) {
    return this.executeJsonProcedure("sp_nt_DeleteLoanPrincipalTxn", payload);
  }

  createBankPaymentVoucher(payload) {
    return this.executeJsonProcedure("sp_nt_CreateBankPaymentVoucher", payload);
  }

  getBankPaymentVouchers(filters = {}) {
    return this.executeJsonProcedure("sp_nt_GetBankPaymentVouchers", filters);
  }

  getBankPaymentVoucher(voucher_sno) {
    return this.executeJsonProcedure("sp_nt_GetBankPaymentVoucher", { voucher_sno });
  }

  approveBankPaymentVoucher(payload) {
    return this.executeJsonProcedure("sp_nt_ApproveBankPaymentVoucher", payload);
  }

  markBankPaymentVoucherPaid(payload) {
    return this.executeJsonProcedure("sp_nt_MarkBankPaymentVoucherPaid", payload);
  }

  // Pending vouchers for the logged-in approver.
  async getBankPaymentVouchersForApproval(ecno) {
    try {
      const request = mssqlPool.request();
      request.input("Ecno", mssql.VarChar(50), ecno);
      const result = await request.execute("sp_nt_GetBankPaymentVouchersForApproval");
      return result.recordset;
    } catch (error) {
      throw toApiError(error);
    }
  }
}

export default LoanVoucherRepository;
