// KYCControllers - supplier KYC change requests (grn sql/93). The stored procedures hold the real rules (checked against the database in a
// rolled-back transaction: grn-service/sql/_verify_93.mjs); these tests pin the HTTP layer around them: the approver is always the session's
// ecno, what is accepted, how the procedure's messages reach the client, and who is told what after a decision.
import { describe, it, expect, jest, beforeEach } from "@jest/globals";

const KYCServices = {
  getKycChangeApprovals: jest.fn(),
  actKycChange: jest.fn(),
};
const createInAppNotification = jest.fn(async () => ({ sent: true }));
const notifySupplier = jest.fn(async () => ({ sent: true }));
const invalidateCache = jest.fn(async () => {});

jest.unstable_mockModule("../src/Kyc/services/Kyc.service.js", () => ({ default: KYCServices }));
jest.unstable_mockModule("../src/Utils/Notify/notifyClient.js", () => ({ createInAppNotification, notifySupplier }));
jest.unstable_mockModule("../src/Middleware/redisCache.js", () => ({ invalidateCache, cacheMiddleware: () => (_r, _s, n) => n() }));
jest.unstable_mockModule("../src/Middleware/payloadCrypto.js", () => ({ decryptFormPayload: (x) => x }));
jest.unstable_mockModule("../src/Utils/ImagesUpload/ImgUpload.js", () => ({ ftpUploader: {}, upload: {} }));
jest.unstable_mockModule("../src/KycVerification/KycVerification.service.js", () => ({ default: {} }));
jest.unstable_mockModule("../src/Masters/Services/CommonMasterServices.js", () => ({ default: {} }));

const { default: KYCControllers } = await import("../src/Kyc/controllers/Kyc.controller.js");

const mockRes = () => {
  const res = {};
  res.status = jest.fn(() => res);
  res.json = jest.fn(() => res);
  return res;
};
const req = (body = {}, extra = {}) => ({ user_ecno: "ED001", redisClient: null, io: { to: () => ({ emit: jest.fn() }) }, body, query: {}, ...extra });
const tick = () => new Promise((resolve) => setImmediate(resolve));

beforeEach(() => {
  jest.clearAllMocks();
  KYCServices.getKycChangeApprovals.mockReset();
  KYCServices.actKycChange.mockReset();
});

describe("getKycChangeRequests", () => {
  it("lists the requests for the SESSION's approver", async () => {
    KYCServices.getKycChangeApprovals.mockResolvedValue({ waiting: [{ kyc_modified_sno: 1 }], history: [] });
    const res = mockRes();
    await KYCControllers.getKycChangeRequests(req({}, { user_ecno: "ED001" }), res);
    expect(KYCServices.getKycChangeApprovals).toHaveBeenCalledWith("ED001");
    expect(res.json).toHaveBeenCalledWith({ success: true, data: { waiting: [{ kyc_modified_sno: 1 }], history: [] }, count: 1 });
  });

  it("401 without a signed-in approver", async () => {
    const res = mockRes();
    await KYCControllers.getKycChangeRequests(req({}, { user_ecno: undefined }), res);
    expect(res.status).toHaveBeenCalledWith(401);
    expect(KYCServices.getKycChangeApprovals).not.toHaveBeenCalled();
  });

  it("500 for a database failure, 400 for a message written for the user", async () => {
    KYCServices.getKycChangeApprovals.mockRejectedValueOnce(new Error("Database error: boom"));
    const a = mockRes();
    await KYCControllers.getKycChangeRequests(req(), a);
    expect(a.status).toHaveBeenCalledWith(500);

    KYCServices.getKycChangeApprovals.mockRejectedValueOnce(Object.assign(new Error("The approver is missing."), { userFacing: true }));
    const b = mockRes();
    await KYCControllers.getKycChangeRequests(req(), b);
    expect(b.status).toHaveBeenCalledWith(400);
  });
});

describe("actKycChangeRequest", () => {
  const stillWaiting = { kyc_modified_sno: 9, kyc_basic_info_sno: 55, version_no: 2, status: "P", stage_no: 2, stage_total: 2, next_approver_ecno: "KTM1148", next_stage_name: "GM", supp_code: "SUP55", company_name: "ACME" };
  const applied = { ...stillWaiting, status: "A", stage_no: 2, next_approver_ecno: null, next_stage_name: null };
  const rejected = { ...stillWaiting, status: "R", next_approver_ecno: null, next_stage_name: null, decision_note: "Letter is not signed" };

  it("passes only the intent to the procedure: the approver is the session's, never the body's", async () => {
    KYCServices.actKycChange.mockResolvedValue(stillWaiting);
    const res = mockRes();
    await KYCControllers.actKycChangeRequest(req({ kyc_modified_sno: "9", action: "approve", note: " ok ", ecno: "SPOOFED", approver_ecno: "SPOOFED" }), res);
    expect(KYCServices.actKycChange).toHaveBeenCalledWith({ kyc_modified_sno: 9, ecno: "ED001", action: "approve", note: "ok" });
    expect(res.status).not.toHaveBeenCalled();
  });

  it("validates the request before the procedure is called", async () => {
    const cases = [
      [{ action: "approve" }, /kyc_modified_sno/],
      [{ kyc_modified_sno: 9, action: "forward" }, /approve' or 'reject/],
      [{ kyc_modified_sno: 9, action: "reject", note: "   " }, /why the change is rejected/],
    ];
    for (const [body, pattern] of cases) {
      const res = mockRes();
      await KYCControllers.actKycChangeRequest(req(body), res);
      expect(res.status).toHaveBeenCalledWith(400);
      expect(res.json.mock.calls[0][0].error).toMatch(pattern);
    }
    const none = mockRes();
    await KYCControllers.actKycChangeRequest(req({ kyc_modified_sno: 9, action: "approve" }, { user_ecno: undefined }), none);
    expect(none.status).toHaveBeenCalledWith(401);
    expect(KYCServices.actKycChange).not.toHaveBeenCalled();
  });

  it("approved but not the last stage: tells the NEXT approver, not the supplier", async () => {
    KYCServices.actKycChange.mockResolvedValue(stillWaiting);
    const res = mockRes();
    await KYCControllers.actKycChangeRequest(req({ kyc_modified_sno: 9, action: "approve" }), res);
    expect(res.json.mock.calls[0][0].message).toMatch(/waiting for the next approver \(stage 2 of 2\)/);
    await tick();
    expect(createInAppNotification).toHaveBeenCalledTimes(1);
    expect(createInAppNotification.mock.calls[0][0]).toMatchObject({ ecno: "KTM1148", data: { kind: "supplier_kyc_change_pending", screen: "KYCApprovalScreen" } });
    expect(notifySupplier).not.toHaveBeenCalled();
    expect(invalidateCache).not.toHaveBeenCalled();
  });

  it("last stage approved: the change is live, so the supplier is told and the KYC cache is cleared", async () => {
    KYCServices.actKycChange.mockResolvedValue(applied);
    const res = mockRes();
    await KYCControllers.actKycChangeRequest(req({ kyc_modified_sno: 9, action: "approve" }), res);
    expect(res.json.mock.calls[0][0].message).toMatch(/now live/);
    await tick();
    expect(invalidateCache).toHaveBeenCalledWith(null, "kyc:list", "kyc:pending");
    expect(notifySupplier).toHaveBeenCalledTimes(1);
    expect(notifySupplier.mock.calls[0][0]).toMatchObject({ supplier_sno: 55, type: "success", data: { view: "kyc", status: "A" } });
    expect(createInAppNotification).not.toHaveBeenCalled();
  });

  it("rejected: the supplier is told why, and the KYC cache is left alone", async () => {
    KYCServices.actKycChange.mockResolvedValue(rejected);
    const res = mockRes();
    await KYCControllers.actKycChangeRequest(req({ kyc_modified_sno: 9, action: "reject", note: "Letter is not signed" }), res);
    expect(KYCServices.actKycChange).toHaveBeenCalledWith({ kyc_modified_sno: 9, ecno: "ED001", action: "reject", note: "Letter is not signed" });
    await tick();
    expect(notifySupplier).toHaveBeenCalledTimes(1);
    const n = notifySupplier.mock.calls[0][0];
    expect(n).toMatchObject({ supplier_sno: 55, type: "warning", data: { view: "kyc", status: "R" } });
    expect(n.message).toMatch(/Letter is not signed/);
    expect(invalidateCache).not.toHaveBeenCalled();
  });

  it("the procedure's message comes back as written (400), nobody is told; other failures are 500", async () => {
    KYCServices.actKycChange.mockRejectedValueOnce(Object.assign(new Error("This request is not waiting for you."), { userFacing: true }));
    const a = mockRes();
    await KYCControllers.actKycChangeRequest(req({ kyc_modified_sno: 9, action: "approve" }), a);
    expect(a.status).toHaveBeenCalledWith(400);
    expect(a.json).toHaveBeenCalledWith({ success: false, error: "This request is not waiting for you." });

    KYCServices.actKycChange.mockRejectedValueOnce(new Error("Database error: deadlock"));
    const b = mockRes();
    await KYCControllers.actKycChangeRequest(req({ kyc_modified_sno: 9, action: "approve" }), b);
    expect(b.status).toHaveBeenCalledWith(500);
    await tick();
    expect(createInAppNotification).not.toHaveBeenCalled();
    expect(notifySupplier).not.toHaveBeenCalled();
  });
});
