import POService from "../services/PO.service.js";
import { invalidateCacheByPattern } from "../../Middleware/redisCache.js";

class POController {
  static async getPoRecords(req, res) {
    try {
      // Identity is never taken from the client — a caller could otherwise
      // pass ?ecno=<someone-else> and read that employee's PO records.
      const ecno = req.user_ecno;
      const data = await POService.getPoRecords(ecno, req.hierarchyJson);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async approvePo(req, res) {
    try {
      const { sq_basic_sno, quotation_ref_no, comments, approval_stages, action } = req.body;
      // approved_by is always the authenticated session's ecno, never a
      // client-supplied value — otherwise anyone could forge the approval
      // audit trail by approving on another employee's behalf.
      const ecno = req.user_ecno;

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

      // Additive PR-tracking push — sp_nt_ApproveSupplierQuotation always
      // returns pr_no, and on FINAL_APPROVED this is also the point a PO
      // gets auto-created, so one event here covers both "Quotation" and
      // "PO Approval" stages.
      const trackPrNo = data?.[0]?.pr_no;
      if (trackPrNo) {
        req.io.to(`pr:track:${trackPrNo}`).emit("pr:track:updated", {
          pr_no: trackPrNo,
          stage: data?.[0]?.is_final === "Y" ? "PO Approval" : "Purchase Quotation",
          status: data?.[0]?.result,
          payload: { sq_basic_sno, is_new_po: data?.[0]?.is_new_po },
        });
      }

      res.json({ success: true, data, message: "successfully" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default POController;
