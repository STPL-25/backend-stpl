// ServicePO.service.js — routing tests for PO consolidation, direct-issue
// notification side effect, and the new Variable-Recurring ceiling revision
// endpoint. Same monkey-patch-the-repository-instance approach as
// PR.service.test.js.
import { describe, it, expect, jest, beforeEach } from "@jest/globals";
import ServicePOService from "../src/ServicePO/services/ServicePO.service.js";

describe("ServicePOService — Variable-Recurring ceiling revision", () => {
  beforeEach(() => {
    jest.restoreAllMocks();
  });

  it("reviseServicePOCeiling forwards the revision payload to the repository verbatim", async () => {
    const payload = {
      po_basic_sno: 40,
      ceiling_amount: 60000,
      variance_tolerance_pct: 12,
      revised_by: "KTM1148",
      comments: "Quarterly review — usage trending up",
    };
    const fakeResult = [{ po_basic_sno: 40, ceiling_amount: 60000, result: "SUCCESS" }];
    const spy = jest
      .spyOn(ServicePOService.repo, "reviseServicePOCeiling")
      .mockResolvedValue(fakeResult);

    const result = await ServicePOService.reviseServicePOCeiling(payload);

    expect(spy).toHaveBeenCalledWith(payload);
    expect(result).toBe(fakeResult);
  });
});

describe("ServicePOService — direct-issue vendor notification", () => {
  beforeEach(() => {
    jest.restoreAllMocks();
  });

  it("fires the direct-issue email when the repository reports is_direct_issue=1", async () => {
    jest
      .spyOn(ServicePOService.repo, "createServicePO")
      .mockResolvedValue([{ po_basic_sno: 41, po_no: "SVO-2026-0001", is_direct_issue: 1 }]);
    const emailSpy = jest
      .spyOn(ServicePOService, "sendDirectIssuePOEmail")
      .mockResolvedValue(undefined);

    await ServicePOService.createServicePO({ vendor_sno: 7, items: [] });

    // Fire-and-forget: allow the microtask queue to run the .catch() chain.
    await new Promise((r) => setTimeout(r, 0));
    expect(emailSpy).toHaveBeenCalledWith(7, { po_basic_sno: 41, po_no: "SVO-2026-0001", is_direct_issue: 1 });
  });

  it("does NOT fire the direct-issue email for a normal workflow-routed PO", async () => {
    jest
      .spyOn(ServicePOService.repo, "createServicePO")
      .mockResolvedValue([{ po_basic_sno: 42, po_no: "SVO-2026-0002", is_direct_issue: 0 }]);
    const emailSpy = jest
      .spyOn(ServicePOService, "sendDirectIssuePOEmail")
      .mockResolvedValue(undefined);

    await ServicePOService.createServicePO({ vendor_sno: 7, items: [] });
    await new Promise((r) => setTimeout(r, 0));

    expect(emailSpy).not.toHaveBeenCalled();
  });
});
