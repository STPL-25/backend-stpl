import LoanVoucherRepository from "../repository/LoanVoucher.repository.js";

// The detail / preview SPs return the frozen calculation and history as JSON text
// columns built with FOR JSON — parsed once here so the frontend gets real arrays.
// (FOR JSON leaves out null keys, so an absent field simply means "none".)
function parseJson(value, fallback = null) {
  if (value === null || value === undefined || value === "") return fallback;
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function withParsedVoucherColumns(row) {
  const {
    segments_json, next_segments_json, history_json, beneficiary_json, stage_order_json, ...rest
  } = row;
  return {
    ...rest,
    ...(segments_json !== undefined ? { segments: parseJson(segments_json, []) } : {}),
    ...(next_segments_json !== undefined ? { next_segments: parseJson(next_segments_json, []) } : {}),
    ...(history_json !== undefined ? { history: parseJson(history_json, []) } : {}),
    ...(beneficiary_json !== undefined ? { beneficiary: parseJson(beneficiary_json) } : {}),
    // Kept as the raw text the approval screens already know how to read (parseStages).
    ...(stage_order_json !== undefined ? { stage_order_json } : {}),
  };
}

class LoanVoucherService {
  static repo = new LoanVoucherRepository();

  static getLoanAccounts(filters) {
    return this.repo.getLoanAccounts(filters);
  }

  static async getLoanDetail(agreement_sno) {
    const rows = await this.repo.getLoanDetail(agreement_sno);
    const row = rows?.[0];
    if (!row) return null;
    const { rates_json, txns_json, vouchers_json, beneficiary_json, ...header } = row;
    return {
      ...header,
      rates: parseJson(rates_json, []),
      txns: parseJson(txns_json, []),
      vouchers: parseJson(vouchers_json, []),
      beneficiary: parseJson(beneficiary_json),
    };
  }

  static async previewLoanInterest(payload) {
    const rows = await this.repo.previewLoanInterest(payload);
    return rows.map(withParsedVoucherColumns);
  }

  static addLoanRatePeriod(payload) {
    return this.repo.addLoanRatePeriod(payload);
  }

  static deleteLoanRatePeriod(payload) {
    return this.repo.deleteLoanRatePeriod(payload);
  }

  static addLoanPrincipalTxn(payload) {
    return this.repo.addLoanPrincipalTxn(payload);
  }

  static deleteLoanPrincipalTxn(payload) {
    return this.repo.deleteLoanPrincipalTxn(payload);
  }

  static createBankPaymentVoucher(payload) {
    return this.repo.createBankPaymentVoucher(payload);
  }

  static getBankPaymentVouchers(filters) {
    return this.repo.getBankPaymentVouchers(filters);
  }

  static async getBankPaymentVoucher(voucher_sno) {
    const rows = await this.repo.getBankPaymentVoucher(voucher_sno);
    return rows?.[0] ? withParsedVoucherColumns(rows[0]) : null;
  }

  static approveBankPaymentVoucher(payload) {
    return this.repo.approveBankPaymentVoucher(payload);
  }

  static markBankPaymentVoucherPaid(payload) {
    return this.repo.markBankPaymentVoucherPaid(payload);
  }

  static async getBankPaymentVouchersForApproval(ecno) {
    const rows = await this.repo.getBankPaymentVouchersForApproval(ecno);
    return rows.map(withParsedVoucherColumns);
  }
}

export default LoanVoucherService;
