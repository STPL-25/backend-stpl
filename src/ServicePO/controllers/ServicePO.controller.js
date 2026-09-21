import ServicePoService from "../services/ServicePo.service.js";
import { dispatchServicePo } from "../../ServiceAgreement/services/ServicePoDispatch.service.js";
import { invalidateCacheByPattern } from "../../Middleware/redisCache.js";

class ServicePoController {
  // Unfixed only — rate/discount/GST entry for a Pending Entry cycle.
  // sp_nt_SubmitServicePoEntry throws if the cycle isn't Pending Entry, or
  // if the entered amount exceeds the agreement's ceiling_amount.
  static async submitServicePoEntry(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { cycle_sno, rate_amount, discount_pct, gst_pct, remarks } = req.body;
      if (!cycle_sno || !rate_amount) {
        return res.status(400).json({ success: false, error: "cycle_sno and rate_amount are required" });
      }

      const data = await ServicePoService.submitServicePoEntry({
        cycle_sno, rate_amount, discount_pct, gst_pct, remarks,
        // submitted_by is always the authenticated session's ecno, never client-supplied
        submitted_by: ecno,
      });

      await invalidateCacheByPattern(req.redisClient, "service_po:list:*");

      req.io.to("service_po:approval").emit("service_po:approval:updated", { cycle_sno, action: "entry_submitted" });

      res.json({ success: true, data });
    } catch (error) {
      console.error("Error in submitServicePoEntry:", error);
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async approveServicePoCycle(req, res) {
    try {
      const { cycle_sno, comments, approval_stages, action } = req.body;
      const ecno = req.user_ecno;

      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      if (!cycle_sno || !action) {
        return res.status(400).json({ success: false, error: "cycle_sno and action are required" });
      }
      if (action === "reject" && !comments?.trim()) {
        return res.status(400).json({ success: false, error: "comments are required when rejecting" });
      }

      const data = await ServicePoService.approveServicePoCycle({
        cycle_sno,
        // approved_by comes from the session, never the request body — a
        // client-supplied ecno would let anyone forge who approved a cycle
        approved_by: ecno,
        comments: comments || "",
        approval_stages,
        action,
      });

      await invalidateCacheByPattern(req.redisClient, "service_po:list:*");

      req.io.to("service_po:approval").emit("service_po:approval:updated", { cycle_sno, action, approved_by: ecno });

      res.json({ success: true, data });

      // Additive-only, fires after the response above is already sent — a
      // dispatch failure must never affect the approval result itself. Same
      // helper the ServiceAgreement flow already uses for the Supplier path.
      // A cycle split across several suppliers raises one PO per supplier
      // (po_basic_snos, comma-separated); each supplier gets their own PO.
      const result = data?.[0];
      const po_basic_snos = String(result?.po_basic_snos ?? result?.po_basic_sno ?? "")
        .split(",")
        .map((s) => Number(s))
        .filter((n) => Number.isInteger(n) && n > 0);
      for (const po_basic_sno of po_basic_snos) {
        dispatchServicePo(po_basic_sno).catch((err) =>
          console.error(`Service PO dispatch failed for PO ${po_basic_sno}:`, err.message)
        );
      }
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getServicePoCycles(req, res) {
    try {
      const data = await ServicePoService.getServicePoCycles(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getServicePoCyclesForApproval(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const data = await ServicePoService.getServicePoCyclesForApproval(ecno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default ServicePoController;
