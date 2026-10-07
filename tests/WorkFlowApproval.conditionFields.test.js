// GET /workflow_approval/getConditionFields — which values a stage condition can test for a workflow type.
// The registry lives in the database (approval_condition_field); this pins the HTTP layer around it.
import { describe, it, expect, jest, beforeEach } from "@jest/globals";
import WorkFlowApprovalController from "../src/WorkFlowApproval/controllers/WorkFlowApproval.controller.js";
import WorkFlowApprovalService from "../src/WorkFlowApproval/services/WorkFlowApproval.service.js";
import { mockRes } from "./setup.js";

const FIELDS = [
  { field_key: "amount", field_label: "Amount (PR total)", value_kind: "number", option_source: null, unit: "INR", help_text: null, sort_order: 1 },
  { field_key: "priority", field_label: "Priority", value_kind: "list", option_source: "PriorityMaster", unit: null, help_text: null, sort_order: 4 },
];

describe("WorkFlowApprovalController.getConditionFields", () => {
  let getFields;
  beforeEach(() => {
    jest.restoreAllMocks();
    getFields = jest.spyOn(WorkFlowApprovalService, "getConditionFields").mockResolvedValue(FIELDS);
  });

  it("returns the fields registered for the entity type", async () => {
    const res = mockRes();
    await WorkFlowApprovalController.getConditionFields({ query: { entity_type: "PurchaseRequisition" } }, res);
    expect(getFields).toHaveBeenCalledWith("PurchaseRequisition");
    expect(res.json).toHaveBeenCalledWith({ success: true, data: FIELDS });
  });

  it("an entity type with no registered fields is an empty list, not an error", async () => {
    getFields.mockResolvedValue([]);
    const res = mockRes();
    await WorkFlowApprovalController.getConditionFields({ query: { entity_type: "KYC" } }, res);
    expect(res.status).not.toHaveBeenCalled();
    expect(res.json).toHaveBeenCalledWith({ success: true, data: [] });
  });

  it("requires an entity_type", async () => {
    for (const query of [{}, { entity_type: "" }, { entity_type: "   " }]) {
      const res = mockRes();
      await WorkFlowApprovalController.getConditionFields({ query }, res);
      expect(res.status).toHaveBeenCalledWith(400);
    }
    expect(getFields).not.toHaveBeenCalled();
  });

  it("a failure to load is a 500 — never an empty list the screen would read as 'no conditions here'", async () => {
    getFields.mockRejectedValue(new Error("Database error [sp_nt_GetApprovalConditionFields]: Could not find stored procedure"));
    const res = mockRes();
    await WorkFlowApprovalController.getConditionFields({ query: { entity_type: "PurchaseRequisition" } }, res);
    expect(res.status).toHaveBeenCalledWith(500);
    expect(res.json).toHaveBeenCalledWith({ success: false, error: expect.stringContaining("Could not find stored procedure") });
  });
});
