// ServiceAgreement.service.js — routing tests covering both billing
// patterns the entity now supports (Fixed Recurring rate vs Variable
// Recurring ceiling+tolerance, sql/21_service_agreement_variable_recurring.sql).
// The billing-pattern branching itself lives in sp_nt_CreateServiceAgreement
// (SQL), so these tests only prove the Node layer passes each shape through
// unmangled — the SQL-level branch is covered by the integration test.
import { describe, it, expect, jest, beforeEach } from "@jest/globals";
import ServiceAgreementService from "../src/ServiceAgreement/services/ServiceAgreement.service.js";

describe("ServiceAgreementService — Fixed vs Variable Recurring payload shapes", () => {
  beforeEach(() => {
    jest.restoreAllMocks();
  });

  it("passes a Fixed Recurring payload (rate_amount, no ceiling) through unchanged", async () => {
    const payload = {
      com_sno: 1, div_sno: 1, brn_sno: 1, dept_sno: 1,
      service_sno: 9, // Office Rent
      rate_amount: 100000,
      period_start_date: "2026-01-01",
      period_end_date: "2026-12-31",
      agreement_doc_url: "https://example/agreement.pdf",
      created_by: "KTM1148",
    };
    const spy = jest
      .spyOn(ServiceAgreementService.repo, "createServiceAgreement")
      .mockResolvedValue([{ agreement_sno: 1, agreement_no: "AGR-2026-0001", result: "SUCCESS" }]);

    await ServiceAgreementService.createServiceAgreement(payload);

    expect(spy).toHaveBeenCalledWith(payload);
    expect(spy.mock.calls[0][0].ceiling_amount).toBeUndefined();
  });

  it("passes a Variable Recurring payload (ceiling_amount + variance_tolerance_pct, no rate) through unchanged", async () => {
    const payload = {
      com_sno: 1, div_sno: 1, brn_sno: 1, dept_sno: 1,
      service_sno: 10, // AWS Cloud Hosting
      ceiling_amount: 50000,
      variance_tolerance_pct: 10,
      period_start_date: "2026-01-01",
      period_end_date: "2026-12-31",
      agreement_doc_url: "https://example/aws-agreement.pdf",
      created_by: "KTM1148",
    };
    const spy = jest
      .spyOn(ServiceAgreementService.repo, "createServiceAgreement")
      .mockResolvedValue([{ agreement_sno: 2, agreement_no: "AGR-2026-0002", result: "SUCCESS" }]);

    await ServiceAgreementService.createServiceAgreement(payload);

    expect(spy).toHaveBeenCalledWith(payload);
    expect(spy.mock.calls[0][0].rate_amount).toBeUndefined();
  });

  it("getActiveServiceAgreement forwards the exact org+service scope used for PR auto-fill", async () => {
    const scope = { com_sno: 1, div_sno: 1, brn_sno: 1, dept_sno: 1, service_sno: 9 };
    const spy = jest
      .spyOn(ServiceAgreementService.repo, "getActiveServiceAgreement")
      .mockResolvedValue([]);

    await ServiceAgreementService.getActiveServiceAgreement(scope);

    expect(spy).toHaveBeenCalledWith(scope);
  });
});
