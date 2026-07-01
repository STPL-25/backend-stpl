import POService from "../services/PO.service.js";
import { invalidateCacheByPattern } from "../../Middleware/redisCache.js";

class POController {
  static async getPoRecords(req, res) {
    try {
      const ecno = req.query.ecno;
      const data = await POService.getPoRecords(ecno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async approvePo(req, res) {
    try {
      const { sq_basic_sno, quotation_ref_no, ecno, comments, approval_stages, action } = req.body;

      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      if (!sq_basic_sno || !action) {
        return res.status(400).json({ success: false, error: "sq_basic_sno and action are required" });
      }
      // if (!["approve", "reject"].includes(action)) {
      //   return res.status(400).json({ success: false, error: "action must be 'approve' or 'reject'" });
      // }
      if (action === "reject" && !comments?.trim()) {
        return res.status(400).json({ success: false, error: "comments are required when rejecting" });
      }

      const data = await POService.approvePo({
        sq_basic_sno,
        quotation_ref_no,
        approved_by: ecno,
        comments: comments || "",
        approval_stages,
        action,
      });
      await invalidateCacheByPattern(req.redisClient, "po:list:*");

      // Live update for everyone else on the quotation approval screen
      req.io.to("po:approval").emit("po:approval:updated", {
        sq_basic_sno,
        sq_no: quotation_ref_no,
        action,
        approved_by: ecno,
      });

      res.json({ success: true, data, message: "successfully" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default POController;
