// node sql/_apply126.mjs           -> dry run (rolls back)
// node sql/_apply126.mjs --commit  -> commits if verification is clean. Always targets Non_Trade.
import sql from "mssql";
import fs from "fs";
import { configDotenv } from "dotenv";
configDotenv();
const commit = process.argv.includes("--commit");
const pool = await new sql.ConnectionPool({
  user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD,
  server: process.env.SERVER, database: "Non_Trade",
  port: 1433, options: { trustServerCertificate: true },
}).connect();
const tx = new sql.Transaction(pool);
await tx.begin();
const run = async (s) => (await new sql.Request(tx).query(s)).recordset;
try {
  console.log("DB:", (await run("SELECT DB_NAME() d"))[0].d);
  const pre = await run(`SELECT (SELECT COUNT(*) FROM approval_route_module) m,(SELECT COUNT(*) FROM approval_route_variant) v,(SELECT COUNT(*) FROM approval_entity_route) r,(SELECT COUNT(*) FROM approval_condition_field) c,(SELECT COUNT(*) FROM entity_master) e,(SELECT COUNT(*) FROM service_type_master) st`);
  console.log("before:", pre[0]);
  if (pre[0].m || pre[0].v || pre[0].r || pre[0].c) throw new Error("tables not empty - refusing");
  await new sql.Request(tx).batch(fs.readFileSync(new URL("./126_seed_approval_routing_prod.sql", import.meta.url), "utf8"));
  const post = await run(`SELECT (SELECT COUNT(*) FROM approval_route_module) m,(SELECT COUNT(*) FROM approval_route_variant) v,(SELECT COUNT(*) FROM approval_entity_route) r,(SELECT COUNT(*) FROM approval_condition_field) c,(SELECT COUNT(*) FROM entity_master) e`);
  console.log("after:", post[0]);
  if (post[0].e !== pre[0].e) throw new Error("entity_master row count changed");
  console.log("routes:", await run(`SELECT module_code,variant_code,entity_code FROM approval_entity_route ORDER BY 1,2`));
  // every route target must exist & be active; every module must resolve
  const bad = await run(`SELECT r.module_code,r.variant_code,r.entity_code FROM approval_entity_route r LEFT JOIN entity_master e ON e.entity_code=r.entity_code AND e.is_active='Y' WHERE e.entity_code IS NULL`);
  if (bad.length) throw new Error("dangling routes: " + JSON.stringify(bad));
  const res = await run(`SELECT v.module_code,v.variant_code,dbo.fn_resolve_approval_entity(v.module_code,v.variant_code) ent FROM vw_approval_route_variant v ORDER BY 1,2`);
  console.log("resolved:", res);
  if (res.some(x => x.ent !== x.module_code && !(x.module_code === "PurchaseRequisition" && x.variant_code === "VENDOR_DRIVEN"))) throw new Error("unexpected resolution");
  const pr = await run(`SELECT dbo.fn_resolve_approval_entity('PurchaseRequisition','NORMAL') a, dbo.fn_resolve_approval_entity('KYC','SUPPLIER') b, dbo.fn_resolve_approval_entity('ServiceAgreement','X') c`);
  console.log("spot:", pr[0]);
  const gr = await run(`EXEC sp_nt_GetApprovalRoutes`);
  console.log("sp_nt_GetApprovalRoutes rows:", gr.length);
  if (commit) { await tx.commit(); console.log("COMMITTED"); } else { await tx.rollback(); console.log("DRY RUN - rolled back"); }
} catch (e) {
  console.log("ERROR:", e.message); try { await tx.rollback(); } catch {} console.log("rolled back");
}
await pool.close();
