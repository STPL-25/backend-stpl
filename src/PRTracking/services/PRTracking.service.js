import PRTrackingRepository from "../repository/PRTracking.repository.js";

const repository = new PRTrackingRepository();

// Screen this feature is registered under (sql/29_pr_tracking.sql) — the
// "Team / Org View" tab requires permission_id 7 ("Approve") granted on it,
// on top of base view access, matching the user's own framing: whoever
// manages Role Permissions grants that elevated visibility per person.
const SCREEN_COMP = "PRTrackingPage";
const ORG_VIEW_PERMISSION_ID = 7;

class PRTrackingService {
  async getMyPRTracking(ecno) {
    return repository.getMyPRTracking(ecno);
  }

  async canViewOrgTracking(ecno) {
    return repository.hasScreenPermission(ecno, SCREEN_COMP, ORG_VIEW_PERMISSION_ID);
  }

  async getOrgPRTracking(scope) {
    return repository.getOrgPRTracking(scope);
  }

  async getPRTrackingTimeline(pr_no) {
    const [
      prHeader,
      quotations,
      quotationHistory,
      purchaseOrders,
      poHistory,
      dispatchSlips,
      dispatchDeliveries,
      gateEntries,
      grns,
      grnHistory,
      inventoryMovements,
      approvalStages,
      approvalHistory,
    ] = await repository.getPRTrackingTimeline(pr_no);

    return {
      prHeader,
      quotations,
      quotationHistory,
      purchaseOrders,
      poHistory,
      dispatchSlips,
      dispatchDeliveries,
      gateEntries,
      grns,
      grnHistory,
      inventoryMovements,
      approvalStages,
      approvalHistory,
    };
  }

  async getPrNoByPoBasicSno(po_basic_sno) {
    return repository.getPrNoByPoBasicSno(po_basic_sno);
  }
}

export default new PRTrackingService();
