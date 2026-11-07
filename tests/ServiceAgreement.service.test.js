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

// sql/157: a Statutory agreement's Statutory Payments block (tab, Fixed/Unfixed, payee) is merged into the list rows.
describe("ServiceAgreementService — Statutory due block", () => {
  beforeEach(() => {
    jest.restoreAllMocks();
  });

  const rows = [
    { agreement_sno: 1, service_type_code: "FIXED_RECURRING", vendors_json: "[]" },
    { agreement_sno: 2, service_type_code: "STATUTORY", vendors_json: null },
  ];

  it("adds statutory_due to the Statutory rows only", async () => {
    jest.spyOn(ServiceAgreementService.repo, "getServiceAgreements").mockResolvedValue(rows);
    jest.spyOn(ServiceAgreementService.repo, "getSignedDocs").mockResolvedValue([]);
    jest.spyOn(ServiceAgreementService.repo, "getStatutoryDues").mockResolvedValue([
      { agreement_sno: 2, kind: "OTHER", amount_type: "UNFIXED", payee_sno: 4, payee_name: "EPFO", waiting_count: 1 },
    ]);
    const out = await ServiceAgreementService.getServiceAgreements({});
    expect(out[0].statutory_due).toBeUndefined();
    expect(out[1].statutory_due).toEqual({ kind: "OTHER", amount_type: "UNFIXED", payee_sno: 4, payee_name: "EPFO", waiting_count: 1 });
  });

  it("does not ask for the block when there is no Statutory row", async () => {
    jest.spyOn(ServiceAgreementService.repo, "getServiceAgreements").mockResolvedValue([rows[0]]);
    jest.spyOn(ServiceAgreementService.repo, "getSignedDocs").mockResolvedValue([]);
    const dues = jest.spyOn(ServiceAgreementService.repo, "getStatutoryDues").mockResolvedValue([]);
    await ServiceAgreementService.getServiceAgreements({});
    expect(dues).not.toHaveBeenCalled();
  });

  it("still lists the agreements when the block cannot be read (sql/157 not applied yet)", async () => {
    jest.spyOn(ServiceAgreementService.repo, "getServiceAgreements").mockResolvedValue(rows);
    jest.spyOn(ServiceAgreementService.repo, "getSignedDocs").mockResolvedValue([]);
    jest.spyOn(ServiceAgreementService.repo, "getStatutoryDues").mockRejectedValue(new Error("Could not find stored procedure"));
    jest.spyOn(console, "error").mockImplementation(() => {});
    const out = await ServiceAgreementService.getServiceAgreements({});
    expect(out).toHaveLength(2);
    expect(out[1].statutory_due).toBeUndefined();
  });
});
