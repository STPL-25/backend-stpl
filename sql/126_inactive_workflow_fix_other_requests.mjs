// Usage (from backend-stpl): node sql/126_inactive_workflow_fix_other_requests.mjs [apply] [prod]
// Companion to sql/125: other request types (service agreement/bill request/vendor KYC/entry, supplier quotation)
// must not be assigned a deactivated workflow. Dry run unless 'apply'. Dev is always processed; add 'prod' for Non_Trade.
// Rollback: sql/backups/inactive_workflow_fix_2026-10-13/<db>/other_requests/*.sql
import sql from 'mssql'; import fs from 'fs';
const apply = process.argv.includes('apply'), prod = process.argv.includes('prod');
const ACT = `
          AND wt.is_active = 'Y' AND awm.is_active = 'Y'
          AND EXISTS (SELECT 1 FROM dbo.workflow_stage act_ws WHERE act_ws.workflow_types_id = wt.workflow_types_id AND act_ws.is_active = 'Y')`;
const ENT = /(awm\.entity_type\s*=\s*(?:'[^']*'|dbo\.fn_resolve_approval_entity\([^)]*\)))/;
const names = { sp_nt_CreateServiceAgreement:0, sp_nt_UpdateServiceAgreement:0, sp_nt_CreateServiceBillRequest:0,
                sp_nt_CreateServiceVendorKyc:0, sp_nt_CreateServiceEntry:0, sp_nt_CreateSupplierQuotation:1 };
for (const db of ['Non_trade_Dev', ...(prod ? ['Non_Trade'] : [])]) {
  const pool = await new sql.ConnectionPool({user:'admin',password:'admin123',server:'10.0.21.8',port:1433,database:db,options:{trustServerCertificate:true,encrypt:false}}).connect();
  fs.mkdirSync(`sql/backups/inactive_workflow_fix_2026-10-13/${db}/other_requests`, {recursive:true});
  for (const [n, addThrow] of Object.entries(names)) {
    const row = (await pool.request().query(`select definition from sys.sql_modules where object_id=object_id('${n}')`)).recordset[0];
    if (!row) { console.log(db, n, 'not present'); continue; }
    let d = row.definition;
    if (/act_ws/.test(d)) { console.log(db, n, 'already patched'); continue; }
    if (!/workflow_types\s+wt/i.test(d) || !ENT.test(d)) throw new Error(`${n}: lookup shape not recognised`);
    fs.writeFileSync(`sql/backups/inactive_workflow_fix_2026-10-13/${db}/other_requests/${n}.sql`, d);
    d = d.replace(ENT, m => m + ACT);
    if (addThrow) d = d.replace(/(act_ws\.is_active = 'Y'\);)/, `$1\n\n        IF @workflow_types_id IS NULL\n            THROW 52112, N'No active approval workflow is configured for this branch and department.', 1;`);
    if (addThrow && !/52112/.test(d)) throw new Error(n + ': throw not inserted');
    d = d.replace(/CREATE\s+(PROCEDURE|PROC)/i, 'CREATE OR ALTER $1');
    if (apply) { await pool.request().batch(d); console.log(db, n, 'applied'); } else console.log(db, n, 'patch ok (dry)');
  }
  await pool.close();
}
process.exit(0);
