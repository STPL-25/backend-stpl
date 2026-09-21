import express from "express";
import LoanVoucherController from "../controllers/LoanVoucher.controller.js";

const LoanVoucherRouter = express.Router();

// Loans in process + one loan's history
LoanVoucherRouter.get("/getLoanAccounts", LoanVoucherController.getLoanAccounts);
LoanVoucherRouter.get("/getLoanDetail", LoanVoucherController.getLoanDetail);
LoanVoucherRouter.get("/previewLoanInterest", LoanVoucherController.previewLoanInterest);

// Rate history + principal movements
LoanVoucherRouter.post("/addLoanRatePeriod", LoanVoucherController.addLoanRatePeriod);
LoanVoucherRouter.post("/deleteLoanRatePeriod", LoanVoucherController.deleteLoanRatePeriod);
LoanVoucherRouter.post("/addLoanPrincipalTxn", LoanVoucherController.addLoanPrincipalTxn);
LoanVoucherRouter.post("/deleteLoanPrincipalTxn", LoanVoucherController.deleteLoanPrincipalTxn);

// Bank payment vouchers
LoanVoucherRouter.post("/createBankPaymentVoucher", LoanVoucherController.createBankPaymentVoucher);
LoanVoucherRouter.get("/getBankPaymentVouchers", LoanVoucherController.getBankPaymentVouchers);
LoanVoucherRouter.get("/getBankPaymentVoucher", LoanVoucherController.getBankPaymentVoucher);
LoanVoucherRouter.get("/getBankPaymentVouchersForApproval", LoanVoucherController.getBankPaymentVouchersForApproval);
LoanVoucherRouter.post("/approveBankPaymentVoucher", LoanVoucherController.approveBankPaymentVoucher);
LoanVoucherRouter.post("/markBankPaymentVoucherPaid", LoanVoucherController.markBankPaymentVoucherPaid);

export default LoanVoucherRouter;
