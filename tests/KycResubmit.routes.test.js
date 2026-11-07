// The public /resubmit routes over real HTTP + multipart: the token is read from the first form field so a bad link is refused
// before any file is kept, the parser limits hold, and errors never leak internals.
import { describe, it, expect, jest, beforeEach } from "@jest/globals";
import express from "express";
import request from "supertest";

const service = { open: jest.fn(), save: jest.fn(), assertLinkUsable: jest.fn(), getLinkStatus: jest.fn(), issueAndSend: jest.fn() };
const invalidateCache = jest.fn();
jest.unstable_mockModule("../src/KycResubmit/KycResubmit.service.js", () => ({ default: service }));
jest.unstable_mockModule("../src/Middleware/redisCache.js", () => ({ invalidateCache }));

const { default: Router } = await import("../src/KycResubmit/KycResubmit.routes.js");
const { default: Controller } = await import("../src/KycResubmit/KycResubmit.controller.js");

const TOKEN = "B".repeat(43);
const pdfBytes = Buffer.from("%PDF-1.4\n%%EOF\n", "latin1");
const emit = jest.fn();
const to = jest.fn(() => ({ emit }));

const app = express();
app.use(express.json());
app.use((req, _res, next) => { req.io = { to }; req.user_ecno = "ED001"; next(); });
app.use("/r", Router);
app.post("/staff/send", Controller.send);
app.get("/staff/status/:kycId", Controller.status);

const linkError = (status = 410, message = "This link has expired.") => Object.assign(new Error(message), { userFacing: true, status });

beforeEach(() => {
  Object.values(service).forEach((f) => f.mockReset());
  invalidateCache.mockReset().mockResolvedValue();
  emit.mockReset();
  to.mockClear();
  service.assertLinkUsable.mockResolvedValue({});
  jest.spyOn(console, "error").mockImplementation(() => {});
});

describe("POST /open", () => {
  it("returns the page data, and never lets the browser cache or leak it", async () => {
    service.open.mockResolvedValue({ kyc: { company_name: "Acme" } });
    const res = await request(app).post("/r/open").send({ token: TOKEN });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ success: true, data: { kyc: { company_name: "Acme" } } });
    expect(service.open).toHaveBeenCalledWith(TOKEN);
    expect(res.headers["cache-control"]).toBe("no-store");
    expect(res.headers["referrer-policy"]).toBe("no-referrer");
  });

  it("passes the reason a link cannot be used with its status", async () => {
    service.open.mockRejectedValue(linkError());
    const res = await request(app).post("/r/open").send({ token: TOKEN });
    expect(res.status).toBe(410);
    expect(res.body).toEqual({ success: false, error: "This link has expired." });
  });

  it("hides the details of a real failure", async () => {
    service.open.mockRejectedValue(new Error("Login failed for user 'sa' on SPACEKTMDB"));
    const res = await request(app).post("/r/open").send({ token: TOKEN });
    expect(res.status).toBe(500);
    expect(JSON.stringify(res.body)).not.toMatch(/sa|SPACEKTMDB/);
  });

  it("treats a missing token as an unusable link", async () => {
    service.open.mockRejectedValue(linkError(410, "This link is not valid."));
    const res = await request(app).post("/r/open").send({});
    expect(res.status).toBe(410);
    expect(service.open).toHaveBeenCalledWith("");
  });
});

describe("POST /save", () => {
  const goodRequest = () => request(app).post("/r/save").field("token", TOKEN).field("payload", JSON.stringify({ note: "x", basic: {} }));

  it("hands the parsed form and the files to the service and refreshes the approvers' screens", async () => {
    service.save.mockResolvedValue({ company_name: "Acme" });
    const res = await goodRequest().attach("pan_file", pdfBytes, { filename: "pan.pdf", contentType: "application/pdf" });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ success: true, data: { company_name: "Acme" } });
    expect(res.body.message).toMatch(/sent for approval/);

    const arg = service.save.mock.calls[0][0];
    expect(arg.token).toBe(TOKEN);
    expect(arg.form).toEqual({ note: "x", basic: {} });
    expect(arg.files).toHaveLength(1);
    expect(arg.files[0]).toMatchObject({ fieldname: "pan_file", originalname: "pan.pdf", mimetype: "application/pdf" });
    expect(Buffer.isBuffer(arg.files[0].buffer)).toBe(true);
    expect(invalidateCache).toHaveBeenCalledWith(undefined, "kyc:list", "kyc:pending");
    expect(to).toHaveBeenCalledWith("kyc:approval");
    expect(emit).toHaveBeenCalledWith("kyc:submitted", expect.objectContaining({ resubmitted: true }));
  });

  it("works with no files at all", async () => {
    service.save.mockResolvedValue({ company_name: "Acme" });
    const res = await goodRequest();
    expect(res.status).toBe(200);
    expect(service.save.mock.calls[0][0].files).toEqual([]);
  });

  it("refuses an unusable link before keeping any file", async () => {
    service.assertLinkUsable.mockRejectedValue(linkError(410, "A newer link was sent for this KYC."));
    const res = await goodRequest().attach("pan_file", pdfBytes, { filename: "pan.pdf", contentType: "application/pdf" });
    expect(res.status).toBe(410);
    expect(res.body.error).toBe("A newer link was sent for this KYC.");
    expect(service.assertLinkUsable).toHaveBeenCalledWith(TOKEN);
    expect(service.save).not.toHaveBeenCalled();
  });

  it("does not trust a token that arrives after the file", async () => {
    service.assertLinkUsable.mockImplementation(async (t) => { if (t !== TOKEN) throw linkError(410, "This link is not valid."); });
    const res = await request(app).post("/r/save")
      .attach("pan_file", pdfBytes, { filename: "pan.pdf", contentType: "application/pdf" })
      .field("token", TOKEN).field("payload", "{}");
    expect(res.status).toBe(410);
    expect(service.assertLinkUsable).toHaveBeenCalledWith("");
    expect(service.save).not.toHaveBeenCalled();
  });

  it("refuses a file with a name the page never sends, or an extension that is not PDF / picture", async () => {
    let res = await goodRequest().attach("shell", pdfBytes, { filename: "pan.pdf", contentType: "application/pdf" });
    expect(res.status).toBe(422);
    expect(res.body.error).toMatch(/document we do not accept/);
    res = await goodRequest().attach("pan_file", Buffer.from("MZ"), { filename: "run.exe", contentType: "application/octet-stream" });
    expect(res.status).toBe(422);
    expect(res.body.error).toMatch(/Only PDF, PNG, JPG or WEBP/);
    res = await goodRequest().attach("pan_file", Buffer.from("<svg/>"), { filename: "x.svg", contentType: "image/svg+xml" });
    expect(res.status).toBe(422);
    expect(service.save).not.toHaveBeenCalled();
  });

  it("refuses a file over 5 MB with 413", async () => {
    const res = await goodRequest().attach("pan_file", Buffer.alloc(5 * 1024 * 1024 + 10, 1), { filename: "big.pdf", contentType: "application/pdf" });
    expect(res.status).toBe(413);
    expect(res.body.error).toMatch(/larger than 5 MB/);
    expect(service.save).not.toHaveBeenCalled();
  });

  it("refuses more than 6 files", async () => {
    let r = goodRequest();
    for (let i = 0; i < 7; i += 1) r = r.attach("other_file", pdfBytes, { filename: `o${i}.pdf`, contentType: "application/pdf" });
    const res = await r;
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/at most 6 files/);
    expect(service.save).not.toHaveBeenCalled();
  });

  it("refuses a form that is not JSON", async () => {
    const res = await request(app).post("/r/save").field("token", TOKEN).field("payload", "not json");
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/could not be read/);
    expect(service.save).not.toHaveBeenCalled();
  });

  it("passes on what the service says about an unsafe file, and hides unexpected failures", async () => {
    service.save.mockRejectedValue(Object.assign(new Error('"pan.pdf" contains scripts, embedded files or other active content, so it was not accepted.'), { userFacing: true, status: 422 }));
    let res = await goodRequest();
    expect(res.status).toBe(422);
    expect(res.body.error).toMatch(/active content/);
    service.save.mockRejectedValue(new Error("Invalid object name 'kyc_resubmit_link'"));
    res = await goodRequest();
    expect(res.status).toBe(500);
    expect(JSON.stringify(res.body)).not.toMatch(/kyc_resubmit_link/);
  });
});

describe("staff routes", () => {
  it("sends a new link as the logged-in approver, never as someone the browser names", async () => {
    service.issueAndSend.mockResolvedValue({ issued: true, emailSent: true, sent_to: "r@acme.example" });
    const res = await request(app).post("/staff/send").send({ kyc_basic_info_sno: 7, reason: " Fix the PAN ", created_by: "HACKER" });
    expect(res.status).toBe(200);
    expect(res.body.message).toMatch(/e-mailed to r@acme.example/);
    expect(service.issueAndSend).toHaveBeenCalledWith({ kycId: 7, reason: "Fix the PAN", createdBy: "ED001", throwOnError: true });
  });

  it("explains why a link cannot be sent and checks the input", async () => {
    service.issueAndSend.mockRejectedValue(Object.assign(new Error("A correction link can be sent only for a rejected KYC."), { userFacing: true }));
    let res = await request(app).post("/staff/send").send({ kyc_basic_info_sno: 7 });
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/only for a rejected KYC/);
    res = await request(app).post("/staff/send").send({ kyc_basic_info_sno: "abc" });
    expect(res.status).toBe(400);
  });

  it("reports the state of the last link", async () => {
    service.getLinkStatus.mockResolvedValue({ link_state: "OPEN" });
    const res = await request(app).get("/staff/status/7");
    expect(res.body).toEqual({ success: true, data: { link_state: "OPEN" } });
    expect((await request(app).get("/staff/status/x")).status).toBe(400);
  });
});
