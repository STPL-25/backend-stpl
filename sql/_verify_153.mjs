// Applies 153 inside ONE transaction that is always rolled back, then calls sp_nt_GetBusinessDashboard for several scopes and
// cross-checks the headline numbers against independent queries. Nothing is left behind.
//   node sql/_verify_153.mjs [--dump <file.json>]      (run from the backend-stpl directory)
import fs from "node:fs/promises";
import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv({ quiet: true });
if (process.env.DATABASE !== "Non_trade_Dev") { console.error("Refusing: not Non_trade_Dev"); process.exit(1); }
const dumpIdx = process.argv.indexOf("--dump");
const dumpFile = dumpIdx > -1 ? process.argv[dumpIdx + 1] : null;
const pool = await new sql.ConnectionPool({ user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD, server: process.env.SERVER, database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433, options: { trustServerCertificate: true }, requestTimeout: 120000, connectionTimeout: 30000, pool: { max: 1, min: 0 } }).connect();
const split = (s) => s.split(/^\s*GO\s*$/gim).map((b) => b.trim()).filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));
const up = split(await fs.readFile(new URL("./153_business_dashboard.sql", import.meta.url), "utf8"));

let failures = 0;
const check = (label, ok, extra = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${label}${extra ? "  " + extra : ""}`); if (!ok) failures++; };
const num = (x) => Number(x ?? 0);
const near = (a, b) => Math.abs(num(a) - num(b)) < 0.01;

const tx = new sql.Transaction(pool); await tx.begin();
try {
  const R = () => new sql.Request(tx);
  for (const b of up) await R().batch(b);
  for (const b of up) await R().batch(b);     // second run must be a no-op
  console.log("applied 153 twice (in a transaction that will be rolled back)");

  const call = async (hierarchy) => {
    const rq = R(); rq.input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify({ hierarchy }));
    const res = await rq.execute("sp_nt_GetBusinessDashboard");
    const [meta, kpi, monthly, breakdown, topItems, assetsByDept, budgets, payments, expenses, expByVendor, agreements, expenseMonthlyOrg] = res.recordsets;
    return { meta: meta[0], kpi: kpi[0], monthly, breakdown, topItems, assetsByDept, budgets, payments, expenses, expByVendor, agreements, expenseMonthlyOrg };
  };
  const one = async (q) => (await R().query(q)).recordset[0];

  // ── scope: nothing / everything ──
  const none = await call([]);
  check("empty hierarchy sees nothing", none.meta.no_scope === 1 && Object.values(none.kpi).every((v) => num(v) === 0) && none.expenses.length === 0 && none.payments.length === 0);

  const comps = (await R().query("SELECT com_sno FROM dbo.company_master")).recordset.map((r) => ({ com_sno: r.com_sno }));
  const all = await call(comps);
  const k = all.kpi;
  console.log("\nKPI (all companies):\n", JSON.stringify(k, null, 1));

  // ── independent cross-checks (whole-company grants cover every row whose com_sno is not NULL) ──
  const c = await one(`
    SELECT (SELECT COUNT(*) FROM dbo.pr_basic_info WHERE ISNULL(is_active,'Y')='Y' AND com_sno IS NOT NULL) pr,
           (SELECT COUNT(*) FROM dbo.pr_basic_info WHERE ISNULL(is_active,'Y')='Y' AND com_sno IS NOT NULL AND status='P') pr_p,
           (SELECT COUNT(*) FROM dbo.po_request_info WHERE ISNULL(is_active,'Y')='Y' AND com_sno IS NOT NULL) po,
           (SELECT COUNT(*) FROM dbo.po_request_info WHERE ISNULL(is_active,'Y')='Y' AND com_sno IS NOT NULL AND service_type_sno IS NOT NULL) po_svc,
           (SELECT ISNULL(SUM(i.total_cost),0) FROM dbo.po_item_details i JOIN dbo.po_request_info p ON p.po_basic_sno=i.po_basic_sno WHERE ISNULL(p.is_active,'Y')='Y' AND p.com_sno IS NOT NULL AND ISNULL(i.is_active,'1') NOT IN ('N','0')) po_val,
           (SELECT COUNT(*) FROM dbo.nt_gate_entry g JOIN dbo.po_request_info p ON p.po_basic_sno=g.po_basic_sno WHERE ISNULL(p.is_active,'Y')='Y' AND p.com_sno IS NOT NULL) ge,
           (SELECT COUNT(*) FROM dbo.nt_gate_entry g JOIN dbo.po_request_info p ON p.po_basic_sno=g.po_basic_sno WHERE ISNULL(p.is_active,'Y')='Y' AND p.com_sno IS NOT NULL AND g.status='GRN Done') ge_done,
           (SELECT COUNT(*) FROM dbo.grn_basic_info WHERE ISNULL(is_active,'Y')='Y' AND com_sno IS NOT NULL AND status IN ('Received','Approved')) grn,
           (SELECT COUNT(*) FROM dbo.payment_info WHERE ISNULL(is_active,'Y')='Y' AND com_sno IS NOT NULL AND status='Pending Approval') pay_w,
           (SELECT ISNULL(SUM(ISNULL(net_paid,amount)),0) FROM dbo.payment_info WHERE ISNULL(is_active,'Y')='Y' AND com_sno IS NOT NULL AND status='Approved') pay_a_amt,
           (SELECT COUNT(*) FROM dbo.payment_info WHERE ISNULL(is_active,'Y')='Y' AND com_sno IS NOT NULL AND status='Processed') pay_s,
           (SELECT COUNT(*) FROM dbo.invoice_info WHERE ISNULL(is_active,'Y')='Y' AND com_sno IS NOT NULL) inv,
           (SELECT ISNULL(SUM(invoice_amount),0) FROM dbo.invoice_info WHERE ISNULL(is_active,'Y')='Y' AND com_sno IS NOT NULL) inv_amt,
           (SELECT ISNULL(SUM(budget),0) FROM (SELECT ISNULL(bud_value_request,0) budget FROM dbo.budget_master WHERE ISNULL(is_active,'Y')='Y' AND com_sno IS NOT NULL) x) bud,
           (SELECT COUNT(*) FROM dbo.nt_inventory_items WHERE com_sno IS NOT NULL) inv_items,
           (SELECT ISNULL(SUM(current_stock),0) FROM dbo.nt_inventory_items WHERE com_sno IS NOT NULL) inv_qty,
           (SELECT COUNT(*) FROM dbo.service_agreement WHERE ISNULL(is_active,'Y')='Y' AND status='A' AND com_sno IS NOT NULL) agr`);
  check("PR total", k.pr_total === c.pr, `${k.pr_total} vs ${c.pr}`);
  check("PR pending", k.pr_pending === c.pr_p, `${k.pr_pending} vs ${c.pr_p}`);
  check("PO total", k.po_total === c.po, `${k.po_total} vs ${c.po}`);
  check("PO service count", k.po_service === c.po_svc && k.po_product === c.po - c.po_svc, `${k.po_service}/${k.po_product}`);
  check("PO value = product + service", near(k.po_value, num(k.po_product_value) + num(k.po_service_value)));
  check("PO value matches independent sum", near(k.po_value, c.po_val), `${k.po_value} vs ${c.po_val}`);
  check("gate entries total", k.gate_total === c.ge, `${k.gate_total} vs ${c.ge}`);
  check("gate entries GRN done", k.gate_grn_done === c.ge_done, `${k.gate_grn_done} vs ${c.ge_done}`);
  check("gate: waiting + done <= total", k.gate_waiting_grn + k.gate_grn_done <= k.gate_total);
  check("GRN done (Received + Approved)", k.grn_done === c.grn, `${k.grn_done} vs ${c.grn}`);
  check("payment waiting count", k.pay_waiting_count === c.pay_w, `${k.pay_waiting_count} vs ${c.pay_w}`);
  check("payment approved amount", near(k.pay_approved_amount, c.pay_a_amt), `${k.pay_approved_amount} vs ${c.pay_a_amt}`);
  check("payment sent count", k.pay_sent_count === c.pay_s, `${k.pay_sent_count} vs ${c.pay_s}`);
  check("expenses recurring + non-recurring = all invoices (count)", k.exp_rec_count + k.exp_non_count === c.inv, `${k.exp_rec_count}+${k.exp_non_count} vs ${c.inv}`);
  check("expenses recurring + non-recurring = all invoices (amount)", near(num(k.exp_rec_amount) + num(k.exp_non_amount), c.inv_amt));
  check("expense list rows == invoice count (<= 500)", all.expenses.length === Math.min(500, c.inv));
  check("expense rows' unpaid = amount - paid - in payment", all.expenses.every((e) => near(e.unpaid, num(e.amount) - num(e.paid) - num(e.in_payment))));
  check("paid never exceeds the invoice", all.expenses.every((e) => num(e.paid) <= num(e.amount) + 0.01), "");
  check("budget total", near(k.bud_all_budget, c.bud), `${k.bud_all_budget} vs ${c.bud}`);
  check("inventory items / qty", k.inv_items === c.inv_items && near(k.inv_qty, c.inv_qty), `${k.inv_items}/${k.inv_qty} vs ${c.inv_items}/${c.inv_qty}`);
  check("inventory value = sum of stock-by-type breakdown", near(k.inv_value, all.breakdown.filter((b) => b.section === "stock_type").reduce((s, b) => s + num(b.amount), 0)));
  check("agreements active", k.agreements_active === c.agr, `${k.agreements_active} vs ${c.agr}`);
  check("asset qty = in use + in service", near(k.asset_qty, num(k.asset_in_use_qty) + num(k.asset_service_qty)));
  check("asset-by-dept qty adds up to the KPI", near(all.assetsByDept.reduce((s, r) => s + num(r.qty), 0), k.asset_qty));
  check("monthly trend has 12 months, oldest first", all.monthly.length === 12 && all.monthly.every((m, i) => i === 0 || new Date(m.month_start) > new Date(all.monthly[i - 1].month_start)));
  check("monthly expense sums <= KPI totals", all.monthly.reduce((s, m) => s + num(m.exp_recurring) + num(m.exp_non_recurring), 0) <= num(k.exp_rec_amount) + num(k.exp_non_amount) + 0.01);
  check("organisation monthly expense rows match the overall monthly trend", near(
    all.expenseMonthlyOrg.reduce((s, m) => s + num(m.total_expense), 0),
    all.monthly.reduce((s, m) => s + num(m.exp_recurring) + num(m.exp_non_recurring), 0)
  ));
  check("payments list: waiting first", (() => { const o = { WAITING: 1, APPROVED: 2, SENT: 3 }; return all.payments.every((p, i) => i === 0 || o[all.payments[i - 1].stage] <= o[p.stage]); })());

  // ── narrower scopes must never show MORE than the whole ──
  const hier = (await R().query("SELECT DISTINCT com_sno, div_sno, brn_sno, dept_sno FROM dbo.pr_basic_info WHERE com_sno IS NOT NULL AND div_sno IS NOT NULL AND brn_sno IS NOT NULL AND dept_sno IS NOT NULL")).recordset;
  console.log(`\n${hier.length} distinct com/div/brn/dept combinations in PRs`);
  let allNarrowOk = true;
  for (const h of hier.slice(0, 6)) {
    const part = await call([h]);
    const pk = part.kpi;
    const ok = pk.pr_total <= k.pr_total && pk.po_total <= k.po_total && num(pk.exp_rec_amount) + num(pk.exp_non_amount) <= num(k.exp_rec_amount) + num(k.exp_non_amount) + 0.01
      && pk.pay_sent_count <= k.pay_sent_count && pk.grn_done <= k.grn_done;
    const prCount = (await one(`SELECT COUNT(*) n FROM dbo.pr_basic_info WHERE ISNULL(is_active,'Y')='Y' AND com_sno=${h.com_sno} AND div_sno=${h.div_sno} AND brn_sno=${h.brn_sno} AND dept_sno=${h.dept_sno}`)).n;
    const ok2 = pk.pr_total === prCount;
    console.log(`  scope ${JSON.stringify(h)} -> PR ${pk.pr_total} (expected ${prCount}), PO ${pk.po_total}, GRN ${pk.grn_done}, inv items ${pk.inv_items}`);
    allNarrowOk = allNarrowOk && ok && ok2;
  }
  check("narrow scopes: PR count exact, nothing exceeds the whole", allNarrowOk);

  // the real user from the memory notes (Canteen-only scope)
  const kt = (await R().query("EXEC sp_nt_GetUserHierarchy @Ecno = 'KTM1006'")).recordset;
  console.log("\nKTM1006 hierarchy:", JSON.stringify(kt));
  if (kt.length) { const t = await call(kt); console.log("KTM1006 KPI:", JSON.stringify(t.kpi)); check("KTM1006 sees no more than everyone", t.kpi.po_total <= k.po_total && t.kpi.pr_total <= k.pr_total); }

  if (dumpFile) { await fs.writeFile(dumpFile, JSON.stringify(all, null, 1)); console.log("dumped real SP output ->", dumpFile); }
  console.log("\nsample rows:");
  console.log(" breakdown:", JSON.stringify(all.breakdown.slice(0, 40)));
  console.log(" budgets:", JSON.stringify(all.budgets));
  console.log(" top items:", JSON.stringify(all.topItems.slice(0, 5)));
  console.log(" assets by dept:", JSON.stringify(all.assetsByDept));
  console.log(" payments[0..3]:", JSON.stringify(all.payments.slice(0, 3)));
  console.log(" expenses[0..3]:", JSON.stringify(all.expenses.slice(0, 3)));
  console.log(" exp by vendor:", JSON.stringify(all.expByVendor));
  console.log(" agreements[0..3]:", JSON.stringify(all.agreements.slice(0, 3)));
  console.log(" monthly expenses by organisation[0..3]:", JSON.stringify(all.expenseMonthlyOrg.slice(0, 3)));
} finally {
  await tx.rollback();
  console.log("\nrolled back - nothing was written");
  await pool.close();
}
console.log(failures ? `\n${failures} CHECK(S) FAILED` : "\nALL CHECKS PASSED");
process.exit(failures ? 1 : 0);
