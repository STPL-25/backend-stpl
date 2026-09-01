// PR.service.js — routing/plumbing tests for the mixed Product+Service PR
// flow. PRService.PRRepository is a plain instance property (not late-bound
// via DI), so mocking it is a direct monkey-patch of its methods rather than
// jest.unstable_mockModule — same low-ceremony approach as this repo's only
// existing test file (middleware.test.js), which mocks Redis directly rather
// than the DB layer.
import { describe, it, expect, jest, beforeEach } from "@jest/globals";
import PRService from "../src/PR/services/PR.service.js";

describe("PRService — mixed Product+Service PR routing", () => {
  beforeEach(() => {
    jest.restoreAllMocks();
  });

  it("createPrRecords passes the payload straight through to the repository, untouched", async () => {
    const payload = {
      basicInfo: {
        com_sno: 1, div_sno: 1, brn_sno: 1, dept_sno: 1,
        req_date: "2026-08-21", required_date: "2026-08-28",
        requisition_type: "civil_works",
      },
      items: [
        { item_type: "product", prod_sno: 5, unit_sno: 3, qty: 2 },
        { item_type: "service", service_sno: 10, qty: 1 },
      ],
    };
    const fakeResult = { recordset: [{ Message: "ok" }], pr_no: "PR26-27-0001" };
    const spy = jest
      .spyOn(PRService.PRRepository, "createPrRecords")
      .mockResolvedValue(fakeResult);

    const result = await PRService.createPrRecords(payload);

    expect(spy).toHaveBeenCalledWith(payload);
    // category (requisition_type) is not stripped/renamed before hitting the
    // repository — the mapping to the persisted `category` enum happens
    // entirely inside usp_InsertPurchaseRequest v4, not in this layer.
    expect(spy.mock.calls[0][0].basicInfo.requisition_type).toBe("civil_works");
    expect(result).toBe(fakeResult);
  });

  it("getPrLineRoutingStatus forwards pr_basic_sno to the repository and returns its result verbatim", async () => {
    const fakeLines = [
      { pr_item_sno: 1, item_type: "product", po_basic_sno: null, grn_summary: null },
      { pr_item_sno: 2, item_type: "service", po_basic_sno: 40, service_entry_summary: [] },
    ];
    const spy = jest
      .spyOn(PRService.PRRepository, "getPrLineRoutingStatus")
      .mockResolvedValue(fakeLines);

    const result = await PRService.getPrLineRoutingStatus(19);

    expect(spy).toHaveBeenCalledWith(19);
    expect(result).toEqual(fakeLines);
  });

  it("approvePr forwards the full approval envelope (pr_no, approver, action, stages) unchanged", async () => {
    const approvalData = {
      pr_no: "PR26-27-0001",
      approved_by: "KTM1148",
      comments: "",
      approval_stages: [{ approver_ecno: "KTM1148" }],
      action: "approve",
    };
    const spy = jest
      .spyOn(PRService.PRRepository, "approvePr")
      .mockResolvedValue([{ result: "SUCCESS" }]);

    await PRService.approvePr(approvalData);

    expect(spy).toHaveBeenCalledWith(approvalData);
  });
});
