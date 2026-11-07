/**
 * Verifies backend sql/157_statutory_due_agreement.sql + grn-service sql/96_statutory_agreement_dues.sql WITHOUT applying them:
 * every case runs in its own transaction that is always rolled back (a procedure error under XACT_ABORT ends the transaction, so
 * each expected error gets a fresh one with both files applied again). Test payees / agreements are created inside the transaction.
 *
 *   cd backend-stpl && node sql/_verify_157.mjs            (add --dump <file> to save real SP output for UI fixtures)
 */
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
const dumpAt = process.argv.indexOf("--dump");
const dumpFile = dumpAt > 0 ? process.argv[dumpAt + 1] : null;

const pool = await new sql.ConnectionPool({
  user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD, server: process.env.SERVER,
  database: process.env.DATABASE, port: parseInt(process.env.DB_PORT) || 1433,
  options: { trustServerCertificate: true, enableArithAbort: true }, requestTimeout: 120000,
}).connect();
console.log(`Database: ${process.env.DATABASE} (every change is rolled back)\n`);

const batchesOf = (text) => text.split(/^\s*GO\s*$/gim).map((b) => b.trim())
  .filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));
const backendBatches = batchesOf(await fs.readFile(path.join(here, "157_statutory_due_agreement.sql"), "utf8"));
const grnBatches = batchesOf(await fs.readFile(path.join(here, "..", "..", "grn-service", "sql", "96_statutory_agreement_dues.sql"), "utf8"));

let failures = 0;
const check = (ok, label, extra = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${label}${extra ? `  ${extra}` : ""}`); if (!ok) failures += 1; };

async function withTx(label, fn) {
  const tx = new sql.Transaction(pool);
  await tx.begin();
  const q = async (text, inputs = {}) => {
    const r = new sql.Request(tx);
    for (const [k, v] of Object.entries(inputs)) r.input(k, v);
    return r.query(text);
  };
  const sp = async (name, json) => {
    const r = new sql.Request(tx);
    r.input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify(json));
    return r.execute(name);
  };
  try {
    for (const b of backendBatches) await q(b);
    for (const b of grnBatches) await q(b);
    await fn({ q, sp, tx });
  } catch (e) {
    check(false, `${label}: unexpected error`, e.message);
  } finally {
    try { await tx.rollback(); } catch { /* already ended by an expected error */ }
  }
}

// an expected error, alone in its own transaction
async function expectError(label, number, fn) {
  const tx = new sql.Transaction(pool);
  await tx.begin();
  const q = async (text) => new sql.Request(tx).query(text);
  const sp = async (name, json) => {
    const r = new sql.Request(tx);
    r.input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify(json));
    return r.execute(name);
  };
  try {
    for (const b of backendBatches) await q(b);
    for (const b of grnBatches) await q(b);
    await fn({ q, sp, setup: true });
    check(false, label, "no error was raised");
  } catch (e) {
    check(e.number === number, label, `-> ${e.number}: ${e.message}`);
  } finally {
    try { await tx.rollback(); } catch { /* ended */ }
  }
}

// ── shared fixtures ──────────────────────────────────────────────────────────
const today = (await pool.request().query("SELECT CONVERT(VARCHAR(10), CAST(GETDATE() AS DATE), 23) AS d")).recordset[0].d;
const [Y, M, D] = today.split("-").map(Number);
if (D > 20) { console.error(`Today is ${today}: the date expectations below assume day <= 20. Re-run early in a month.`); process.exit(3); }
const iso = (y, m, d) => new Date(Date.UTC(y, m - 1, d)).toISOString().slice(0, 10);
const termStart = iso(Y, M - 6, 1), termEnd = iso(Y + 1, M, 0);
const scope = { com_sno: 1, div_sno: 1, brn_sno: 1, dept_sno: 1 };
const monthly = (await pool.request().query("SELECT recurrence_cadence_sno FROM recurrence_cadence_master WHERE cadence_code = 'MONTHLY'")).recordset[0].recurrence_cadence_sno;
const fixedService = (await pool.request().query("SELECT TOP 1 m.service_sno FROM service_master m JOIN service_type_master t ON t.service_type_sno = m.service_type_sno WHERE t.service_type_code = 'FIXED_RECURRING' AND m.is_active = 'Y'")).recordset[0]?.service_sno;
const serviceVendor = (await pool.request().query("SELECT TOP 1 kyc_basic_info_sno AS v FROM kyc_basic_info WHERE vendor_category = 'SERVICE' AND status = 'A' AND is_active = 'Y' ORDER BY kyc_basic_info_sno")).recordset[0]?.v;
console.log(`today ${today}, term ${termStart}..${termEnd}, monthly cadence ${monthly}, fixed service ${fixedService}, service vendor ${serviceVendor}\n`);

const serviceOf = async (q, code) => (await q(`SELECT service_sno FROM service_master WHERE service_code = '${code}'`)).recordset[0]?.service_sno;
const addPayee = async (sp, kind, name, online = true) => (await sp("sp_nt_UpsertStatutoryPayee", online
  ? { kind, payee_name: name, pay_via_portal: "Y", payment_portal_name: `${name} portal`, payment_portal_url: "https://example.gov.in/pay", is_default: "Y", modified_by: "KTM1148" }
  : { kind, payee_name: name, ac_number: "000111222333", ifsc: "SBIN0000001", bank_name: "Test Bank", is_default: "Y", modified_by: "KTM1148" })).recordset[0].payee_sno;
const createStatutory = async (sp, q, { code, due, dd, notify, rate }) => (await sp("sp_nt_CreateServiceAgreement", {
  ...scope, service_sno: await serviceOf(q, code), qty: 7, rate_amount: rate, recurrence_cadence_sno: monthly, po_generation_day: dd,
  notify_days_before: notify, period_start_date: termStart, period_end_date: termEnd, remarks: "verify 157", created_by: "KTM1148", statutory_due: due,
  vendors: [{ vendor_sno: 999999, share_amount: 1 }],   // must be ignored for a Statutory agreement
})).recordset[0];

async function approveFully(q, sp, agreementSno) {
  for (let i = 0; i < 6; i += 1) {
    const row = (await q(`SELECT status, current_approver_id FROM service_agreement WHERE agreement_sno = ${agreementSno}`)).recordset[0];
    if (row.status !== "P") return row.status;
    const pending = (await q(`EXEC sp_nt_GetServiceAgreementsForApproval @Ecno = '${row.current_approver_id}'`)).recordset.find((a) => a.agreement_sno === agreementSno);
    const res = await sp("sp_approve_service_agreement", {
      agreement_sno: agreementSno, action: "approve", approved_by: row.current_approver_id, comments: "verify 157",
      approval_stages: JSON.parse(pending.stage_order_json ?? "[]"),
    });
    const out = res.recordset?.[0];
    if (out?.auto_po_result) console.log(`      approval step ${i + 1} by ${row.current_approver_id}: auto_po_result=${out.auto_po_result}`);
  }
  return (await q(`SELECT status FROM service_agreement WHERE agreement_sno = ${agreementSno}`)).recordset[0].status;
}
const payables = async (sp, kind) => {
  const r = await sp("sp_nt_GetStatutoryPayables", { kind });
  return { amounts: r.recordsets[0], gstHeld: r.recordsets[1], waiting: r.recordsets[2] ?? [] };
};
const dump = {};

// ── 1. the happy path ────────────────────────────────────────────────────────
await withTx("happy path", async ({ q, sp }) => {
  const meta = (await q(`SELECT
      (SELECT is_active FROM service_type_master WHERE service_type_code = 'STATUTORY') AS type_active,
      (SELECT COUNT(*) FROM service_master WHERE service_code LIKE 'STAT-%' AND service_code NOT IN ('STAT-LOAN','STAT-REPO','STAT-CC') AND is_active = 'Y') AS due_services,
      (SELECT COUNT(*) FROM service_master WHERE service_code IN ('STAT-LOAN','STAT-REPO','STAT-CC') AND is_active = 'Y') AS loan_services_on,
      (SELECT is_nullable FROM sys.columns WHERE object_id = OBJECT_ID('service_agreement') AND name = 'vendor_sno') AS vendor_nullable,
      (SELECT definition FROM sys.check_constraints WHERE name = 'CK_statutory_payable_source') AS source_ck,
      (SELECT COUNT(*) FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID('statutory_payable') AND definition LIKE '%source_type%') AS source_cks`)).recordset[0];
  check(meta.type_active === "Y", "STATUTORY service type switched on");
  check(meta.due_services === 5, "5 statutory due services seeded", `(${meta.due_services})`);
  check(meta.loan_services_on === 0, "the 3 loan services stay off");
  check(meta.vendor_nullable === true, "service_agreement.vendor_sno is NULL-able");
  check(/AGREEMENT/.test(meta.source_ck ?? "") && meta.source_cks === 1, "statutory_payable.source_type allows AGREEMENT (one check left)", meta.source_ck);

  // re-running both files on top of themselves must work (re-runnable)
  for (const b of backendBatches) await q(b);
  for (const b of grnBatches) await q(b);
  check(true, "both files re-run cleanly on top of themselves");

  const epfo = await addPayee(sp, "OTHER", "EPFO (test)", true);
  const gstPayee = await addPayee(sp, "GST", "GST dept (test)", false);

  // A: Unfixed PF, due 8 days from today, shown 10 days ahead
  const ddA = D + 8;
  const a = await createStatutory(sp, q, { code: "STAT-PF", dd: ddA, notify: 10, rate: 50000, due: { kind: "OTHER", amount_type: "UNFIXED", payee_sno: epfo, reference_no: "TN/MAS/0012345" } });
  check(/^AGR-\d{4}-\d{4}$/.test(a.agreement_no), "Statutory agreement created without a supplier or document", a.agreement_no);
  const rowA = (await q(`SELECT vendor_sno, qty, agreement_doc_url, status, rate_uom_sno FROM service_agreement WHERE agreement_sno = ${a.agreement_sno}`)).recordset[0];
  check(rowA.vendor_sno === null && Number(rowA.qty) === 1 && rowA.agreement_doc_url === "" && rowA.status === "P", "stored with no supplier, qty forced to 1, empty document, Pending", JSON.stringify(rowA));
  const vendorsA = (await q(`SELECT COUNT(*) n FROM service_agreement_vendor WHERE agreement_sno = ${a.agreement_sno}`)).recordset[0].n;
  check(vendorsA === 0, "the supplier list sent by the client was ignored");
  const dueA = (await q(`SELECT kind, amount_type, payee_sno, reference_no FROM service_agreement_statutory_due WHERE agreement_sno = ${a.agreement_sno}`)).recordset[0];
  check(dueA?.kind === "OTHER" && dueA.amount_type === "UNFIXED" && dueA.payee_sno === epfo && dueA.reference_no === "TN/MAS/0012345", "due block saved", JSON.stringify(dueA));
  const terms = JSON.parse((await q(`SELECT terms_json FROM service_agreement_version WHERE agreement_sno = ${a.agreement_sno} AND version_no = 1`)).recordset[0].terms_json);
  check(terms.statutory_due?.payee_name === "EPFO (test)" && terms.statutory_due?.amount_type === "UNFIXED", "version 1 snapshot keeps the due block", JSON.stringify(terms.statutory_due));

  let p = await payables(sp, "OTHER");
  check(!p.waiting.some((w) => w.agreement_sno === a.agreement_sno), "nothing shows while the agreement is still Pending");

  const statusA = await approveFully(q, sp, a.agreement_sno);
  check(statusA === "A", "approved through the normal agreement approval", statusA);
  const poLog = (await q(`SELECT COUNT(*) n FROM service_agreement_recurring_pr_log WHERE agreement_sno = ${a.agreement_sno}`)).recordset[0].n;
  check(poLog === 0, "no PR / PO was raised for it");

  p = await payables(sp, "OTHER");
  const waitA = p.waiting.filter((w) => w.agreement_sno === a.agreement_sno);
  const expectA = iso(Y, M, ddA);
  check(waitA.length === 1 && waitA[0].due_date.toISOString().slice(0, 10) === expectA, `exactly one due shows, ${expectA} (earlier months are before approval, next month is not in view yet)`,
    JSON.stringify(waitA.map((w) => [w.due_date, w.period_label])));
  check(waitA[0]?.pay_to_name === "EPFO (test)" && waitA[0]?.pay_to_online === "Y" && Number(waitA[0]?.expected_amount) === 50000 && waitA[0]?.ref_no === "TN/MAS/0012345",
    "it shows the payee, the expected amount and the reference", JSON.stringify({ to: waitA[0]?.pay_to_name, exp: waitA[0]?.expected_amount, ref: waitA[0]?.ref_no, label: waitA[0]?.period_label }));
  check(!p.amounts.some((x) => x.agreement_no === a.agreement_no), "no amount is posted before it is entered");

  // B: Fixed ESI, due 3 days from today, shown 5 days ahead -> posted straight away
  const b = await createStatutory(sp, q, { code: "STAT-ESI", dd: D + 3, notify: 5, rate: 12000, due: { kind: "OTHER", amount_type: "FIXED" } });
  check((await approveFully(q, sp, b.agreement_sno)) === "A", "Fixed Statutory agreement approved");
  p = await payables(sp, "OTHER");
  const amtB = p.amounts.filter((x) => x.agreement_no === b.agreement_no);
  check(amtB.length === 1 && Number(amtB[0].amount) === 12000 && amtB[0].source_type === "AGREEMENT" && amtB[0].status === "Open" && amtB[0].agreement_amount_type === "FIXED",
    "Fixed: the due is an Open amount right away, with the agreement amount", JSON.stringify(amtB.map((x) => [x.amount, x.source_type, x.status, x.period_label, x.pay_to_name])));
  check(amtB[0]?.pay_to_name === "EPFO (test)", "no payee on the agreement -> the Others default payee", amtB[0]?.pay_to_name);
  check(!p.waiting.some((w) => w.agreement_sno === b.agreement_sno), "a Fixed due never waits for an amount");

  // the sync is idempotent
  await sp("sp_nt_GetStatutoryPayables", { kind: "OTHER" });
  await q("EXEC sp_nt_SyncStatutoryAgreementDues");
  const counts = (await q(`SELECT agreement_sno, COUNT(*) n FROM statutory_agreement_cycle WHERE agreement_sno IN (${a.agreement_sno}, ${b.agreement_sno}) GROUP BY agreement_sno`)).recordset;
  const postedB = (await q(`SELECT COUNT(*) n FROM statutory_payable WHERE cycle_sno IN (SELECT cycle_sno FROM statutory_agreement_cycle WHERE agreement_sno = ${b.agreement_sno})`)).recordset[0].n;
  check(counts.every((c) => c.n === 1) && postedB === 1, "reading the list again adds nothing twice", JSON.stringify(counts));

  // the GST tab does not see Others dues
  const g = await payables(sp, "GST");
  check(!g.waiting.length && !g.amounts.some((x) => x.source_type === "AGREEMENT"), "the GST tab shows none of the Others dues");

  // enter the Unfixed amount
  const cycleA = waitA[0].cycle_sno;
  const entered = (await sp("sp_nt_EnterStatutoryAgreementAmount", { cycle_sno: cycleA, amount: 48250.5, ref_no: "CHLN-001", entered_by: "KTM1148" })).recordset[0];
  p = await payables(sp, "OTHER");
  const amtA = p.amounts.find((x) => x.stat_sno === entered.stat_sno);
  check(amtA && Number(amtA.amount) === 48250.5 && amtA.status === "Open" && amtA.agreement_no === a.agreement_no && amtA.ref_no === "CHLN-001" && amtA.created_by === "KTM1148",
    "Enter amount: it becomes an Open amount on the Others tab", JSON.stringify(amtA && { amount: amtA.amount, ref: amtA.ref_no, due: amtA.due_date, label: amtA.period_label }));
  check(!p.waiting.some((w) => w.cycle_sno === cycleA), "and leaves the waiting list");

  // cancel it -> waits again; enter again
  await sp("sp_nt_CancelStatutoryPayable", { stat_sno: entered.stat_sno, reason: "typed the wrong amount" });
  p = await payables(sp, "OTHER");
  check(p.waiting.some((w) => w.cycle_sno === cycleA), "Cancel (Unfixed): the due goes back to waiting for its amount");
  const again = (await sp("sp_nt_EnterStatutoryAgreementAmount", { cycle_sno: cycleA, amount: 48000, entered_by: "KTM1148" })).recordset[0];
  check(again.stat_sno !== entered.stat_sno, "the right amount can then be entered");

  // cancel the Fixed one -> skipped, never re-posted
  await sp("sp_nt_CancelStatutoryPayable", { stat_sno: amtB[0].stat_sno, reason: "paid outside the system" });
  await q("EXEC sp_nt_SyncStatutoryAgreementDues");
  const cyB = (await q(`SELECT status, skip_reason FROM statutory_agreement_cycle WHERE agreement_sno = ${b.agreement_sno}`)).recordset[0];
  const openB = (await q(`SELECT COUNT(*) n FROM statutory_payable WHERE status = 'Open' AND cycle_sno IN (SELECT cycle_sno FROM statutory_agreement_cycle WHERE agreement_sno = ${b.agreement_sno})`)).recordset[0].n;
  check(cyB.status === "Skipped" && cyB.skip_reason === "paid outside the system" && openB === 0, "Cancel (Fixed): the due is skipped and not posted again", JSON.stringify(cyB));

  // pay A on the EPFO portal (the existing online-payment path)
  const paid = await sp("sp_nt_RecordStatutoryOnlinePayment", { stat_snos: [again.stat_sno], txn_mode: "Net Banking", txn_id: "TRRN-778899", recorded_by: "KTM1148" });
  const after = (await q(`SELECT status, batch_sno FROM statutory_payable WHERE stat_sno = ${again.stat_sno}`)).recordset[0];
  check(after.status === "Paid" && paid.recordsets[0][0]?.batch_no?.startsWith("SO-"), "it is paid like any other amount (online record SO-...)", `${paid.recordsets[0][0]?.batch_no}`);

  // the agreement list gets the due block
  const dues = (await q("EXEC sp_nt_GetServiceAgreementStatutoryDues")).recordset;
  const dA = dues.find((d) => d.agreement_sno === a.agreement_sno);
  check(dA?.payee_name === "EPFO (test)" && dA?.waiting_count === 0 && dA?.last_due_date, "sp_nt_GetServiceAgreementStatutoryDues: payee, waiting count, last due", JSON.stringify(dA));

  // edit -> back to Pending, nothing new posted meanwhile
  await sp("sp_nt_UpdateServiceAgreement", {
    agreement_sno: a.agreement_sno, ...scope, service_sno: await serviceOf(q, "STAT-PF"), qty: 1, rate_amount: 52000, recurrence_cadence_sno: monthly,
    po_generation_day: ddA, notify_days_before: 12, period_start_date: termStart, period_end_date: termEnd, edited_by: "KTM1148",
    statutory_due: { kind: "OTHER", amount_type: "UNFIXED", payee_sno: null, reference_no: "TN/MAS/0012345" },
  });
  const edited = (await q(`SELECT sa.status, d.payee_sno, (SELECT terms_json FROM service_agreement_version v WHERE v.agreement_sno = sa.agreement_sno AND v.version_no = 2) AS t2
                           FROM service_agreement sa JOIN service_agreement_statutory_due d ON d.agreement_sno = sa.agreement_sno WHERE sa.agreement_sno = ${a.agreement_sno}`)).recordset[0];
  check(edited.status === "P" && edited.payee_sno === null && JSON.parse(edited.t2).statutory_due?.payee_sno == null, "Edit: resubmitted for approval, due block updated, version 2 kept");

  // the reminder sweep still runs and now says what kind of agreement it is
  const rem = await q("EXEC sp_nt_GetAgreementsDueForNotification");
  check(rem.recordset.columns.service_type_code !== undefined, "reminder sweep returns service_type_code", `${rem.recordset.length} row(s)`);

  // the old loan agreements never create a due
  const loanCycles = (await q("SELECT COUNT(*) n FROM statutory_agreement_cycle c JOIN service_agreement_statutory l ON l.agreement_sno = c.agreement_sno")).recordset[0].n;
  check(loanCycles === 0, "the 8 old loan agreements create no due");

  // a GST-tab agreement with a GST payee
  const c = await createStatutory(sp, q, { code: "STAT-PT", dd: D + 2, notify: 3, rate: 2500, due: { kind: "GST", amount_type: "FIXED", payee_sno: gstPayee } });
  await approveFully(q, sp, c.agreement_sno);
  const g2 = await payables(sp, "GST");
  check(g2.amounts.some((x) => x.agreement_no === c.agreement_no && Number(x.amount) === 2500 && x.pay_to_name === "GST dept (test)"), "a GST-tab agreement lands on the GST tab");

  // Fixed / Unfixed service agreements still work (regression)
  if (fixedService && serviceVendor) {
    const f = (await sp("sp_nt_CreateServiceAgreement", {
      ...scope, service_sno: fixedService, qty: 1, rate_amount: 1000, recurrence_cadence_sno: monthly, po_generation_day: 5, notify_days_before: 0,
      period_start_date: termStart, period_end_date: termEnd, agreement_doc_url: "https://example.com/doc.pdf", created_by: "KTM1148",
      vendors: [{ vendor_sno: serviceVendor, share_amount: 1000 }],
    })).recordset[0];
    const fr = (await q(`SELECT vendor_sno, (SELECT COUNT(*) FROM service_agreement_vendor v WHERE v.agreement_sno = ${f.agreement_sno}) AS n,
                         (SELECT COUNT(*) FROM service_agreement_statutory_due d WHERE d.agreement_sno = ${f.agreement_sno}) AS due FROM service_agreement WHERE agreement_sno = ${f.agreement_sno}`)).recordset[0];
    check(fr.vendor_sno === serviceVendor && fr.n === 1 && fr.due === 0, "a Fixed service agreement still saves its supplier and no due block");
  } else check(false, "regression fixture missing (Fixed service or approved service vendor)");

  const list = (await q("EXEC sp_nt_GetServiceAgreements")).recordset.find((r) => r.agreement_sno === a.agreement_sno);
  check(list && list.service_type_code === "STATUTORY" && list.vendor_name === null && list.facility_type === null, "agreement list returns it (no supplier, not a loan)");

  if (dumpFile) {
    const r = await sp("sp_nt_GetStatutoryPayables", { kind: "OTHER" });
    dump.payables = r.recordsets[0]; dump.waiting = r.recordsets[2];
    dump.dues = (await q("EXEC sp_nt_GetServiceAgreementStatutoryDues")).recordset;
    dump.agreements = (await q("EXEC sp_nt_GetServiceAgreements")).recordset.filter((r2) => [a.agreement_sno, b.agreement_sno, c.agreement_sno].includes(r2.agreement_sno));
  }
});

// ── 2. due slots: changing the due day never doubles a month ────────────────
await withTx("slots", async ({ q, sp }) => {
  const a = await createStatutory(sp, q, { code: "STAT-PF", dd: D + 8, notify: 10, rate: 50000, due: { kind: "OTHER", amount_type: "UNFIXED" } });
  await approveFully(q, sp, a.agreement_sno);
  await q("EXEC sp_nt_SyncStatutoryAgreementDues");
  // move the due day two days later (still in view) and re-sync: this month already has its due
  await q(`UPDATE service_agreement SET po_generation_day = ${D + 6} WHERE agreement_sno = ${a.agreement_sno}`);
  await q("EXEC sp_nt_SyncStatutoryAgreementDues");
  const n = (await q(`SELECT COUNT(*) n FROM statutory_agreement_cycle WHERE agreement_sno = ${a.agreement_sno}`)).recordset[0].n;
  check(n === 1, "a changed due day does not add a second due in the same month", `(${n})`);
  // show 40 days ahead -> next month comes into view too
  await q(`UPDATE service_agreement SET notify_days_before = 40 WHERE agreement_sno = ${a.agreement_sno}`);
  await q("EXEC sp_nt_SyncStatutoryAgreementDues");
  const rows = (await q(`SELECT CONVERT(VARCHAR(10), due_date, 23) d, period_label FROM statutory_agreement_cycle WHERE agreement_sno = ${a.agreement_sno} ORDER BY due_date`)).recordset;
  check(rows.length === 2 && rows[1].d === iso(Y, M + 1, D + 6), "next month's due appears once it is in view", JSON.stringify(rows));
  // skip a due
  const cy = (await q(`SELECT TOP 1 cycle_sno FROM statutory_agreement_cycle WHERE agreement_sno = ${a.agreement_sno} ORDER BY due_date DESC`)).recordset[0].cycle_sno;
  await sp("sp_nt_SkipStatutoryAgreementCycle", { cycle_sno: cy, reason: "no employees this month", skipped_by: "KTM1148" });
  const p = await payables(sp, "OTHER");
  check(!p.waiting.some((w) => w.cycle_sno === cy), "Skip: the due leaves the waiting list");
  // switched-off agreement: its waiting dues disappear
  await q(`UPDATE service_agreement SET is_active = 'N' WHERE agreement_sno = ${a.agreement_sno}`);
  const p2 = await payables(sp, "OTHER");
  check(!p2.waiting.some((w) => w.agreement_sno === a.agreement_sno), "a switched-off agreement's dues are not listed");
});

// ── 3. expected errors, one per transaction ─────────────────────────────────
await expectError("Statutory agreement without its payment details -> 58192", 58192, async ({ q, sp }) => {
  await createStatutory(sp, q, { code: "STAT-PF", dd: 10, notify: 5, rate: 100, due: undefined });
});
await expectError("Statutory agreement on the TDS tab -> 58193", 58193, async ({ q, sp }) => {
  await createStatutory(sp, q, { code: "STAT-PF", dd: 10, notify: 5, rate: 100, due: { kind: "TDS", amount_type: "FIXED" } });
});
await expectError("Neither Fixed nor Unfixed -> 58194", 58194, async ({ q, sp }) => {
  await createStatutory(sp, q, { code: "STAT-PF", dd: 10, notify: 5, rate: 100, due: { kind: "OTHER", amount_type: "MAYBE" } });
});
await expectError("A GST payee on an Others agreement -> 58196", 58196, async ({ q, sp }) => {
  const gp = await addPayee(sp, "GST", "GST dept (test)", false);
  await createStatutory(sp, q, { code: "STAT-PF", dd: 10, notify: 5, rate: 100, due: { kind: "OTHER", amount_type: "FIXED", payee_sno: gp } });
});
await expectError("Fixed service agreement without a document still refused -> 58105", 58105, async ({ sp }) => {
  await sp("sp_nt_CreateServiceAgreement", {
    ...scope, service_sno: fixedService, qty: 1, rate_amount: 1000, recurrence_cadence_sno: monthly, po_generation_day: 5,
    period_start_date: termStart, period_end_date: termEnd, created_by: "KTM1148", vendors: [{ vendor_sno: serviceVendor, share_amount: 1000 }],
  });
});
const waitingDue = async (q, sp) => {
  const a = await createStatutory(sp, q, { code: "STAT-PF", dd: D + 8, notify: 10, rate: 50000, due: { kind: "OTHER", amount_type: "UNFIXED" } });
  await approveFully(q, sp, a.agreement_sno);
  return (await payables(sp, "OTHER")).waiting.find((w) => w.agreement_sno === a.agreement_sno).cycle_sno;
};
await expectError("Enter amount 0 -> 57273", 57273, async ({ q, sp }) => {
  const cy = await waitingDue(q, sp);
  await sp("sp_nt_EnterStatutoryAgreementAmount", { cycle_sno: cy, amount: 0, entered_by: "KTM1148" });
});
await expectError("Enter the amount twice -> 57277", 57277, async ({ q, sp }) => {
  const cy = await waitingDue(q, sp);
  await sp("sp_nt_EnterStatutoryAgreementAmount", { cycle_sno: cy, amount: 100, entered_by: "KTM1148" });
  await sp("sp_nt_EnterStatutoryAgreementAmount", { cycle_sno: cy, amount: 100, entered_by: "KTM1148" });
});
await expectError("Enter outside your access -> 57276", 57276, async ({ q, sp }) => {
  const cy = await waitingDue(q, sp);
  await sp("sp_nt_EnterStatutoryAgreementAmount", { cycle_sno: cy, amount: 100, entered_by: "KTM1148", hierarchy: [{ com_sno: 99, div_sno: null, brn_sno: null }] });
});
await expectError("Skip without a reason -> 57279", 57279, async ({ q, sp }) => {
  const cy = await waitingDue(q, sp);
  await sp("sp_nt_SkipStatutoryAgreementCycle", { cycle_sno: cy, skipped_by: "KTM1148" });
});
await expectError("A TDS amount still cannot be cancelled -> 57221", 57221, async ({ q, sp }) => {
  const t = (await q("SELECT TOP 1 stat_sno FROM statutory_payable WHERE source_type = 'TDS' AND status = 'Open'")).recordset[0];
  await sp("sp_nt_CancelStatutoryPayable", { stat_sno: t?.stat_sno ?? -1, reason: "x" });
});

// nothing leaked
const leak = (await pool.request().query(`SELECT OBJECT_ID('dbo.statutory_agreement_cycle') AS t, OBJECT_ID('dbo.service_agreement_statutory_due') AS d,
  (SELECT is_active FROM service_type_master WHERE service_type_code = 'STATUTORY') AS type_active`)).recordset[0];
check(leak.t === null && leak.d === null && leak.type_active === "N", "after the run the database is exactly as before (nothing applied)");

if (dumpFile) { await fs.writeFile(dumpFile, JSON.stringify(dump, null, 2)); console.log(`\nReal SP output saved to ${dumpFile}`); }
await pool.close();
console.log(failures ? `\n${failures} FAILED` : "\nAll checks passed");
process.exit(failures ? 1 : 0);
