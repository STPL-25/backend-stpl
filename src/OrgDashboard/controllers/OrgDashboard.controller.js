import OrgDashboardRepository from "../repository/OrgDashboard.repository.js";

const repo = new OrgDashboardRepository();

class OrgDashboardController {
  // GET /api/org_dashboard/overview
  // Staff are identified by ecno and non-staff by login_id - verifyJWT puts whichever applies on req.user_ecno.
  static async getOverview(req, res) {
    try {
      const actor = req.user_ecno;
      if (!actor) return res.status(401).json({ success: false, error: "Not signed in" });
      // Always fresh: this page is live, a cached answer would hide the change that just triggered the refresh.
      res.set("Cache-Control", "no-store");
      const data = await repo.getOverview(actor);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // GET /api/org_dashboard/business
  // The numbers (stock, assets, PR/PO, gate entries, GRN, payments, budget, expenses) a signed-in user sees are limited to the
  // part of the organisation they hold access to: attachHierarchyScope puts their grants on req.hierarchyJson (fail closed: no
  // grants = empty list = the procedure returns zeros). The client sends nothing that could widen it.
  static async getBusinessOverview(req, res) {
    try {
      if (!req.user_ecno) return res.status(401).json({ success: false, error: "Not signed in" });
      res.set("Cache-Control", "no-store");
      const data = await repo.getBusinessOverview(req.hierarchyJson);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default OrgDashboardController;
