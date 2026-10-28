import ServiceGrnService from "../services/ServiceGrn.service.js";
import { createInAppNotification } from "../../Utils/Notify/notifyClient.js";

const notifyApprover = (ecno, row) =>
  createInAppNotification({
    ecno,
    type: "approval",
    title: "Service GRN awaiting your approval",
    message: `${row.grn_no} (${row.po_no ?? "Service PO"}) is waiting for your approval.`,
    data: { kind: "approval_pending", entity_type: "ServiceGRN", entity_id: row.grn_sno, screen: "ServiceGrnPage" },
  }).catch((error) => console.error("Service GRN notification failed:", error.message));

class ServiceGrnController {
  // A department files the GRN for one of its issued Service POs (Fixed or Unfixed). The org (company/division/branch/
  // department) is taken from the PO itself and the approver from that department's 'ServiceGRN' workflow — never from the client.
  static async createServiceGrn(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { po_basic_sno, received_date, remarks } = req.body;
      if (!po_basic_sno || !received_date) {
        return res.status(400).json({ success: false, error: "po_basic_sno and received_date are required" });
      }

      const [data] = await ServiceGrnService.createServiceGrn({
        po_basic_sno: Number(po_basic_sno),
        received_date,
        remarks,
        // entered_by is always the authenticated session's ecno, never client-supplied
        entered_by: ecno,
      });

      req.io?.to("service_grn:updates").emit("service_grn:updated", { grn_sno: data.grn_sno, action: "filed" });
      notifyApprover(data.current_approver_id, { grn_sno: data.grn_sno, grn_no: data.grn_no });

      res.json({ success: true, data });
    } catch (error) {
      console.error("Error in createServiceGrn:", error);
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async approveServiceGrn(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { grn_sno, action, comments } = req.body;
      if (!grn_sno || !action) {
        return res.status(400).json({ success: false, error: "grn_sno and action are required" });
      }

      const [data] = await ServiceGrnService.approveServiceGrn({
        grn_sno: Number(grn_sno),
        action,
        comments,
        // approved_by comes from the session; the SP only lets the GRN's current approver act
        approved_by: ecno,
      });

      req.io?.to("service_grn:updates").emit("service_grn:updated", { grn_sno: Number(grn_sno), action: data.result });
      if (data.result === "APPROVED_NEXT") notifyApprover(data.next_approver, data);

      res.json({ success: true, data });
    } catch (error) {
      console.error("Error in approveServiceGrn:", error);
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getPendingServiceGrnPOs(req, res) {
    try {
      const data = await ServiceGrnService.getPendingServiceGrnPOs({ hierarchy: req.hierarchyJson });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getServiceGrns(req, res) {
    try {
      const data = await ServiceGrnService.getServiceGrns({ hierarchy: req.hierarchyJson, ecno: req.user_ecno });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default ServiceGrnController;
