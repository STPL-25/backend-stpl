// Kyc.service.js approveKyc: rejecting a KYC e-mails the supplier a correction link (sql/155) - and a failure there must
// never undo the rejection.
import { describe, it, expect, jest, beforeEach } from "@jest/globals";

const repo = { approveKyc: jest.fn(), getSupplierContact: jest.fn(), createSupplierLogin: jest.fn() };
const issueAndSend = jest.fn();
jest.unstable_mockModule("../src/Kyc/repository/Kyc.repository.js", () => ({ default: function KYCRepo() { return repo; } }));
jest.unstable_mockModule("../src/Utils/Notify/notifyClient.js", () => ({ sendSupplierInviteEmail: jest.fn() }));
jest.unstable_mockModule("../src/KycResubmit/KycResubmit.service.js", () => ({ default: { issueAndSend } }));

const { default: KYCServices } = await import("../src/Kyc/services/Kyc.service.js");

const input = { kyc_basic_info_sno: 7, ecno: "ED001", comments: "PAN is not readable", action: "reject" };

beforeEach(() => {
  Object.values(repo).forEach((f) => f.mockReset());
  issueAndSend.mockReset();
  jest.spyOn(console, "error").mockImplementation(() => {});
});

describe("approveKyc and the correction link", () => {
  it("sends the link, with the approver's comment as the reason, after a successful rejection", async () => {
    repo.approveKyc.mockResolvedValue([[{ x: 1 }], [{ result: "SUCCESS", message: "KYC rejected.", status: "R" }]]);
    issueAndSend.mockResolvedValue({ issued: true, emailSent: true, sent_to: "r@acme.example" });
    const outcome = await KYCServices.approveKyc(input);
    expect(issueAndSend).toHaveBeenCalledWith({ kycId: 7, reason: "PAN is not readable", createdBy: "ED001" });
    expect(outcome[0].resubmit_link).toEqual({ issued: true, emailSent: true, sent_to: "r@acme.example" });
    expect(outcome[0].result).toBe("SUCCESS");
  });

  it("still reports the rejection when the link could not be started", async () => {
    repo.approveKyc.mockResolvedValue([[{ result: "SUCCESS", status: "R" }]]);
    issueAndSend.mockRejectedValue(new Error("boom"));
    const outcome = await KYCServices.approveKyc(input);
    expect(outcome[0]).toMatchObject({ result: "SUCCESS", resubmit_link: { issued: false, emailSent: false } });
  });

  it("does nothing for an approval", async () => {
    repo.approveKyc.mockResolvedValue([[{ result: "SUCCESS", message: "Stage approved." }]]);
    await KYCServices.approveKyc({ ...input, action: "approve" });
    expect(issueAndSend).not.toHaveBeenCalled();
  });

  it("does nothing when the rejection itself failed", async () => {
    repo.approveKyc.mockResolvedValue([[{ result: "ERROR", error_message: "KYC record not found or is not in Pending (P) status." }]]);
    const outcome = await KYCServices.approveKyc(input);
    expect(issueAndSend).not.toHaveBeenCalled();
    expect(outcome[0].resubmit_link).toBeUndefined();
  });
});
