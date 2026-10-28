// Kyc.service.js sendSupplierInvite - the supplier portal login made on the final KYC approval. It must never undo an approval, but it
// must say so when the supplier ends up with a code and no usable login (a shared e-mail used to make the login insert fail silently).
import { describe, it, expect, jest, beforeEach } from "@jest/globals";

const repo = {
  getSupplierContact: jest.fn(),
  createSupplierLogin: jest.fn(),
  approveKyc: jest.fn(),
};
const sendSupplierInviteEmail = jest.fn();
jest.unstable_mockModule("../src/Kyc/repository/Kyc.repository.js", () => ({ default: function KYCRepo() { return repo; } }));
jest.unstable_mockModule("../src/Utils/Notify/notifyClient.js", () => ({ sendSupplierInviteEmail }));

const { default: KYCServices } = await import("../src/Kyc/services/Kyc.service.js");

const contact = { company_name: "KANINI TECHNOLOGY", email: "store@nachammal.com", supp_code: "SCL2604" };

beforeEach(() => {
  Object.values(repo).forEach((f) => f.mockReset());
  sendSupplierInviteEmail.mockReset();
  jest.spyOn(console, "error").mockImplementation(() => {});
});

describe("sendSupplierInvite", () => {
  it("creates the login and sends the temporary password", async () => {
    repo.getSupplierContact.mockResolvedValue(contact);
    repo.createSupplierLogin.mockResolvedValue({});
    sendSupplierInviteEmail.mockResolvedValue({ sent: true });
    const r = await KYCServices.sendSupplierInvite(101, "ED001");
    expect(r).toEqual({ loginCreated: true, emailSent: true, login_email: "store@nachammal.com" });
    const arg = repo.createSupplierLogin.mock.calls[0][0];
    expect(arg).toMatchObject({ kyc_basic_info_sno: 101, login_email: "store@nachammal.com", created_by: "ED001" });
    expect(arg.password_hash).toMatch(/^\$2[aby]\$/);
    expect(sendSupplierInviteEmail.mock.calls[0][0]).toMatchObject({ to: "store@nachammal.com", suppCode: "SCL2604" });
  });

  it("says no login was created when the database refuses it (and never throws)", async () => {
    repo.getSupplierContact.mockResolvedValue(contact);
    repo.createSupplierLogin.mockRejectedValue(new Error("Database error: Violation of UNIQUE KEY constraint"));
    const r = await KYCServices.sendSupplierInvite(101, "ED001");
    expect(r.loginCreated).toBe(false);
    expect(r.emailSent).toBe(false);
    expect(r.reason).toMatch(/No supplier portal login was created: .*UNIQUE KEY/);
    expect(sendSupplierInviteEmail).not.toHaveBeenCalled();
  });

  it("says the supplier never got the password when the login exists but the e-mail failed", async () => {
    repo.getSupplierContact.mockResolvedValue(contact);
    repo.createSupplierLogin.mockResolvedValue({});
    sendSupplierInviteEmail.mockResolvedValue({ sent: false, reason: "SMTP down" });
    const r = await KYCServices.sendSupplierInvite(101, "ED001");
    expect(r).toMatchObject({ loginCreated: true, emailSent: false });
    expect(r.reason).toMatch(/login was created but the invite e-mail was not sent \(SMTP down\)/);
  });

  it("explains a supplier with no e-mail on the KYC record", async () => {
    repo.getSupplierContact.mockResolvedValue({ ...contact, email: null });
    const r = await KYCServices.sendSupplierInvite(101, "ED001");
    expect(r).toMatchObject({ loginCreated: false, emailSent: false });
    expect(r.reason).toMatch(/No email/);
    expect(repo.createSupplierLogin).not.toHaveBeenCalled();
  });
});

describe("approveKyc - the invite only follows a final approval that made a supplier code", () => {
  it("attaches the invite result to the outcome row", async () => {
    repo.approveKyc.mockResolvedValue([[{ result: "SUCCESS", message: "KYC fully approved.", supp_code: "SCL2604" }]]);
    repo.getSupplierContact.mockResolvedValue(contact);
    repo.createSupplierLogin.mockRejectedValue(new Error("duplicate"));
    const out = await KYCServices.approveKyc({ kyc_basic_info_sno: 101, ecno: "ED001", action: "approve" });
    expect(out[0].supp_code).toBe("SCL2604");
    expect(out[0].supplier_invite).toMatchObject({ loginCreated: false, emailSent: false });
  });

  it("does not create a login for an intermediate stage", async () => {
    repo.approveKyc.mockResolvedValue([[{ result: "SUCCESS", next_approver_ecno: "ED001" }]]);
    const out = await KYCServices.approveKyc({ kyc_basic_info_sno: 101, ecno: "KTM1148", action: "approve" });
    expect(out[0].supplier_invite).toBeUndefined();
    expect(repo.getSupplierContact).not.toHaveBeenCalled();
  });
});
