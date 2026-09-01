import PRTrackingService from "../services/PRTracking.service.js";

class PRTrackingController {
  static async getMyTracking(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const data = await PRTrackingService.getMyPRTracking(ecno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // Lets the frontend decide whether to render the "Team / Org View" tab at
  // all, without duplicating the permission rule client-side — the org data
  // endpoint below still enforces this independently either way.
  static async canViewOrgTracking(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const allowed = await PRTrackingService.canViewOrgTracking(ecno);
      res.json({ success: true, data: { allowed } });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getOrgTracking(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const allowed = await PRTrackingService.canViewOrgTracking(ecno);
      if (!allowed) {
        return res.status(403).json({ success: false, error: "Not granted access to the org-wide PR tracking view" });
      }

      const { com_sno, div_sno, brn_sno, dept_sno } = req.query;
      if (!com_sno) {
        return res.status(400).json({ success: false, error: "com_sno is required" });
      }

      const data = await PRTrackingService.getOrgPRTracking({
        com_sno: Number(com_sno),
        div_sno: div_sno ? Number(div_sno) : null,
        brn_sno: brn_sno ? Number(brn_sno) : null,
        dept_sno: dept_sno ? Number(dept_sno) : null,
      });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getTimeline(req, res) {
    try {
      const { pr_no } = req.params;
      if (!pr_no) return res.status(400).json({ success: false, error: "pr_no is required" });

      const data = await PRTrackingService.getPRTrackingTimeline(pr_no);
      if (!data.prHeader?.length) {
        return res.status(404).json({ success: false, error: "PR not found" });
      }

      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default PRTrackingController;
