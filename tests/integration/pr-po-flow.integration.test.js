// Integration test — mixed Product+Service PR routing, exercised against a
// REAL database connection rather than mocks, because the actual business
// rules for this feature (category persistence, per-line routing,
// consolidation) live in stored procedures, not in the Node.js layer that
// PR.service.test.js already covers with mocks.
//
// SKIPPED BY DEFAULT. This repo has no dedicated test database — every
// database this connects to is the same one real users work in (confirmed
// during this session: accounts KTM1148/SNV11xxx have live PRs/POs here).
// Automatically creating and deleting rows here on every `npm test` run
// risks colliding with real in-flight data (PR/PO numbering sequences,
// approval queues, notification emails) — too risky to run unattended.
//
// To run for real, point this at an actual disposable test database (set
// SERVER/DATABASE/DB_USER/DB_USER_PASSWORD in the environment for a
// non-production instance) and then:
//   RUN_DB_INTEGRATION_TESTS=1 npm test -- --testPathPatterns=integration
//
// Everything this test creates is deleted in its own afterAll, keyed by the
// pr_no/po_no it just created — nothing pre-existing is ever touched.
import { describe, it, expect, beforeAll, afterAll } from "@jest/globals";

const RUN = process.env.RUN_DB_INTEGRATION_TESTS === "1";
const maybeDescribe = RUN ? describe : describe.skip;

maybeDescribe("Mixed PR flow (integration, real DB)", () => {
  let sql, pool;
  let createdPrBasicSno;

  // A real, working (com,div,brn,dept) scope with a configured
  // PurchaseRequisition workflow — verified live during this session
  // (usp_InsertPurchaseRequest succeeds against it without a 50006 throw).
  const ORG_SCOPE = { com_sno: 14, div_sno: 14, brn_sno: 13, dept_sno: 15 };

  beforeAll(async () => {
    sql = (await import("mssql")).default;
    const { configDotenv } = await import("dotenv");
    configDotenv();
    pool = await new sql.ConnectionPool({
      user: process.env.DB_USER,
      password: process.env.DB_USER_PASSWORD,
      server: process.env.SERVER,
      database: process.env.DATABASE,
      port: parseInt(process.env.DB_PORT) || 1433,
      options: { trustServerCertificate: true, enableArithAbort: true },
    }).connect();
  });

  afterAll(async () => {
    if (createdPrBasicSno) {
      // Soft-delete only what this test created — never a hard DELETE
      // against shared data.
      await pool.request()
        .input("sno", sql.Int, createdPrBasicSno)
        .query("UPDATE pr_basic_info SET is_active = 'N' WHERE pr_basic_sno = @sno");
      await pool.request()
        .input("sno", sql.Int, createdPrBasicSno)
        .query("UPDATE pr_item_details SET is_active = 'N' WHERE pr_basic_sno = @sno");
    }
    await pool?.close();
  });

  it("persists category on a mixed Product+Service PR and exposes per-line routing status", async () => {
    // Needs a real prod_sno/unit_sno/service_sno to satisfy usp_InsertPurchaseRequest's
    // item-shape check — pull the first active row of each rather than hardcoding ids
    // that may not exist on whatever DB this points at.
    const [prod, unit, service, priority] = await Promise.all([
      pool.request().query("SELECT TOP 1 prod_sno FROM product_master WHERE prod_active = 'Y'"),
      pool.request().query("SELECT TOP 1 uom_sno FROM uom_master WHERE is_active = 'Y'"),
      pool.request().query(
        "SELECT TOP 1 sm.service_sno FROM service_master sm JOIN service_type_master st ON st.service_type_sno = sm.service_type_sno WHERE st.service_type_code = 'VENDOR_BILL' AND sm.is_active = 'Y'"
      ),
      pool.request().query("SELECT TOP 1 priority_sno FROM priority_master WHERE is_active = 'Y'"),
    ]);
    if (!prod.recordset.length || !unit.recordset.length || !service.recordset.length || !priority.recordset.length) {
      throw new Error("Fixture data missing (product_master/uom_master/service_master/priority_master) — cannot run this integration test on this DB.");
    }

    const payload = {
      basicInfo: {
        ...ORG_SCOPE,
        req_date: new Date().toISOString().slice(0, 10),
        required_date: new Date(Date.now() + 7 * 86400000).toISOString().slice(0, 10),
        purpose: "[integration-test] mixed Civil PR",
        priority_sno: priority.recordset[0].priority_sno,
        requisition_type: "civil_works",
      },
      items: [
        { item_type: "product", prod_sno: prod.recordset[0].prod_sno, unit_sno: unit.recordset[0].uom_sno, qty: 1, est_cost: 100 },
        { item_type: "service", service_sno: service.recordset[0].service_sno, qty: 1 },
      ],
    };

    const result = await pool.request()
      .input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify(payload))
      .output("pr_no", sql.VarChar(20))
      .execute("usp_InsertPurchaseRequest");

    expect(result.recordset[0].Status).toBe("Success");
    const prNo = result.output.pr_no;

    const created = await pool.request()
      .input("pr_no", sql.VarChar(20), prNo)
      .query("SELECT pr_basic_sno, category FROM pr_basic_info WHERE pr_no = @pr_no");
    createdPrBasicSno = created.recordset[0].pr_basic_sno;

    // Gap B: category is now actually persisted (was silently dropped before).
    expect(created.recordset[0].category).toBe("CIVIL");

    // Gap C: routing status is queryable per line — both lines present, both
    // unrouted yet (no PO exists for a PR that was never approved).
    const routing = await pool.request()
      .input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify({ pr_basic_sno: createdPrBasicSno }))
      .execute("sp_nt_GetPrLineRoutingStatus");
    const rows = JSON.parse(routing.recordset[0][Object.keys(routing.recordset[0])[0]]);
    expect(rows).toHaveLength(2);
    expect(rows.map((r) => r.item_type).sort()).toEqual(["product", "service"]);
    expect(rows.every((r) => r.po_basic_sno == null)).toBe(true);
  });
});
