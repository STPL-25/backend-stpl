import LoanVoucherService from "../services/LoanVoucher.service.js";

const ROOM = "loan_voucher:approval";
const EVENT = "loan_voucher:approval:updated";

// Validation outcomes from the loan procs carry status 400 (see the repository);
// everything else is a 500.
function fail(res, error, context) {
  if (!error.status) console.error(`Error in ${context}:`, error);
  res.status(error.status || 500).json({ success: false, error: error.message });
}

const toId = (v) => {
  const n = Number(v);
  return Number.isInteger(n) && n > 0 ? n : null;
};

class LoanVoucherController {
  // ── Loans in process ────────────────────────────────────────────────────
  static async getLoanAccounts(req, res) {
    try {
      const { com_sno, div_sno, brn_sno, dept_sno } = req.query;
      const data = await LoanVoucherService.getLoanAccounts({ com_sno, div_sno, brn_sno, dept_sno });
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error, "getLoanAccounts");
    }
  }

  static async getLoanDetail(req, res) {
    try {
      const agreement_sno = toId(req.query.agreement_sno);
      if (!agreement_sno) return res.status(400).json({ success: false, error: "agreement_sno is required" });
      const data = await LoanVoucherService.getLoanDetail(agreement_sno);
      if (!data) return res.status(404).json({ success: false, error: "Loan not found" });
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error, "getLoanDetail");
    }
  }

  // What a voucher would look like for a payment date (default: the next scheduled
  // interest date) and an optional principal repayment. Read-only.
  static async previewLoanInterest(req, res) {
    try {
      const agreement_sno = toId(req.query.agreement_sno);
      if (!agreement_sno) return res.status(400).json({ success: false, error: "agreement_sno is required" });
      const { payment_date, principal_repayment } = req.query;
      const data = await LoanVoucherService.previewLoanInterest({
        agreement_sno,
        payment_date: payment_date || undefined,
        principal_repayment: principal_repayment ? Number(principal_repayment) : undefined,
      });
      res.json({ success: true, data: data[0] ?? null });
    } catch (error) {
      fail(res, error, "previewLoanInterest");
    }
  }

  // ── Rate history + principal movements ──────────────────────────────────
  static async addLoanRatePeriod(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const { agreement_sno, effective_from, benchmark_rate_pct, interest_rate_pct, remarks } = req.body;
      if (!toId(agreement_sno) || !effective_from) {
        return res.status(400).json({ success: false, error: "agreement_sno and effective_from are required" });
      }
      const data = await LoanVoucherService.addLoanRatePeriod({
        agreement_sno, effective_from, benchmark_rate_pct, interest_rate_pct, remarks,
        // entered_by is always the authenticated session's ecno, never client-supplied
        entered_by: ecno,
      });
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error, "addLoanRatePeriod");
    }
  }

  static async deleteLoanRatePeriod(req, res) {
    try {
      const rate_period_sno = toId(req.body.rate_period_sno);
      if (!rate_period_sno) return res.status(400).json({ success: false, error: "rate_period_sno is required" });
      const data = await LoanVoucherService.deleteLoanRatePeriod({ rate_period_sno });
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error, "deleteLoanRatePeriod");
    }
  }

  static async addLoanPrincipalTxn(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const { agreement_sno, txn_type, txn_date, amount, remarks } = req.body;
      if (!toId(agreement_sno) || !txn_type || !txn_date || !amount) {
        return res.status(400).json({ success: false, error: "agreement_sno, txn_type, txn_date and amount are required" });
      }
      const data = await LoanVoucherService.addLoanPrincipalTxn({
        agreement_sno, txn_type, txn_date, amount: Number(amount), remarks, entered_by: ecno,
      });
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error, "addLoanPrincipalTxn");
    }
  }

  static async deleteLoanPrincipalTxn(req, res) {
    try {
      const txn_sno = toId(req.body.txn_sno);
      if (!txn_sno) return res.status(400).json({ success: false, error: "txn_sno is required" });
      const data = await LoanVoucherService.deleteLoanPrincipalTxn({ txn_sno });
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error, "deleteLoanPrincipalTxn");
    }
  }

  // ── Bank payment vouchers ───────────────────────────────────────────────
  static async createBankPaymentVoucher(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const { agreement_sno, payment_date, principal_repayment, remarks } = req.body;
      if (!toId(agreement_sno)) return res.status(400).json({ success: false, error: "agreement_sno is required" });

      const data = await LoanVoucherService.createBankPaymentVoucher({
        agreement_sno, payment_date: payment_date || undefined,
        principal_repayment: principal_repayment ? Number(principal_repayment) : 0,
        remarks, created_by: ecno,
      });

      req.io.to(ROOM).emit(EVENT, { voucher_sno: data?.[0]?.voucher_sno, action: "created" });
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error, "createBankPaymentVoucher");
    }
  }

  static async getBankPaymentVouchers(req, res) {
    try {
      const { agreement_sno, status, com_sno, div_sno, brn_sno, dept_sno } = req.query;
      const data = await LoanVoucherService.getBankPaymentVouchers({ agreement_sno, status, com_sno, div_sno, brn_sno, dept_sno });
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error, "getBankPaymentVouchers");
    }
  }

  static async getBankPaymentVoucher(req, res) {
    try {
      const voucher_sno = toId(req.query.voucher_sno);
      if (!voucher_sno) return res.status(400).json({ success: false, error: "voucher_sno is required" });
      const data = await LoanVoucherService.getBankPaymentVoucher(voucher_sno);
      if (!data) return res.status(404).json({ success: false, error: "Voucher not found" });
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error, "getBankPaymentVoucher");
    }
  }

  static async getBankPaymentVouchersForApproval(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const data = await LoanVoucherService.getBankPaymentVouchersForApproval(ecno);
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error, "getBankPaymentVouchersForApproval");
    }
  }

  static async approveBankPaymentVoucher(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const { voucher_sno, action, comments } = req.body;
      if (!toId(voucher_sno) || !action) {
        return res.status(400).json({ success: false, error: "voucher_sno and action are required" });
      }
      if (action === "reject" && !comments?.trim()) {
        return res.status(400).json({ success: false, error: "comments are required when rejecting" });
      }

      // The stage list is read from the workflow inside the procedure, and only the
      // voucher's CURRENT approver may act — approved_by comes from the session,
      // never the request body.
      const data = await LoanVoucherService.approveBankPaymentVoucher({
        voucher_sno, action, comments: comments || "", approved_by: ecno,
      });

      req.io.to(ROOM).emit(EVENT, { voucher_sno, action, approved_by: ecno });
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error, "approveBankPaymentVoucher");
    }
  }

  static async markBankPaymentVoucherPaid(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const { voucher_sno, paid_on, payment_mode, payment_ref_no, paid_from_bank, remarks } = req.body;
      if (!toId(voucher_sno) || !paid_on || !payment_mode) {
        return res.status(400).json({ success: false, error: "voucher_sno, paid_on and payment_mode are required" });
      }
      const data = await LoanVoucherService.markBankPaymentVoucherPaid({
        voucher_sno, paid_on, payment_mode, payment_ref_no, paid_from_bank, remarks, paid_by: ecno,
      });

      req.io.to(ROOM).emit(EVENT, { voucher_sno, action: "paid", approved_by: ecno });
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error, "markBankPaymentVoucherPaid");
    }
  }
}

export default LoanVoucherController;
