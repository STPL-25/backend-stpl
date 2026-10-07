import fs from "node:fs";
const D = process.argv[2];
let out = `-- ============================================================
-- Service PO Terms & Conditions: issue the PO with the T&C master text for the
-- PO's Company/Division/Branch/Department scope (default entry, else oldest
-- active), falling back to the agreement's own terms_conditions. Both service
-- PO issue paths inserted NULL terms before.
-- Database: Non_trade_Dev. Originals: sql/backups/service_po_terms_2026-10-03/
-- ============================================================
`;
const fix = (n, from, to) => {
  let d = fs.readFileSync(D + "/" + n + ".sql", "utf8");
  if (!from.test(d)) throw new Error(n + ": pattern not found");
  d = d.replace(from, to).replace(/CREATE\s+PROCEDURE/i, "CREATE OR ALTER PROCEDURE");
  return d.trimEnd() + "\nGO\n";
};
out += fix("sp_nt_ApproveServicePoCycle",
/(ELSE N'' END,\s*)NULL, NULL,/,
`$1COALESCE(dbo.fn_nt_DefaultTermsText(@com_sno, @div_sno, @brn_sno, @dept_sno),
                             (SELECT NULLIF(LTRIM(RTRIM(terms_conditions)), '') FROM dbo.service_agreement WHERE agreement_sno = @agreement_sno)),
                    NULL,`);
out += fix("sp_nt_DirectIssueServicePO",
/@purpose, NULL, NULL,/,
`@purpose, dbo.fn_nt_DefaultTermsText(@com_sno, @div_sno, @brn_sno, @dept_sno), NULL,`);
fs.writeFileSync("sql/123_service_po_terms_from_master.sql", out);
