// Approval routing (sql/124): request variant -> approval type. Pins the HTTP layer; the resolving lives in SQL.
import { describe, it, expect, jest, beforeEach } from "@jest/globals";
import WorkFlowApprovalController from "../src/WorkFlowApproval/controllers/WorkFlowApproval.controller.js";
import WorkFlowApprovalService from "../src/WorkFlowApproval/services/WorkFlowApproval.service.js";
import { mockRes } from "./setup.js";

describe("approval routing controller", () => {
  beforeEach(() => jest.restoreAllMocks());

  it("getApprovalRoutes parses the eligible approval types JSON of each row", async () => {
    jest.spyOn(WorkFlowApprovalService, "getApprovalRoutes").mockResolvedValue([
      { module_code: "ServiceAgreement", variant_code: "FIXED_RECURRING", eligible_entities: '[{"entity_code":"ServiceAgreement","entity_name":"Service Agreement"}]' },
      { module_code: "ServicePO", variant_code: "STATUTORY", eligible_entities: null },
    ]);
    const res = mockRes();
    await WorkFlowApprovalController.getApprovalRoutes({}, res);
    const rows = res.json.mock.calls[0][0].data;
    expect(rows[0].eligible_entities).toEqual([{ entity_code: "ServiceAgreement", entity_name: "Service Agreement" }]);
    expect(rows[1].eligible_entities).toEqual([]);
  });

  it("saveApprovalRoute needs module, variant and entity", async () => {
    const save = jest.spyOn(WorkFlowApprovalService, "saveApprovalRoute");
    const res = mockRes();
    await WorkFlowApprovalController.saveApprovalRoute({ body: { module_code: "ServiceAgreement" } }, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(save).not.toHaveBeenCalled();
  });

  it("saveApprovalRoute passes the caller and only an explicit force=true", async () => {
    const save = jest.spyOn(WorkFlowApprovalService, "saveApprovalRoute").mockResolvedValue([{ status: "NEEDS_CONFIRM", scopes_missing: 2 }]);
    const res = mockRes();
    await WorkFlowApprovalController.saveApprovalRoute({
      user_ecno: "E1", body: { module_code: "ServiceAgreement", variant_code: "FIXED_RECURRING", entity_code: "ServiceAgreement_FIXED_RECURRING", force: "true" },
    }, res);
    expect(save).toHaveBeenCalledWith({
      module_code: "ServiceAgreement", variant_code: "FIXED_RECURRING", entity_code: "ServiceAgreement_FIXED_RECURRING", force: false, modified_by: "E1",
    });
    expect(res.json).toHaveBeenCalledWith({ success: true, data: { status: "NEEDS_CONFIRM", scopes_missing: 2 } });
  });

  it("a database refusal comes back as 400 with its message", async () => {
    jest.spyOn(WorkFlowApprovalService, "saveApprovalRoute").mockRejectedValue(new Error("not available"));
    const res = mockRes();
    await WorkFlowApprovalController.saveApprovalRoute({ body: { module_code: "a", variant_code: "b", entity_code: "c" } }, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(res.json).toHaveBeenCalledWith({ success: false, error: "not available" });
  });
});
