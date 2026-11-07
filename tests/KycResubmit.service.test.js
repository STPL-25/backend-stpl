// KycResubmit.service.js - the link, and the order of a save: the link, the form and EVERY file are checked before a byte
// goes to the FTP server or the database.
import { describe, it, expect, jest, beforeEach } from "@jest/globals";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";

const repo = { issue: jest.fn(), markEmail: jest.fn(), linkStatus: jest.fn(), check: jest.fn(), open: jest.fn(), save: jest.fn() };
const ftpUploader = { uploadFileIfExists: jest.fn() };
const sendKycResubmitEmail = jest.fn();
const createInAppNotification = jest.fn();
jest.unstable_mockModule("../src/KycResubmit/KycResubmit.repository.js", () => ({ default: function Repo() { return repo; } }));
jest.unstable_mockModule("../src/Utils/ImagesUpload/ImgUpload.js", () => ({ ftpUploader }));
jest.unstable_mockModule("../src/Utils/Notify/notifyClient.js", () => ({ sendKycResubmitEmail, createInAppNotification }));

const { default: Service, newToken, hashToken, resubmitLink, resubmitBaseUrl, assertTokenShape } = await import("../src/KycResubmit/KycResubmit.service.js");

const here = path.dirname(fileURLToPath(import.meta.url));
const plainPdf = fs.readFileSync(path.join(here, "fixtures", "kyc-resubmit", "plain.pdf"));
const jsPdf = fs.readFileSync(path.join(here, "fixtures", "kyc-resubmit", "js_plain.pdf"));
const png = (() => {
  const chunk = (t, d) => { const l = Buffer.alloc(4); l.writeUInt32BE(d.length); return Buffer.concat([l, Buffer.from(t), d, Buffer.alloc(4)]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(8, 0); ihdr.writeUInt32BE(8, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(Buffer.alloc(30))), chunk("IEND", Buffer.alloc(0))]);
})();
const file = (buffer, originalname, mimetype, fieldname) => ({ fieldname, originalname, mimetype, size: buffer.length, buffer });

const TOKEN = "A".repeat(43);
const currentRow = { company_name: "Acme", business_type: "1", supplier_cat_code: "PS", reject_reason: "PAN unreadable", rejected_date: "2026-11-07", expires_at: "2026-11-14" };
const goodForm = () => ({
  note: "fixed",
  basic: { company_name: "Acme", contact_person: "Ravi", email: "r@acme.example", mobile_number: "9876543210", business_type: "1", supplier_cat_code: "PS", pan_no: "ABCDE1234F", is_gst_avail: "N", is_msme_avail: "N", pay_via_portal: "N" },
  addresses: [{ kyc_address_sno: 1, door_no: "1", street: "S", area: "A", city: "C", state: "TN", pincode: "641004", is_primary: "Y" }],
  banks: [{ kyc_bank_sno: 2, ac_holder_name: "Acme", ac_number: "123456789012", ac_type: "10", ifsc: "HDFC0001234", bank_name: "HDFC", bank_branch_name: "RS", bank_address: "CBE", is_primary: "Y" }],
  contacts: [{ kyc_contact_sno: 3, contact_name: "Ravi", contact_mobile: "9876543210", contact_email: "r@acme.example", is_primary: "Y" }],
});
/** What sp_nt_KycResubmitOpen returns: 8 result sets. */
const openSets = ({ docs = [{ document_type: "pan_file", document_name: "old.pdf", document_path: "http://secret/dwl/old.pdf", uploaded_date: "2026-10-01" }] } = {}) => [
  [currentRow], [{ kyc_address_sno: 1 }], [{ kyc_bank_sno: 2 }], [{ kyc_contact_sno: 3 }], docs,
  [{ value: "1", label: "Manufacturer" }], [{ value: "10", label: "Savings" }], [{ value: "PS", label: "Product Supplier" }],
];

beforeEach(() => {
  Object.values(repo).forEach((f) => f.mockReset());
  ftpUploader.uploadFileIfExists.mockReset();
  sendKycResubmitEmail.mockReset();
  createInAppNotification.mockReset().mockResolvedValue({ sent: true });
  delete process.env.KYC_RESUBMIT_BASE_URL;
  delete process.env.CLAMAV_HOST;
  process.env.SUPPLIER_PORTAL_URL = "https://uat.example.net/supplier";
  jest.spyOn(console, "error").mockImplementation(() => {});
});

describe("tokens and links", () => {
  it("makes 43-character URL-safe tokens, all different, and only ever stores an upper-case SHA-256", () => {
    const a = newToken();
    expect(a).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(newToken()).not.toBe(a);
    expect(hashToken(a)).toMatch(/^[0-9A-F]{64}$/);
    expect(hashToken(a)).not.toContain(a);
  });

  it("puts the token after # so it never reaches a server log or a Referer", () => {
    expect(resubmitLink("TOK")).toBe("https://uat.example.net/kyc_resubmit#t=TOK");
    process.env.KYC_RESUBMIT_BASE_URL = "https://kyc.example.com/";
    expect(resubmitBaseUrl()).toBe("https://kyc.example.com");
    expect(resubmitLink("TOK")).toBe("https://kyc.example.com/kyc_resubmit#t=TOK");
  });

  it("refuses a token of the wrong shape before the database is asked", () => {
    for (const bad of ["", "short", undefined, null, 5, {}, "A".repeat(44), `${"A".repeat(42)}!`, `${"A".repeat(42)} `, `'; DROP TABLE x;--${"A".repeat(30)}`]) {
      expect(() => assertTokenShape(bad)).toThrow(expect.objectContaining({ userFacing: true, status: 410 }));
    }
    expect(() => assertTokenShape(TOKEN)).not.toThrow();
    expect(repo.check).not.toHaveBeenCalled();
  });
});

describe("issueAndSend", () => {
  const row = { link_sno: 9, company_name: "Acme", sent_to: "r@acme.example", reject_reason: "PAN unreadable", expires_at: new Date("2026-11-14T10:00:00Z") };

  it("stores only the hash, e-mails the link that belongs to it, and records that the e-mail went out", async () => {
    repo.issue.mockResolvedValue(row);
    sendKycResubmitEmail.mockResolvedValue({ sent: true });
    const r = await Service.issueAndSend({ kycId: 7, reason: "PAN unreadable", createdBy: "ED001" });
    expect(r).toMatchObject({ issued: true, emailSent: true, sent_to: "r@acme.example" });

    const issued = repo.issue.mock.calls[0][0];
    expect(issued).toMatchObject({ kycId: 7, reason: "PAN unreadable", createdBy: "ED001", validDays: 7 });
    const mail = sendKycResubmitEmail.mock.calls[0][0];
    const token = /#t=(.+)$/.exec(mail.link)[1];
    expect(hashToken(token)).toBe(issued.tokenHash);
    expect(JSON.stringify(issued)).not.toContain(token);
    expect(mail).toMatchObject({ to: "r@acme.example", companyName: "Acme", reason: "PAN unreadable" });
    expect(repo.markEmail).toHaveBeenCalledWith(9, true, null);
  });

  it("says so when the link exists but the e-mail did not go out", async () => {
    repo.issue.mockResolvedValue(row);
    sendKycResubmitEmail.mockResolvedValue({ sent: false, reason: "SMTP down" });
    const r = await Service.issueAndSend({ kycId: 7, reason: "x", createdBy: "ED001" });
    expect(r).toMatchObject({ issued: true, emailSent: false });
    expect(r.reason).toMatch(/not sent \(SMTP down\)/);
    expect(repo.markEmail).toHaveBeenCalledWith(9, false, "SMTP down");
  });

  it("never throws for the rejection hook, and tells the approver why in plain words", async () => {
    repo.issue.mockRejectedValue(Object.assign(new Error("This KYC has no valid e-mail address."), { userFacing: true }));
    expect(await Service.issueAndSend({ kycId: 7, reason: "x", createdBy: "ED001" })).toEqual({ issued: false, emailSent: false, reason: "This KYC has no valid e-mail address." });
    repo.issue.mockRejectedValue(new Error("Database error: secret table name"));
    const r = await Service.issueAndSend({ kycId: 7, reason: "x", createdBy: "ED001" });
    expect(r.reason).toBe("The correction link could not be created.");
    expect(sendKycResubmitEmail).not.toHaveBeenCalled();
  });

  it("throws when staff ask for a link and it cannot be made", async () => {
    repo.issue.mockRejectedValue(Object.assign(new Error("Only an approver"), { userFacing: true }));
    await expect(Service.issueAndSend({ kycId: 7, createdBy: "X", throwOnError: true })).rejects.toThrow("Only an approver");
  });
});

describe("open", () => {
  it("returns what the page needs and never a stored file's address", async () => {
    repo.open.mockResolvedValue(openSets());
    const data = await Service.open(TOKEN);
    expect(repo.open).toHaveBeenCalledWith(hashToken(TOKEN));
    expect(data.link.reject_reason).toBe("PAN unreadable");
    expect(data.documents).toEqual([{ document_type: "pan_file", label: "PAN card", document_name: "old.pdf", uploaded_date: "2026-10-01" }]);
    expect(JSON.stringify(data)).not.toContain("secret");
    expect(data.uploads).toMatchObject({ allowed: "PDF, PNG, JPG or WEBP", max_mb: 5, max_files: 6 });
    expect(data.choices.business_types).toEqual([{ value: "1", label: "Manufacturer" }]);
  });

  it("does not ask the database about a malformed token", async () => {
    await expect(Service.open("nope")).rejects.toMatchObject({ status: 410 });
    expect(repo.open).not.toHaveBeenCalled();
  });
});

describe("save", () => {
  const saved = { kyc_basic_info_sno: 7, company_name: "Acme", approver_ecno: "ED001 ", resubmit_count: 2 };

  it("checks everything first, then uploads with clean names, then saves, then tells the approver", async () => {
    repo.open.mockResolvedValue(openSets());
    repo.save.mockResolvedValue(saved);
    ftpUploader.uploadFileIfExists.mockResolvedValue("http://files/dwl/NON_TRADE_DATAS/KYC_DATAS/pan_x.pdf");

    const row = await Service.save({ token: TOKEN, form: goodForm(), files: [file(plainPdf, "../../PAN card.php.pdf", "application/pdf", "pan_file")], clientIp: "203.0.113.5" });
    expect(row).toBe(saved);

    const [uploaded, folder] = ftpUploader.uploadFileIfExists.mock.calls[0];
    expect(folder).toBe("NON_TRADE_DATAS/KYC_DATAS");
    expect(uploaded.originalname).toBe("PAN card_php.pdf");
    expect(Buffer.isBuffer(uploaded.buffer)).toBe(true);

    const arg = repo.save.mock.calls[0][0];
    expect(arg.tokenHash).toBe(hashToken(TOKEN));
    expect(arg.clientIp).toBe("203.0.113.5");
    expect(arg.documents).toEqual([{ document_type: "pan_file", document_name: "PAN card_php.pdf", document_path: "http://files/dwl/NON_TRADE_DATAS/KYC_DATAS/pan_x.pdf", file_size: plainPdf.length }]);
    expect(arg.filesJson[0]).toMatchObject({ type: "pan_file", detected: "pdf", antivirus: "not configured" });
    expect(arg.filesJson[0].sha256).toMatch(/^[0-9a-f]{64}$/);
    expect(arg.payload.basic.pan_no).toBe("ABCDE1234F");

    expect(createInAppNotification).toHaveBeenCalledWith(expect.objectContaining({ ecno: "ED001", data: expect.objectContaining({ kind: "kyc_resubmitted", kyc_basic_info_sno: 7 }) }));
  });

  it("works with no new files when a PAN card is already on file", async () => {
    repo.open.mockResolvedValue(openSets());
    repo.save.mockResolvedValue(saved);
    await Service.save({ token: TOKEN, form: goodForm(), files: [], clientIp: "1.1.1.1" });
    expect(ftpUploader.uploadFileIfExists).not.toHaveBeenCalled();
    expect(repo.save.mock.calls[0][0].documents).toEqual([]);
  });

  it("uploads and saves NOTHING when one file is unsafe", async () => {
    repo.open.mockResolvedValue(openSets());
    await expect(Service.save({
      token: TOKEN, form: goodForm(),
      files: [file(png, "gst.png", "image/png", "gst_file"), file(jsPdf, "pan.pdf", "application/pdf", "pan_file")],
    })).rejects.toThrow(/active content/);
    expect(ftpUploader.uploadFileIfExists).not.toHaveBeenCalled();
    expect(repo.save).not.toHaveBeenCalled();
  });

  it("uploads and saves NOTHING when the form is wrong", async () => {
    repo.open.mockResolvedValue(openSets());
    const form = goodForm();
    form.basic.pan_no = "bad";
    await expect(Service.save({ token: TOKEN, form, files: [file(plainPdf, "pan.pdf", "application/pdf", "pan_file")] })).rejects.toThrow(/PAN is not valid/);
    expect(ftpUploader.uploadFileIfExists).not.toHaveBeenCalled();
    expect(repo.save).not.toHaveBeenCalled();
  });

  it("uploads and saves NOTHING when there is no PAN card anywhere", async () => {
    repo.open.mockResolvedValue(openSets({ docs: [] }));
    await expect(Service.save({ token: TOKEN, form: goodForm(), files: [file(png, "gst.png", "image/png", "gst_file")] })).rejects.toThrow("Upload your PAN card.");
    expect(ftpUploader.uploadFileIfExists).not.toHaveBeenCalled();
    expect(repo.save).not.toHaveBeenCalled();
  });

  it("stops before anything when the link is not usable", async () => {
    repo.open.mockRejectedValue(Object.assign(new Error("This link has expired."), { userFacing: true, status: 410 }));
    await expect(Service.save({ token: TOKEN, form: goodForm(), files: [file(plainPdf, "pan.pdf", "application/pdf", "pan_file")] })).rejects.toThrow("This link has expired.");
    expect(ftpUploader.uploadFileIfExists).not.toHaveBeenCalled();
    await expect(Service.save({ token: "bad", form: goodForm(), files: [] })).rejects.toMatchObject({ status: 410 });
  });

  it("does not save when a file cannot be stored", async () => {
    repo.open.mockResolvedValue(openSets());
    ftpUploader.uploadFileIfExists.mockResolvedValue("");
    await expect(Service.save({ token: TOKEN, form: goodForm(), files: [file(plainPdf, "pan.pdf", "application/pdf", "pan_file")] })).rejects.toMatchObject({ status: 502 });
    expect(repo.save).not.toHaveBeenCalled();
  });

  it("does not fail the save when the approver's bell cannot be reached", async () => {
    repo.open.mockResolvedValue(openSets());
    repo.save.mockResolvedValue(saved);
    createInAppNotification.mockRejectedValue(new Error("down"));
    await expect(Service.save({ token: TOKEN, form: goodForm(), files: [] })).resolves.toBe(saved);
  });
});
