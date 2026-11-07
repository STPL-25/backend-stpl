import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";
let mssqlPool = await initializeDatabase();

class OrgDashboardRepository {
  /**
   * One call to sp_nt_GetOrgAccessDashboard (sql/152). The procedure decides what `actor` may see - the Node layer only
   * passes the identity taken from the verified session, never anything the client sent.
   */
  async getOverview(actor) {
    try {
      const request = mssqlPool.request();
      request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify({ ecno: actor }));
      const result = await request.execute("sp_nt_GetOrgAccessDashboard");
      const [meta, nodes, nodeUsers, users, grants, unassigned] = result.recordsets;
      return {
        meta: meta?.[0] ?? {},
        nodes: nodes ?? [],
        node_users: nodeUsers ?? [],
        users: users ?? [],
        grants: grants ?? [],
        unassigned: unassigned ?? [],
      };
    } catch (error) {
      throw new Error(`Error loading the organisation dashboard: ${error.message}`);
    }
  }

  /**
   * One call to sp_nt_GetBusinessDashboard (sql/153). `hierarchy` is the caller's own grants (req.hierarchyJson, from
   * sp_nt_GetUserHierarchy) - an empty list sees nothing, the procedure never treats it as "unfiltered".
   */
  async getBusinessOverview(hierarchy) {
    try {
      const request = mssqlPool.request();
      request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify({ hierarchy: Array.isArray(hierarchy) ? hierarchy : [] }));
      const result = await request.execute("sp_nt_GetBusinessDashboard");
      const [meta, kpi, monthly, breakdown, topItems, assetsByDept, budgets, payments, expenses, expenseByVendor, agreements, expenseMonthlyOrg] = result.recordsets;
      return {
        meta: meta?.[0] ?? {},
        kpi: kpi?.[0] ?? {},
        monthly: monthly ?? [],
        breakdown: breakdown ?? [],
        top_items: topItems ?? [],
        assets_by_dept: assetsByDept ?? [],
        budgets: budgets ?? [],
        payments: payments ?? [],
        expenses: expenses ?? [],
        expense_by_vendor: expenseByVendor ?? [],
        agreements: agreements ?? [],
        expense_monthly_org: expenseMonthlyOrg ?? [],
      };
    } catch (error) {
      throw new Error(`Error loading the business overview: ${error.message}`);
    }
  }
}

export default OrgDashboardRepository;
