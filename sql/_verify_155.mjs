/**
 * Verifies sql/155_kyc_resubmit_link.sql WITHOUT applying it: every case runs in its own transaction that is always rolled
 * back (a procedure error under XACT_ABORT ends the transaction, so each expected error gets a fresh one). The test KYC is
 * created inside the transaction too, so nothing depends on, or touches, real data.
 *
 *   cd backend-stpl && node sql/_verify_155.mjs
 */
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sql from "mssql";
import { configDotenv } from "dotenv";

configDotenv({ quiet: true });
const here = path.dirname(fileURLToPath(import.meta.url));

if (!/dev/i.test(process.env.DATABASE ?? "")) {
  console.error(`Refusing to run: DATABASE is "${process.env.DATABASE}", expected a Dev database.`);
  process.exit(2);
}

const pool = await new sql.ConnectionPool({
  user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD, server: process.env.SERVER,
  database: process.env.DATABASE, port: parseInt(process.env.DB_PORT) || 1433,
  options: { trustServerCertificate: true, enableArithAbort: true }, requestTimeout: 120000,
}).connect();
console.log(`Database: ${process.env.DATABASE} (every change is rolled back)\n`);

const script = await fs.readFile(path.join(here, "155_kyc_resubmit_link.sql"), "utf8");
const batches = script.split(/^\s*GO\s*$/gim).map((b) => b.trim())
  .filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));

// sql/156 re-creates sp_InsertKYCData with QUOTED_IDENTIFIER ON; the live procedure has it OFF and cannot insert at all (error 1934).
const fixScript = await fs.readFile(path.join(here, "156_sp_insert_kyc_data_quoted_identifier.sql"), "utf8");
const fixBatches = fixScript.split(/^\s*GO\s*$/gim).map((b) => b.trim())
  .filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));

let failures = 0;
const check = (ok, label, extra = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${label}${extra ? `  ${extra}` : ""}`); if (!ok) failures += 1; };

const newToken = () => { const token = crypto.randomBytes(32).toString("base64url"); return { token, hash: crypto.createHash("sha256").update(token).digest("hex").toUpperCase() }; };

const [[bt], [acType]] = await Promise.all([
  pool.request().query("SELECT TOP 1 CAST(business_types_id AS VARCHAR(20)) v FROM dbo.business_types WHERE IsActive = 1 ORDER BY business_types_id").then((r) => r.recordset),
  pool.request().query("SELECT TOP 1 CAST(bank_account_type_sno AS VARCHAR(20)) v FROM dbo.bank_account_type_master WHERE is_active = 'Y' ORDER BY bank_account_type_sno").then((r) => r.recordset),
]);

let seq = 0;
const unique = () => `${Date.now().toString(36)}${(seq += 1)}`.toUpperCase();

/** A KYC as the public form sends it to sp_InsertKYCData. */
function newKycInput({ withPan = true, gst } = {}) {
  const u = unique();
  return {
    company_name: `VERIFY155 ${u}`, contact_name: "Test Person", email: "verify155@example.com", mobile_number: "9876543210",
    business_type: bt.v, is_gst_avail: "true", gst_no: gst ?? `33AAAAA${String(seq).padStart(4, "0")}A1Z5`, is_msme_avail: "false",
    pan_no: `AAAAA${String(seq).padStart(4, "0")}A`, created_by: "PUBLIC", supplier_cat_code: "PS",
    addresses: [{ door_no: "1", street: "Old Street", area: "Area", city: "Chennai", taluk: "", state: "Tamil Nadu", state_code: "33", pincode: "600001", location_link: "", isPrimary: true }],
    bankDetails: [{ ac_holder_name: "Old Holder", ac_number: "111122223333", ac_type: acType.v, ifsc: "HDFC0001234", bank_name: "HDFC", bank_branch_name: "Main", bank_address: "Chennai", isPrimary: true }],
    contacts: [{ ownername: "Owner One", ownerposition: "MD", ownermobile: "9876543210", owneremail: "owner@example.com", isPrimary: true }],
    document: JSON.stringify(withPan ? [{ documentType: "pan_file", filename: "pan-old.pdf", url: "http://localhost/dwl/old/pan-old.pdf", size: 1000 }] : []),
  };
}

/** Runs fn inside a fresh transaction with sql/155 applied and a rejected KYC ready, then rolls back. */
async function inTx(label, opts, fn) {
  const tx = new sql.Transaction(pool);
  await tx.begin();
  const q = async (text) => (await new sql.Request(tx).query(text)).recordset;
  const exec = async (proc, params = {}) => {
    const r = new sql.Request(tx);
    for (const [k, [type, v]] of Object.entries(params)) r.input(k, type, v);
    return (await r.execute(proc)).recordsets;
  };
  try {
    for (const b of [...fixBatches, ...batches]) await new sql.Request(tx).batch(b);
    const input = newKycInput(opts);
    const [[ins]] = await exec("sp_InsertKYCData", { jsonInput: [sql.NVarChar(sql.MAX), JSON.stringify(input)] });
    const k = ins.kyc_basic_info_sno;
    const [{ approver_ecno: approver }] = await q(`SELECT approver_ecno FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = ${k}`);
    let rejected = false;
    if (opts?.reject !== false) {
      const sets = await exec("sp_approve_kyc_datas", { jsonInput: [sql.NVarChar(sql.MAX), JSON.stringify({ kyc_basic_info_sno: k, ecno: approver, action: "reject" })] });
      rejected = sets.some((rs) => rs[0]?.result === "SUCCESS");
    }
    const issue = (hash, reason = "PAN card is not readable", by = approver) => exec("sp_nt_KycResubmitIssue", {
      kyc_basic_info_sno: [sql.Int, k], token_hash: [sql.Char(64), hash], reason: [sql.NVarChar(1000), reason], created_by: [sql.VarChar(30), by],
    });
    await fn({ q, exec, k, approver, input, rejected, issue });
  } finally {
    try { await tx.rollback(); } catch { /* an error inside the procedure already ended it */ }
  }
  console.log(`      (${label}: rolled back)\n`);
}

async function expectError(promise, num, label) {
  try { await promise; check(false, label, "no error raised"); }
  catch (e) { check(e.number === num, label, `-> ${e.number}: ${e.message}`); }
}

/** The corrected form: the KYC as it is, with the snos the open call returned, and what the test changes. */
async function correctedPayload(exec, hash, change = {}) {
  const [head, addresses, banks, contacts] = await exec("sp_nt_KycResubmitOpen", { token_hash: [sql.Char(64), hash] });
  const h = head[0];
  const basic = {
    company_name: h.company_name, legal_name: h.legal_name, trade_name: h.trade_name, contact_person: h.contact_person, email: h.email,
    mobile_number: h.mobile_number, business_type: h.business_type, supplier_cat_code: h.supplier_cat_code, pan_no: h.pan_no,
    is_gst_avail: h.is_gst_avail, gst_no: h.gst_no, is_msme_avail: h.is_msme_avail, msme_no: h.msme_no, msme_type: h.msme_type,
    pay_via_portal: h.pay_via_portal, payment_portal_name: h.payment_portal_name, payment_portal_url: h.payment_portal_url,
    payment_instructions: h.payment_instructions, ...change.basic,
  };
  return { note: "Corrected the PAN card and bank account", basic, addresses: change.addresses ?? addresses, banks: change.banks ?? banks, contacts: change.contacts ?? contacts };
}

const save = (exec, hash, payload, docs = []) => exec("sp_nt_KycResubmitSave", {
  token_hash: [sql.Char(64), hash], payload: [sql.NVarChar(sql.MAX), JSON.stringify(payload)],
  documents: [sql.NVarChar(sql.MAX), JSON.stringify(docs)], files_json: [sql.NVarChar(sql.MAX), JSON.stringify(docs)], client_ip: [sql.VarChar(45), "203.0.113.9"],
});

// ───────────────────────────── 1. the whole journey
await inTx("journey", {}, async ({ q, exec, k, approver, input, rejected, issue }) => {
  check(rejected, "test KYC was rejected through sp_approve_kyc_datas", `(KYC ${k}, approver ${approver})`);
  const [{ status }] = await q(`SELECT status FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = ${k}`);
  check(status === "R", "KYC status is R after the rejection");

  const first = newToken();
  const [[l1]] = await issue(first.hash, "The PAN card is not readable and the bank account is wrong");
  check(l1.sent_to === "verify155@example.com" && l1.link_sno > 0, "link issued to the KYC e-mail", JSON.stringify({ sent_to: l1.sent_to }));
  const [st1] = (await exec("sp_nt_KycResubmitLinkStatus", { kyc_basic_info_sno: [sql.Int, k] }))[0];
  check(st1.link_state === "OPEN" && st1.resubmit_count === 0 && st1.email_sent === "N", "status: OPEN, nothing resubmitted yet, e-mail not marked sent");
  await exec("sp_nt_KycResubmitMarkEmail", { link_sno: [sql.Int, l1.link_sno], sent: [sql.Bit, 1], note: [sql.NVarChar(300), null] });
  const [st1b] = (await exec("sp_nt_KycResubmitLinkStatus", { kyc_basic_info_sno: [sql.Int, k] }))[0];
  check(st1b.email_sent === "Y", "e-mail marked as sent");

  const second = newToken();
  await issue(second.hash, "The PAN card is not readable and the bank account is wrong");
  const rows = await q(`SELECT closed_reason, closed_date FROM dbo.kyc_resubmit_link WHERE link_sno = ${l1.link_sno}`);
  check(rows[0].closed_reason === "REPLACED", "a newer link closes the older one (REPLACED)");
  await expectError(exec("sp_nt_KycResubmitCheck", { token_hash: [sql.Char(64), first.hash] }), 58712, "the older link no longer works");

  const sets = await exec("sp_nt_KycResubmitOpen", { token_hash: [sql.Char(64), second.hash] });
  check(sets.length === 8, "open returns 8 result sets", `(${sets.length})`);
  const [head, addresses, banks, contacts, documents, businessTypes, accountTypes, categories] = sets;
  check(head[0].company_name === input.company_name && head[0].reject_reason.includes("bank account is wrong"), "open: company + the reason it was rejected");
  check(addresses.length === 1 && banks.length === 1 && contacts.length === 1 && documents.length === 1, "open: one address / bank / contact / document");
  check(banks[0].ac_number === "111122223333", "open: account number comes back as text");
  check(businessTypes.length > 0 && accountTypes.length > 0 && Array.isArray(categories), "open: choices for the form");
  const [{ opened }] = await q(`SELECT COUNT(opened_date) AS opened FROM dbo.kyc_resubmit_link WHERE link_sno = ${head[0].link_sno}`);
  check(opened === 1, "open marks the link as opened");

  const oldSnap = (await q(`SELECT dbo.fn_nt_KycSnapshot(${k}) AS s`))[0].s;
  const payload = await correctedPayload(exec, second.hash, {
    basic: { company_name: "VERIFY155 CORRECTED" },
    addresses: [{ ...addresses[0], city: "Coimbatore" }, { door_no: "9", street: "New Street", area: "Area 2", city: "Madurai", state: "Tamil Nadu", state_code: "33", pincode: "625001", is_primary: "N" }],
    banks: [{ ac_holder_name: "New Holder", ac_number: "999988887777", ac_type: acType.v, ifsc: "ICIC0004321", bank_name: "ICICI", bank_branch_name: "Town", bank_address: "Madurai", is_primary: "Y" }],
  });
  const docs = [{ document_type: "pan_file", document_name: "pan-new.pdf", document_path: "http://localhost/dwl/new/pan-new.pdf", file_size: 2000 },
                { document_type: "gst_file", document_name: "gst.png", document_path: "http://localhost/dwl/new/gst.png", file_size: 3000 }];
  const [[res]] = await save(exec, second.hash, payload, docs);
  check(res.approver_ecno === approver && res.resubmit_count === 1, "save: back to the first approver", JSON.stringify(res));

  const [b] = await q(`SELECT status, company_name, approver_ecno, modified_by, gst_status FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = ${k}`);
  check(b.status === "P" && b.company_name === "VERIFY155 CORRECTED" && b.modified_by === "SUPPLIER", "KYC is P again with the corrected company name");
  const addr = await q(`SELECT kyc_address_sno, city, is_active, is_primary FROM dbo.kyc_address_info WHERE kyc_basic_info_sno = ${k} ORDER BY kyc_address_sno`);
  check(addr.length === 2 && addr[0].city === "Coimbatore" && addr[0].is_active === "Y" && addr[0].kyc_address_sno === addresses[0].kyc_address_sno, "address 1 updated in place (same sno), address 2 added");
  const bank = await q(`SELECT ac_number, is_active FROM dbo.kyc_bank_info WHERE kyc_basic_info_sno = ${k} ORDER BY kyc_address_sno`);
  check(bank.length === 2 && bank[0].is_active === "N" && bank[1].is_active === "Y" && Number(bank[1].ac_number) === 999988887777, "old bank account deactivated (kept), new one active");
  const doc = await q(`SELECT document_type, document_name, is_active FROM dbo.kyc_document_info WHERE kyc_basic_info_sno = ${k} ORDER BY kyc_document_sno`);
  check(doc.length === 3 && doc[0].is_active === "N" && doc[1].is_active === "Y" && doc[2].document_type === "gst_file", "new PAN replaces the old one (old kept inactive), GST certificate added");

  const link = await q(`SELECT used_date, closed_reason FROM dbo.kyc_resubmit_link WHERE token_hash = '${second.hash}'`);
  check(link[0].used_date && link[0].closed_reason === "RESUBMITTED", "link is spent");
  const [r] = await q(`SELECT supplier_note, client_ip, old_data, new_data, ISJSON(files_json) AS jf FROM dbo.kyc_resubmission WHERE kyc_basic_info_sno = ${k}`);
  check(r.supplier_note.startsWith("Corrected") && r.client_ip === "203.0.113.9" && r.jf === 1 && r.old_data === oldSnap && r.new_data !== oldSnap, "resubmission kept: note, IP, files, old and new snapshot");
  const hist = await q(`SELECT status, status_by FROM dbo.kyc_history WHERE kyc_basic_info_sno = ${k} ORDER BY kyc_history_sno`);
  check(hist.map((h) => h.status).join("") === "RS" && hist.at(-1).status_by === "SUPPLIER", "history: R then S (by SUPPLIER)");

  await expectError(exec("sp_nt_KycResubmitCheck", { token_hash: [sql.Char(64), second.hash] }), 58711, "the spent link cannot be used again");
  const [st3] = (await exec("sp_nt_KycResubmitLinkStatus", { kyc_basic_info_sno: [sql.Int, k] }))[0];
  check(st3.link_state === "USED" && st3.resubmit_count === 1, "status: USED, 1 resubmission");

  // staff views
  const approvals = (await exec("sp_get_kyc_approval", { Ecno: [sql.VarChar(20), approver] }))[0].find((x) => x.kyc_basic_info_sno === k);
  check(!!approvals && approvals.resubmit_count === 1 && approvals.resubmit_note.startsWith("Corrected") && approvals.last_reject_reason.includes("bank account is wrong"),
    "approval list: resubmit count, supplier note, previous rejection reason");
  const apBanks = JSON.parse(approvals.kyc_bank_info);
  const apAddr = JSON.parse(approvals.kyc_address);
  check(apBanks.length === 1 && apBanks[0].ac_holder_name === "New Holder" && apAddr.length === 2, "approval list shows only the active bank account / addresses");
  const tl = await exec("sp_nt_GetSupplierStatusTimeline", { source: [sql.VarChar(12), "KYC"], record_id: [sql.Int, k] });
  const ev = tl[2].map((e) => e.event);
  check(ev.join(",").endsWith("REJECTED,RESUBMITTED"), "timeline: REJECTED then RESUBMITTED", ev.join(","));
  check(tl[2].find((e) => e.event === "REJECTED").comment.includes("bank account is wrong") && tl[2].find((e) => e.event === "RESUBMITTED").comment.startsWith("Corrected"), "timeline: rejection reason and supplier note shown as comments");
  const full = await exec("sp_nt_GetSupplierFullDetails", { source: [sql.VarChar(12), "KYC"], record_id: [sql.Int, k] });
  check(full[3].length === 1 && full[2].length === 1, "full details unchanged: active rows only");
});

// ───────────────────────────── 2. the issue rules (one error per transaction)
await inTx("issue: not rejected", { reject: false }, async ({ exec, k, approver, issue }) => {
  await expectError(issue(newToken().hash), 58702, "a pending KYC cannot get a correction link");
});
await inTx("issue: stranger", {}, async ({ issue }) => {
  await expectError(issue(newToken().hash, "reason", "NOTANAPPROVER9"), 58709, "someone who is not an approver cannot send a link");
});
await inTx("issue: no e-mail", {}, async ({ q, k, issue }) => {
  await q(`UPDATE dbo.kyc_basic_info SET email = 'not-an-email' WHERE kyc_basic_info_sno = ${k}`);
  await q(`UPDATE dbo.kyc_contact_info SET contact_email = NULL WHERE kyc_basic_info_sno = ${k}`);
  await expectError(issue(newToken().hash), 58704, "no valid e-mail -> no link");
});
await inTx("issue: no reason", {}, async ({ issue }) => {
  await expectError(issue(newToken().hash, "   "), 58705, "a link needs a reason");
});
await inTx("issue: bad token", {}, async ({ issue }) => {
  await expectError(issue("not-a-sha256"), 58707, "a malformed token hash is refused");
});
await inTx("issue: rate limit", {}, async ({ issue }) => {
  for (let i = 0; i < 5; i += 1) await issue(newToken().hash);
  await expectError(issue(newToken().hash), 58706, "the 6th link in 24 hours is refused");
});

// ───────────────────────────── 3. the open / check rules
await inTx("open: unknown token", {}, async ({ exec }) => {
  await expectError(exec("sp_nt_KycResubmitOpen", { token_hash: [sql.Char(64), newToken().hash] }), 58710, "an unknown token is refused");
});
await inTx("open: expired", {}, async ({ q, exec, issue }) => {
  const t = newToken();
  await issue(t.hash);
  await q(`UPDATE dbo.kyc_resubmit_link SET expires_at = DATEADD(MINUTE, -1, GETDATE()) WHERE token_hash = '${t.hash}'`);
  await expectError(exec("sp_nt_KycResubmitOpen", { token_hash: [sql.Char(64), t.hash] }), 58713, "an expired link is refused");
});
await inTx("open: KYC approved meanwhile", {}, async ({ q, k, exec, issue }) => {
  const t = newToken();
  await issue(t.hash);
  await q(`UPDATE dbo.kyc_basic_info SET status = 'A' WHERE kyc_basic_info_sno = ${k}`);
  await expectError(exec("sp_nt_KycResubmitOpen", { token_hash: [sql.Char(64), t.hash] }), 58714, "a KYC that is no longer rejected cannot be corrected");
});

// ───────────────────────────── 4. the save rules
await inTx("save: duplicate GST", {}, async ({ q, exec, issue, k }) => {
  const other = newKycInput({ gst: "33ZZZZZ9999Z1Z9" });
  await exec("sp_InsertKYCData", { jsonInput: [sql.NVarChar(sql.MAX), JSON.stringify(other)] }); // pending, live
  const t = newToken();
  await issue(t.hash);
  const payload = await correctedPayload(exec, t.hash, { basic: { gst_no: "33ZZZZZ9999Z1Z9" } });
  await expectError(save(exec, t.hash, payload, [{ document_type: "pan_file", document_name: "p.pdf", document_path: "http://x/p.pdf", file_size: 1 }]), 58732, "a GST number already used by a live KYC is refused");
});
await inTx("save: row of another KYC", {}, async ({ exec, issue }) => {
  const t = newToken();
  await issue(t.hash);
  const payload = await correctedPayload(exec, t.hash, {});
  payload.addresses[0].kyc_address_sno = 2147483000;
  await expectError(save(exec, t.hash, payload), 58734, "an address number that is not this KYC's is refused");
});
await inTx("save: nothing left of addresses", {}, async ({ exec, issue }) => {
  const t = newToken();
  await issue(t.hash);
  const payload = await correctedPayload(exec, t.hash, { addresses: [] });
  await expectError(save(exec, t.hash, payload), 58737, "removing every address is refused");
});
await inTx("save: no PAN card", { withPan: false }, async ({ exec, issue }) => {
  const t = newToken();
  await issue(t.hash);
  const payload = await correctedPayload(exec, t.hash, {});
  await expectError(save(exec, t.hash, payload), 58738, "a KYC with no PAN card on file and none uploaded is refused");
});
await inTx("save: missing company name", {}, async ({ exec, issue }) => {
  const t = newToken();
  await issue(t.hash);
  const payload = await correctedPayload(exec, t.hash, { basic: { company_name: "" } });
  await expectError(save(exec, t.hash, payload), 58731, "a missing required company field is refused");
});
await inTx("save: twice with the same link", {}, async ({ exec, issue }) => {
  const t = newToken();
  await issue(t.hash);
  const payload = await correctedPayload(exec, t.hash, {});
  await save(exec, t.hash, payload);
  await expectError(save(exec, t.hash, payload), 58711, "saving a second time with the same link is refused");
});
await inTx("save: portal payment drops the bank accounts", {}, async ({ q, k, exec, issue }) => {
  const t = newToken();
  await issue(t.hash);
  const payload = await correctedPayload(exec, t.hash, { basic: { pay_via_portal: "Y", payment_portal_name: "Their portal", payment_portal_url: "https://pay.example.com" } });
  await save(exec, t.hash, payload);
  const bank = await q(`SELECT is_active FROM dbo.kyc_bank_info WHERE kyc_basic_info_sno = ${k}`);
  check(bank.every((b) => b.is_active === "N"), "paying through a portal deactivates the bank accounts");
});

// ───────────────────────────── 5. what the real backend sends fits the procedure
const { parseResubmitPayload } = await import("../src/KycResubmit/resubmit.validation.js");
await inTx("real validator output", {}, async ({ q, k, exec, issue }) => {
  const t = newToken();
  await issue(t.hash);
  const [head, addresses, banks, contacts, , businessTypes, accountTypes, categories] = await exec("sp_nt_KycResubmitOpen", { token_hash: [sql.Char(64), t.hash] });
  const h = head[0];
  // the form exactly as the page sends it (strings, Y/N flags), then through the same validator the backend runs
  const form = {
    note: "Corrected through the real validator",
    basic: { ...h, company_name: "VERIFY155 VALIDATED", pan_no: h.pan_no.toLowerCase(), gst_no: h.gst_no.toLowerCase() },
    addresses: addresses.map((a) => ({ ...a, state_code: String(a.state_code ?? ""), city: "Salem" })),
    banks: banks.map((b) => ({ ...b, ifsc: b.ifsc.toLowerCase() })),
    contacts,
  };
  const payload = parseResubmitPayload(form, {
    business_types: businessTypes.map((r) => r.value), account_types: accountTypes.map((r) => r.value), supplier_categories: categories.map((r) => r.value),
    business_type: h.business_type, supplier_cat_code: h.supplier_cat_code,
  });
  const [[res]] = await save(exec, t.hash, payload, [{ document_type: "pan_file", document_name: "pan.pdf", document_path: "http://x/p.pdf", file_size: 1 }]);
  check(res.resubmit_count === 1, "the validator's output is accepted by sp_nt_KycResubmitSave");
  const [b] = await q(`SELECT status, company_name, pan_no, gst_no FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = ${k}`);
  check(b.status === "P" && b.company_name === "VERIFY155 VALIDATED" && b.pan_no === h.pan_no.toUpperCase() && b.gst_no === h.gst_no.toUpperCase(), "stored upper-cased PAN / GST, new company name, back to P");
  const [a] = await q(`SELECT city, state_code FROM dbo.kyc_address_info WHERE kyc_basic_info_sno = ${k} AND is_active = 'Y'`);
  check(a.city === "Salem" && a.state_code === 33, "address updated, numeric state code kept");
  const [bk] = await q(`SELECT ifsc FROM dbo.kyc_bank_info WHERE kyc_basic_info_sno = ${k} AND is_active = 'Y'`);
  check(bk.ifsc === "HDFC0001234", "IFSC upper-cased");
});

// ───────────────────────────── 6. the rollback script puts everything back
{
  const rollback = await fs.readFile(path.join(here, "backups", "kyc_resubmit_link_2026-11-07_ROLLBACK.sql"), "utf8");
  const rbBatches = rollback.split(/^\s*GO\s*$/gim).map((b) => b.trim()).filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));
  const tx = new sql.Transaction(pool);
  await tx.begin();
  const q = async (text) => (await new sql.Request(tx).query(text)).recordset;
  const NEW_OBJECTS = "SELECT COUNT(*) AS n FROM sys.objects WHERE name LIKE '%KycResubmit%' OR name IN ('kyc_resubmit_link', 'kyc_resubmission')";
  try {
    for (const b of [...fixBatches, ...batches]) await new sql.Request(tx).batch(b);
    const [{ n }] = await q(NEW_OBJECTS);
    check(n >= 9, "after sql/155 the new objects exist", `(${n})`);
    for (const b of rbBatches) await new sql.Request(tx).batch(b);
    const [{ n: left }] = await q(NEW_OBJECTS);
    check(left === 0, "after the rollback none of them is left", `(${left})`);
    const [d] = await q("SELECT OBJECT_DEFINITION(OBJECT_ID('sp_get_kyc_approval')) AS a, OBJECT_DEFINITION(OBJECT_ID('sp_nt_GetSupplierStatusTimeline')) AS t, OBJECT_DEFINITION(OBJECT_ID('vw_get_all_kyc_info')) AS v");
    check(!/resubmit/i.test(d.a) && !/resubmit|RESUBMITTED/i.test(d.t) && !/ISNULL\(af\.is_active/.test(d.v), "the three changed objects are back to their old definitions");
    const rows = await new sql.Request(tx).query("SELECT TOP 1 * FROM dbo.vw_get_all_kyc_info");
    check(rows.recordset.length === 1 && "kyc_address" in rows.recordset[0], "the view still works after the rollback");
    await new sql.Request(tx).input("Ecno", sql.VarChar(20), "ED001").execute("sp_get_kyc_approval");
    check(true, "sp_get_kyc_approval still runs after the rollback");
  } finally {
    try { await tx.rollback(); } catch { /* nothing to do */ }
  }
  console.log("      (rollback script: rolled back)\n");
}

await pool.close();
console.log(failures ? `\n${failures} CHECK(S) FAILED` : "\nAll checks passed. Nothing was changed in the database.");
process.exit(failures ? 1 : 0);
