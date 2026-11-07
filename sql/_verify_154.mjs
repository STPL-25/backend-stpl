// Applies 154 (backend) + 85 (grn-service) inside transactions that are ALWAYS rolled back and exercises the whole RFQ flow
// with real Dev data. Nothing is left behind.   node sql/_verify_154.mjs      (run from the backend-stpl directory)
import fs from "node:fs/promises";
import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv({ quiet: true });
if (process.env.DATABASE !== "Non_trade_Dev") { console.error("Refusing: not Non_trade_Dev"); process.exit(1); }
const pool = await new sql.ConnectionPool({ user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD, server: process.env.SERVER, database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433, options: { trustServerCertificate: true }, requestTimeout: 120000, connectionTimeout: 30000, pool: { max: 1, min: 0 } }).connect();
const split = (s) => s.split(/^\s*GO\s*$/gim).map((b) => b.trim()).filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));
const batches = [
  ...split(await fs.readFile(new URL("./154_rfq.sql", import.meta.url), "utf8")),
  ...split(await fs.readFile(new URL("../../grn-service/sql/86_supplier_rfq_portal.sql", import.meta.url), "utf8")),
];
let failures = 0;
const check = (label, ok, extra = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${label}${extra ? "  " + extra : ""}`); if (!ok) failures++; };
const day = (n) => new Date(Date.now() + n * 864e5).toISOString().slice(0, 10);
const num = (x) => Number(x ?? 0);

// Runs fn inside a fresh transaction (migration applied first) that is rolled back at the end.
async function inTx(name, fn, expectError) {
  console.log(`\n── ${name}`);
  const tx = new sql.Transaction(pool); await tx.begin();
  const R = () => new sql.Request(tx);
  const call = async (sp, obj) => { const rq = R(); rq.input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify(obj)); return await rq.execute(sp); };
  const exec = async (sp, params) => { const rq = R(); for (const [k, v] of Object.entries(params)) rq.input(k, v); return await rq.execute(sp); };
  const q = async (text) => (await R().query(text)).recordset;
  try {
    for (const b of batches) await R().batch(b);
    await fn({ call, exec, q, R });
    if (expectError) check(`${name}: expected "${expectError}" but no error was raised`, false);
  } catch (e) {
    if (expectError) check(`${name}: raises "${expectError}"`, String(e.message).includes(expectError), `(got: ${String(e.message).slice(0, 160)})`);
    else check(`${name}: unexpected error`, false, e.message);
  } finally { try { await tx.rollback(); } catch { /* the procedure already rolled it back */ } }
}

// ── real Dev data
const PR = 5144;
const prItems = (await pool.request().query(`SELECT pr_item_sno, prod_sno, specification, qty, unit FROM pr_item_details WHERE pr_basic_sno=${PR} AND ISNULL(is_active,'Y')='Y' ORDER BY pr_item_sno`)).recordset;
const pr = (await pool.request().query(`SELECT pr_no, com_sno, div_sno, brn_sno, dept_sno, created_by FROM pr_basic_info WHERE pr_basic_sno=${PR}`)).recordset[0];
const noWfPR = (await pool.request().query(`SELECT TOP 1 p.pr_basic_sno, p.pr_no, p.com_sno, p.div_sno, p.brn_sno, p.dept_sno FROM pr_basic_info p WHERE p.pr_basic_sno=5146`)).recordset[0];
console.log("PR", PR, pr.pr_no, "items:", prItems.length, "| PR without workflow:", noWfPR?.pr_no);
const staff = pr.created_by;
const itemsPayload = prItems.map((i) => ({ pr_item_sno: i.pr_item_sno, prod_sno: i.prod_sno, specification: i.specification, qty: Number(i.qty), unit: i.unit }));
const rfqBody = (extra = {}) => ({
  pr_basic_sno: PR, pr_no: pr.pr_no, com_sno: pr.com_sno, div_sno: pr.div_sno, brn_sno: pr.brn_sno, dept_sno: pr.dept_sno,
  response_due_date: day(5), notes: "Please quote your best rate", created_by: staff, vendor_snos: [96, 99, 113], items: itemsPayload, ...extra,
});
// item #2 is not quoted; everything else 100+idx, 10% discount, 18% GST, item #1 carries a Warranty cover
const respBody = (k, rs, rfqItems, extra = {}) => ({
  kyc_basic_info_sno: k, rfq_supplier_sno: rs, valid_upto: day(30), payment_terms: "Net 30", delivery_days: 7, remarks: "ok",
  freight_charges: 100, freight_gst_pct: 18, other_charges: 50, other_charges_gst_pct: 0, submitted_by: "x@y.z",
  items: rfqItems.map((ri, idx) => ({ rfq_item_sno: ri.rfq_item_sno, is_quoted: idx !== 1, unit_price: 100 + idx, discount_pct: 10, tax_pct: 18, delivery_days: 5, remarks: "r",
    additional: idx === 0 ? [{ type: "Warranty", years: 2, cost_type: "Free", terms: "std" }] : [] })), ...extra,
});
const expectedItemsTotal = (rfqItems, items) => items.reduce((s, it, idx) => idx === 1 ? s : s + Math.round(Number(rfqItems[idx].qty) * (100 + idx) * 0.9 * 1.18 * 100) / 100, 0);

// helper: create the standard RFQ and return the ids
async function makeRfq({ call }, body = rfqBody()) {
  const created = (await call("sp_nt_CreateRfq", body)).recordset[0];
  const pay = await call("sp_nt_GetRfqEmailPayload", { rfq_sno: created.rfq_sno });
  const sups = pay.recordsets[1];
  const items = (await call("sp_nt_GetRfqEmailPayload", { rfq_sno: created.rfq_sno })).recordsets[2];
  return { created, pay, sups, sup: (v) => sups.find((s) => s.vendor_sno === v) };
}

// ═════ 1) happy path ═════
await inTx("happy path: send -> view -> submit v1 -> v2 -> revision -> v3 -> take v2 -> close", async ({ call, exec, q, R }) => {
  for (const b of batches) await R().batch(b);                           // a second application must be a no-op
  const { created, pay, sups, sup } = await makeRfq({ call });
  check("RFQ created with a number", /^RFQ-\d{5}$/.test(created.rfq_no), created.rfq_no);
  check("email payload: header + 3 suppliers + items", pay.recordsets[0].length === 1 && sups.length === 3 && pay.recordsets[2].length === prItems.length);
  check("portal login flags (96,99 yes / 113 no)", sup(96).has_login && sup(99).has_login && !sup(113).has_login);
  check("an e-mail address is resolved for every supplier", sups.every((s) => !!s.email_to), JSON.stringify(sups.map((s) => s.email_to)));
  check("due date formatted for the e-mail", /^\d{2} \w{3} \d{4}$/.test(pay.recordsets[0][0].response_due_date), pay.recordsets[0][0].response_due_date);

  await call("sp_nt_SetRfqEmailStatus", { event_by: staff, results: [
    { rfq_supplier_sno: sup(96).rfq_supplier_sno, email_to: sup(96).email_to, sent: true },
    { rfq_supplier_sno: sup(99).rfq_supplier_sno, email_to: sup(99).email_to, sent: false, error: "SMTP not configured" } ] });
  let rfqs = (await exec("sp_nt_GetRfqsForPR", { pr_basic_sno: PR, pr_no: pr.pr_no })).recordset;
  let r = rfqs.find((x) => x.rfq_sno === created.rfq_sno);
  let s = (list, v) => JSON.parse(list.suppliers).find((x) => x.vendor_sno === v);
  check("GetRfqsForPR returns the RFQ with items and suppliers", !!r && JSON.parse(r.items).length === prItems.length && JSON.parse(r.suppliers).length === 3);
  check("email status recorded (96 sent / 99 failed with reason)", s(r, 96).email_sent === "Y" && s(r, 99).email_sent === "N" && /SMTP/.test(s(r, 99).email_error));
  check("dates leave as plain strings", typeof r.response_due_date === "string" && typeof r.created_at === "string");

  const k96 = 96, rs96 = sup(96).rfq_supplier_sno, rs99 = sup(99).rfq_supplier_sno;
  const list96 = (await call("sp_nt_GetRfqsForSupplier", { kyc_basic_info_sno: k96 })).recordset;
  check("supplier 96 sees exactly its own RFQ and can respond", list96.length >= 1 && list96.some((x) => x.rfq_supplier_sno === rs96 && x.can_respond === true));
  check("supplier 99 does not see supplier 96's row", !(await call("sp_nt_GetRfqsForSupplier", { kyc_basic_info_sno: 99 })).recordset.some((x) => x.rfq_supplier_sno === rs96));

  const det = await call("sp_nt_GetRfqDetailForSupplier", { kyc_basic_info_sno: k96, rfq_supplier_sno: rs96 });
  const rfqItems = det.recordsets[1];
  check("detail: header, items, no response yet, no versions, payment terms list", det.recordsets[0].length === 1 && rfqItems.length === prItems.length && det.recordsets[2].length === 0 && det.recordsets[3].length === 0 && det.recordsets[4].length > 0, `terms=${det.recordsets[4].length}`);
  check("opening it marks the supplier row VIEWED", (await q(`SELECT status, first_viewed_at FROM rfq_supplier WHERE rfq_supplier_sno=${rs96}`))[0].status === "VIEWED");

  // v1
  const v1 = (await call("sp_nt_SubmitRfqResponse", respBody(k96, rs96, rfqItems, { quotation_file: "http://files/q1.pdf" }))).recordset[0];
  check("v1 stored", v1.version_no === 1);
  const exp1 = expectedItemsTotal(rfqItems, rfqItems);
  const row1 = (await q(`SELECT items_total, grand_total, quotation_ref_no FROM rfq_response WHERE rfq_response_sno=${v1.rfq_response_sno}`))[0];
  check("v1 items total = qty x price x (1-disc) x (1+GST), unquoted line excluded", Math.abs(num(row1.items_total) - exp1) < 0.05, `${row1.items_total} vs ${exp1.toFixed(2)}`);
  check("v1 grand total adds freight with its GST and the other charge", Math.abs(num(row1.grand_total) - (num(row1.items_total) + 118 + 50)) < 0.05, `${row1.grand_total}`);
  check("default quotation reference is RFQ-no + version", row1.quotation_ref_no === `${created.rfq_no}-V1`, row1.quotation_ref_no);
  check("unquoted line stored with 0 price / not quoted", (await q(`SELECT is_quoted, unit_price FROM rfq_response_item WHERE rfq_response_sno=${v1.rfq_response_sno} AND rfq_item_sno=${rfqItems[1].rfq_item_sno}`))[0].is_quoted === false);
  check("supplier row is SUBMITTED, current = v1", (await q(`SELECT status, response_count, current_response_sno FROM rfq_supplier WHERE rfq_supplier_sno=${rs96}`))[0].status === "SUBMITTED");

  // v2 (re-submission because rates changed)
  const v2 = (await call("sp_nt_SubmitRfqResponse", respBody(k96, rs96, rfqItems, { change_note: "Rates reduced", freight_charges: 0, items: rfqItems.map((ri, idx) => ({ rfq_item_sno: ri.rfq_item_sno, is_quoted: true, unit_price: 90 + idx, discount_pct: 0, tax_pct: 12, delivery_days: 3 })) }))).recordset[0];
  check("v2 stored as a new version", v2.version_no === 2);
  const vers = await exec("sp_nt_GetRfqResponseVersions", { rfq_supplier_sno: rs96 });
  check("both versions kept, newest first, only v2 current", vers.recordsets[0].length === 2 && vers.recordsets[0][0].version_no === 2 && vers.recordsets[0][0].is_current === "Y" && vers.recordsets[0][1].is_current === "N");
  check("v1 prices untouched by v2", JSON.parse(vers.recordsets[0][1].items)[0].unit_price === 100 && JSON.parse(vers.recordsets[0][0].items)[0].unit_price === 90);
  check("v1 Warranty cover kept in additional", JSON.parse(vers.recordsets[0][1].items)[0].additional?.[0]?.type === "Warranty");
  check("audit log has CREATED/VIEWED/SUBMITTED x2", ["CREATED", "VIEWED", "SUBMITTED"].every((t) => vers.recordsets[1].some((l) => l.event_type === t)) && vers.recordsets[1].filter((l) => l.event_type === "SUBMITTED").length === 2);
  check("re-submission without a new document keeps the previous one", vers.recordsets[0][0].quotation_file === "http://files/q1.pdf" && vers.recordsets[0][1].quotation_file === "http://files/q1.pdf");

  // revision
  await call("sp_nt_RequestRfqRevision", { rfq_supplier_sno: rs96, note: "Please add 1% more discount", response_due_date: day(8), requested_by: staff });
  const det2 = await call("sp_nt_GetRfqDetailForSupplier", { kyc_basic_info_sno: k96, rfq_supplier_sno: rs96 });
  check("supplier sees the revision note, can respond, form prefilled with v2", det2.recordsets[0][0].status === "REVISION_REQUESTED" && /1% more/.test(det2.recordsets[0][0].revision_note) && det2.recordsets[0][0].can_respond === true && det2.recordsets[2][0].version_no === 2 && num(det2.recordsets[1][0].unit_price) === 90);
  const v3 = (await call("sp_nt_SubmitRfqResponse", respBody(k96, rs96, det2.recordsets[1], { change_note: "Extra discount given" }))).recordset[0];
  check("v3 stored, revision note cleared", v3.version_no === 3 && (await q(`SELECT revision_note FROM rfq_supplier WHERE rfq_supplier_sno=${rs96}`))[0].revision_note === null);

  // take v2 (an earlier version) as the final quotation
  const v2sno = vers.recordsets[0][0].rfq_response_sno;
  const taken = (await call("sp_nt_TakeRfqResponse", { rfq_response_sno: v2sno, taken_by: staff })).recordset[0];
  check("take: a supplier_quotation_info row was created", !!taken?.sq_basic_sno, JSON.stringify(taken));
  const sq = (await q(`SELECT sq_basic_sno, vendor_sno, pr_basic_sno, pr_no, quotation_ref_no, status, rfq_sno, rfq_response_sno, freight_charges, freight_gst_pct, other_charges, other_charges_gst_pct, payment_terms, delivery_days, workflow_types_id, approver_ecno, com_sno, brn_sno, dept_sno, is_active FROM supplier_quotation_info WHERE sq_basic_sno=${taken.sq_basic_sno}`))[0];
  check("quotation is linked to the RFQ version, carries PR/vendor/org, enters PO approval", sq.rfq_sno === created.rfq_sno && sq.rfq_response_sno === v2sno && sq.vendor_sno === 96 && sq.pr_basic_sno === PR && sq.pr_no === pr.pr_no && sq.status === "P" && !!sq.workflow_types_id && !!sq.approver_ecno && sq.brn_sno === pr.brn_sno, JSON.stringify(sq));
  check("freight GST % copied (the create procedure drops it)", num(sq.freight_gst_pct) === 18 && num(sq.other_charges_gst_pct) === 0 && num(sq.freight_charges) === 0 && num(sq.other_charges) === 50);
  const sqItems = await q(`SELECT prod_sno, unit_price, discount_pct, tax_pct, total_amount, qty FROM supplier_quotation_items WHERE sq_basic_sno=${taken.sq_basic_sno}`);
  check("quotation items = the 4 priced lines of v2", sqItems.length === prItems.length && sqItems.every((i) => num(i.unit_price) >= 90), `${sqItems.length}`);
  const viaPrList = (await exec("sp_nt_GetSupplierQuotations", { pr_basic_sno: PR, pr_no: pr.pr_no })).recordset;
  check("existing quotation list returns the new quotation (with the RFQ link)", viaPrList.some((x) => x.sq_basic_sno === taken.sq_basic_sno && x.rfq_sno === created.rfq_sno));
  check("supplier row is TAKEN", (await q(`SELECT status, taken_response_sno, taken_sq_basic_sno FROM rfq_supplier WHERE rfq_supplier_sno=${rs96}`))[0].taken_sq_basic_sno === taken.sq_basic_sno);

  // supplier 99 declines; 113 untouched
  await call("sp_nt_DeclineRfq", { kyc_basic_info_sno: 99, rfq_supplier_sno: rs99, reason: "Out of stock" });
  check("decline recorded", (await q(`SELECT status, decline_reason FROM rfq_supplier WHERE rfq_supplier_sno=${rs99}`))[0].status === "DECLINED");

  // close
  await call("sp_nt_CloseRfq", { rfq_sno: created.rfq_sno, reason: "Cancelled", closed_by: staff });
  const after = await q(`SELECT vendor_sno, status FROM rfq_supplier WHERE rfq_sno=${created.rfq_sno} ORDER BY vendor_sno`);
  check("close: TAKEN stays, everyone else CLOSED", after.find((x) => x.vendor_sno === 96).status === "TAKEN" && after.find((x) => x.vendor_sno === 99).status === "CLOSED" && after.find((x) => x.vendor_sno === 113).status === "CLOSED");
  check("RFQ itself is cancelled", (await q(`SELECT status FROM rfq_info WHERE rfq_sno=${created.rfq_sno}`))[0].status === "X");

  const contacts = (await exec("sp_nt_GetRfqSupplierContacts", {})).recordset;
  check("supplier contacts list: login flag per approved supplier", contacts.length > 0 && contacts.find((c) => c.vendor_sno === 96).has_login === true && contacts.find((c) => c.vendor_sno === 113).has_login === false);
});

// ═════ 2) every guard, one expected error per transaction ═════
const setup = async (ctx, body) => { const m = await makeRfq(ctx, body); const rsn = m.sup(96).rfq_supplier_sno; const det = await ctx.call("sp_nt_GetRfqDetailForSupplier", { kyc_basic_info_sno: 96, rfq_supplier_sno: rsn }); return { ...m, rsn, rfqItems: det.recordsets[1] }; };

await inTx("v2 without a change note is refused", async (ctx) => {
  const { rsn, rfqItems } = await setup(ctx);
  await ctx.call("sp_nt_SubmitRfqResponse", respBody(96, rsn, rfqItems));
  await ctx.call("sp_nt_SubmitRfqResponse", respBody(96, rsn, rfqItems));
}, "what changed");

await inTx("another supplier cannot open or answer someone else's RFQ", async (ctx) => {
  const { rsn } = await setup(ctx);
  await ctx.call("sp_nt_GetRfqDetailForSupplier", { kyc_basic_info_sno: 99, rfq_supplier_sno: rsn });
}, "not found");

await inTx("submitting after the due date is refused", async (ctx) => {
  const { created, rsn, rfqItems } = await setup(ctx);
  await ctx.q(`UPDATE rfq_info SET response_due_date = DATEADD(day,-1,CAST(GETDATE() AS DATE)) WHERE rfq_sno=${created.rfq_sno}`);
  await ctx.call("sp_nt_SubmitRfqResponse", respBody(96, rsn, rfqItems));
}, "due date");

await inTx("a quoted item without a price is refused", async (ctx) => {
  const { rsn, rfqItems } = await setup(ctx);
  await ctx.call("sp_nt_SubmitRfqResponse", respBody(96, rsn, rfqItems, { items: rfqItems.map((ri) => ({ rfq_item_sno: ri.rfq_item_sno, is_quoted: true, unit_price: 0 })) }));
}, "Quote a price");

await inTx("an item from another RFQ is refused", async (ctx) => {
  const { rsn, rfqItems } = await setup(ctx);
  await ctx.call("sp_nt_SubmitRfqResponse", respBody(96, rsn, rfqItems, { items: [{ rfq_item_sno: 99999999, is_quoted: true, unit_price: 5 }] }));
}, "not part of this request");

await inTx("taking the same supplier twice is refused", async (ctx) => {
  const { rsn, rfqItems } = await setup(ctx);
  const v = (await ctx.call("sp_nt_SubmitRfqResponse", respBody(96, rsn, rfqItems))).recordset[0];
  await ctx.call("sp_nt_TakeRfqResponse", { rfq_response_sno: v.rfq_response_sno, taken_by: staff });
  await ctx.call("sp_nt_TakeRfqResponse", { rfq_response_sno: v.rfq_response_sno, taken_by: staff });
}, "already been taken");

await inTx("a supplier cannot change a quotation that was taken", async (ctx) => {
  const { rsn, rfqItems } = await setup(ctx);
  const v = (await ctx.call("sp_nt_SubmitRfqResponse", respBody(96, rsn, rfqItems))).recordset[0];
  await ctx.call("sp_nt_TakeRfqResponse", { rfq_response_sno: v.rfq_response_sno, taken_by: staff });
  await ctx.call("sp_nt_SubmitRfqResponse", respBody(96, rsn, rfqItems, { change_note: "late change" }));
}, "already been accepted");

await inTx("cannot take while a revision is pending", async (ctx) => {
  const { rsn, rfqItems } = await setup(ctx);
  const v = (await ctx.call("sp_nt_SubmitRfqResponse", respBody(96, rsn, rfqItems))).recordset[0];
  await ctx.call("sp_nt_RequestRfqRevision", { rfq_supplier_sno: rsn, note: "change please", response_due_date: day(4), requested_by: staff });
  await ctx.call("sp_nt_TakeRfqResponse", { rfq_response_sno: v.rfq_response_sno, taken_by: staff });
}, "Only a submitted quotation");

await inTx("revision cannot be requested before the supplier submitted", async (ctx) => {
  const { rsn } = await setup(ctx);
  await ctx.call("sp_nt_RequestRfqRevision", { rfq_supplier_sno: rsn, note: "x", response_due_date: day(4), requested_by: staff });
}, "after the supplier has submitted");

await inTx("taking in a branch/department without an approval workflow gives a clear message", async (ctx) => {
  const body = rfqBody({ pr_basic_sno: noWfPR.pr_basic_sno, pr_no: noWfPR.pr_no, com_sno: noWfPR.com_sno, div_sno: noWfPR.div_sno, brn_sno: noWfPR.brn_sno, dept_sno: noWfPR.dept_sno });
  const { rsn, rfqItems } = await setup(ctx, body);
  const v = (await ctx.call("sp_nt_SubmitRfqResponse", respBody(96, rsn, rfqItems))).recordset[0];
  await ctx.call("sp_nt_TakeRfqResponse", { rfq_response_sno: v.rfq_response_sno, taken_by: staff });
}, "No active approval workflow");

await inTx("RFQ needs at least one supplier", async (ctx) => { await ctx.call("sp_nt_CreateRfq", rfqBody({ vendor_snos: [] })); }, "at least one supplier");
await inTx("RFQ rejects a supplier that is not approved", async (ctx) => { await ctx.call("sp_nt_CreateRfq", rfqBody({ vendor_snos: [96, 999999] })); }, "not an approved supplier");
await inTx("RFQ rejects a past due date", async (ctx) => { await ctx.call("sp_nt_CreateRfq", rfqBody({ response_due_date: day(-2) })); }, "cannot be in the past");
await inTx("RFQ needs items", async (ctx) => { await ctx.call("sp_nt_CreateRfq", rfqBody({ items: [] })); }, "at least one item");

await pool.close();
console.log(failures === 0 ? "\nALL CHECKS PASSED (everything rolled back)" : `\n${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
