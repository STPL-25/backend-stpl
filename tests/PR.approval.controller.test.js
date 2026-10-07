// PRController — conditional approval endpoints (sql/99). The stored procedure holds the real
// rules (covered by a transactional dry run); these tests pin the HTTP layer around it:
// what is accepted, what is forwarded to the engine, and how its errors reach the client.
import { describe, it, expect, jest, beforeEach } from "@jest/globals";
import PRController from "../src/PR/controllers/PR.controller.js";
import PRService from "../src/PR/services/PR.service.js";
import { mockRes } from "./setup.js";

const req = (body = {}, extra = {}) => ({
  user_ecno: "KKV100",
  redisClient: null,
  io: null,
  body,
  query: {},
  ...extra,
});

const success = [{ result: "SUCCESS", pr_no: "PR1", next_approver: "KKV107", request_mode: "NORMAL", pr_basic_sno: 1 }];

describe("PRController.approvePr", () => {
  let approve;
  beforeEach(() => {
    jest.restoreAllMocks();
    approve = jest.spyOn(PRService, "approvePr").mockResolvedValue(success);
  });

  it("sends the engine only the intent — never a client-supplied stage list — and the session ecno as approver", async () => {
    const res = mockRes();
    await PRController.approvePr(
      req({
        pr_no: "PR1", action: "forward", comments: "escalate", target_seq: 2,
        approval_stages: [{ approver_ecno: "EVIL" }], approved_by: "SPOOFED", ecno: "SPOOFED",
      }),
      res
    );

    expect(approve).toHaveBeenCalledTimes(1);
    expect(approve).toHaveBeenCalledWith({
      pr_no: "PR1", approved_by: "KKV100", comments: "escalate", action: "forward",
      target_seq: 2, target: undefined, edits: undefined,
    });
    expect(approve.mock.calls[0][0]).not.toHaveProperty("approval_stages");
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ success: true, data: success }));
  });

  it.each(["approve", "reject", "forward", "send_back", "edit", "resubmit"])("accepts action %s", async (action) => {
    const res = mockRes();
    await PRController.approvePr(req({ pr_no: "PR1", action, comments: "because" }), res);
    expect(res.status).not.toHaveBeenCalled();
    expect(approve).toHaveBeenCalled();
  });

  it("rejects an unknown action with 400 before touching the database", async () => {
    const res = mockRes();
    await PRController.approvePr(req({ pr_no: "PR1", action: "delete" }), res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(approve).not.toHaveBeenCalled();
  });

  it.each(["reject", "send_back", "edit"])("requires a comment for %s", async (action) => {
    const res = mockRes();
    await PRController.approvePr(req({ pr_no: "PR1", action, comments: "   " }), res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(approve).not.toHaveBeenCalled();
  });

  it("does not require a comment to approve, forward or resubmit", async () => {
    for (const action of ["approve", "forward", "resubmit"]) {
      const res = mockRes();
      await PRController.approvePr(req({ pr_no: "PR1", action }), res);
      expect(res.status).not.toHaveBeenCalled();
    }
  });

  it("needs a session, a pr_no and an action", async () => {
    let res = mockRes();
    await PRController.approvePr(req({ pr_no: "PR1", action: "approve" }, { user_ecno: undefined }), res);
    expect(res.status).toHaveBeenCalledWith(401);
    res = mockRes();
    await PRController.approvePr(req({ action: "approve" }), res);
    expect(res.status).toHaveBeenCalledWith(400);
    res = mockRes();
    await PRController.approvePr(req({ pr_no: "PR1" }), res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(approve).not.toHaveBeenCalled();
  });

  it("passes an engine rule error to the user as a 400 with its own message", async () => {
    const err = new Error("You are the alternate approver for this stage. You can act once it has been pending for 24 hours");
    err.userFacing = true;
    approve.mockRejectedValue(err);
    const res = mockRes();
    await PRController.approvePr(req({ pr_no: "PR1", action: "approve" }), res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(res.json).toHaveBeenCalledWith({ success: false, error: err.message });
  });

  it("keeps a genuine database failure a 500", async () => {
    approve.mockRejectedValue(new Error("Database error: connection lost"));
    const res = mockRes();
    await PRController.approvePr(req({ pr_no: "PR1", action: "approve" }), res);
    expect(res.status).toHaveBeenCalledWith(500);
  });

  it("tells the open approval screens (all actions) and the PR's tracking room", async () => {
    const emit = jest.fn();
    const to = jest.fn().mockReturnValue({ emit });
    const res = mockRes();
    await PRController.approvePr(req({ pr_no: "PR1", action: "send_back", comments: "fix", target: "REQUESTER" }, { io: { to } }), res);

    expect(to).toHaveBeenCalledWith("pr:approval");
    expect(emit).toHaveBeenCalledWith("pr:approval:updated", { pr_no: "PR1", action: "send_back", approved_by: "KKV100" });
    expect(to).toHaveBeenCalledWith("pr:track:PR1");
    expect(emit).toHaveBeenCalledWith("pr:track:updated", expect.objectContaining({ pr_no: "PR1", stage: "PR Approval", status: "send_back" }));
  });

  it("labels a rejection in the tracking push", async () => {
    const emit = jest.fn();
    const res = mockRes();
    await PRController.approvePr(req({ pr_no: "PR1", action: "reject", comments: "no" }, { io: { to: () => ({ emit }) } }), res);
    expect(emit).toHaveBeenCalledWith("pr:track:updated", expect.objectContaining({ stage: "PR Rejected" }));
  });
});

describe("PRController.getApprovalContext", () => {
  beforeEach(() => jest.restoreAllMocks());

  it("shapes the six result sets the procedure returns", async () => {
    const sets = [[{ pr_no: "PR1", my_role: "PRIMARY" }], [{ seq: 0 }, { seq: 1 }], [{ seq: 1 }], [{ target_type: "REQUESTER" }], [{ log_id: 1 }], [{ field_key: "amount", field_label: "Amount (PR total)" }]];
    const spy = jest.spyOn(PRService, "getApprovalContext").mockResolvedValue(sets);
    const res = mockRes();
    await PRController.getApprovalContext(req({}, { query: { pr_no: "PR1" } }), res);

    expect(spy).toHaveBeenCalledWith("PR1", "KKV100");
    expect(res.json).toHaveBeenCalledWith({
      success: true,
      data: {
        summary: { pr_no: "PR1", my_role: "PRIMARY" },
        stages: [{ seq: 0 }, { seq: 1 }],
        forwardTargets: [{ seq: 1 }],
        sendBackTargets: [{ target_type: "REQUESTER" }],
        log: [{ log_id: 1 }],
        fields: [{ field_key: "amount", field_label: "Amount (PR total)" }],
      },
    });
  });

  it("needs a session and a pr_no; the caller is always the session user", async () => {
    const spy = jest.spyOn(PRService, "getApprovalContext").mockResolvedValue([[], [], [], [], [], []]);
    let res = mockRes();
    await PRController.getApprovalContext(req({}, { query: {}, user_ecno: undefined }), res);
    expect(res.status).toHaveBeenCalledWith(401);
    res = mockRes();
    await PRController.getApprovalContext(req({}, { query: {} }), res);
    expect(res.status).toHaveBeenCalledWith(400);
    res = mockRes();
    await PRController.getApprovalContext(req({}, { query: { pr_no: "PR1", ecno: "SPOOFED" } }), res);
    expect(spy).toHaveBeenCalledWith("PR1", "KKV100");
  });

  it("copes with an empty result (PR unknown to the engine)", async () => {
    jest.spyOn(PRService, "getApprovalContext").mockResolvedValue([[], undefined, undefined, undefined, undefined, undefined]);
    const res = mockRes();
    await PRController.getApprovalContext(req({}, { query: { pr_no: "PR1" } }), res);
    expect(res.json).toHaveBeenCalledWith({
      success: true,
      data: { summary: null, stages: [], forwardTargets: [], sendBackTargets: [], log: [], fields: [] },
    });
  });

  it("answers a business error with 400", async () => {
    const err = new Error("Purchase Request not found or inactive.");
    err.userFacing = true;
    jest.spyOn(PRService, "getApprovalContext").mockRejectedValue(err);
    const res = mockRes();
    await PRController.getApprovalContext(req({}, { query: { pr_no: "NOPE" } }), res);
    expect(res.status).toHaveBeenCalledWith(400);
  });
});
