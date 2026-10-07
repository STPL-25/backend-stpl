// Recurring service PO generation + Service Agreement expiry + the
// notify-before-generation reminder.
//
// sp_nt_ProcessDueRecurringServiceAgreements (sql/72_service_agreement_rebuild.sql)
// does the whole PR-auto-create+auto-approve, PO-auto-issue cycle
// server-side in one call — this job just polls it periodically. In-process
// interval timer rather than a cron dependency: the "is today a billing
// boundary" logic lives entirely in SQL, so this file stays correct
// regardless of exactly how often it fires.
import ServiceAgreementRepository from "../repository/ServiceAgreement.repository.js";
import { createInAppNotification } from "../../Utils/Notify/notifyClient.js";
import { dispatchServicePo } from "../services/ServicePoDispatch.service.js";

const repo = new ServiceAgreementRepository();

const SWEEP_INTERVAL_MS = Number(process.env.RECURRING_PR_SWEEP_INTERVAL_MS) || 60 * 1000; // every minute — Service PO date alerts must land in real time
const STARTUP_DELAY_MS = 10_000;

async function runRecurringPoSweep(io) {
  try {
    const { summary, issued } = await repo.processDueRecurringServiceAgreements();
    // New PO cycles (Pending Entry / Pending Approval) just appeared — push them to open screens.
    if (summary?.due_count > 0) io?.to("service_po:approval").emit("service_po:approval:updated", { action: "cycle_created" });
    if (summary?.due_count > 0) {
      console.log(
        `Recurring service PO sweep: ${summary.due_count} due, ${summary.success_count} issued, ` +
          `${summary.skipped_count} skipped, ${summary.failed_count} failed.`
      );
      if (summary.failed_count > 0) {
        console.error(
          `Recurring service PO sweep: ${summary.failed_count} agreement(s) failed to issue — ` +
            `check service_agreement_recurring_pr_log WHERE status = 'FAILED'.`
        );
      }
    }

    // Dispatch (email supplier / notify incharge) each PO this run actually
    // issued — same helper the inline final-approval path uses, so every
    // recurring cycle's PO gets sent out too, not just the first one.
    for (const row of issued ?? []) {
      await dispatchServicePo(row.po_basic_sno).catch((err) =>
        console.error(`Service PO dispatch failed for PO ${row.po_basic_sno}:`, err.message)
      );
    }
  } catch (error) {
    console.error("Recurring service PO sweep failed:", error.message);
  }
}

async function runAgreementExpirySweep(io) {
  try {
    const expiredCount = await repo.expireServiceAgreements();
    if (expiredCount > 0) {
      console.log(`Service agreement expiry sweep: flipped ${expiredCount} agreement(s) to Expired.`);
      io?.to("service_agreement:approval").emit("service_agreement:approval:updated", { action: "expired" });
    }
  } catch (error) {
    console.error("Service agreement expiry sweep failed:", error.message);
  }
}

// sp_nt_GetAgreementsDueForNotification claims each due row as PENDING
// before returning it, so a row here is this sweep's exclusive
// responsibility to send-and-report; a crash after the claim just leaves it
// PENDING for a human to notice via service_agreement_notification_log,
// same trade-off the recurring-PO log already accepts.
async function runAgreementNotificationSweep() {
  let due;
  try {
    due = await repo.getAgreementsDueForNotification();
  } catch (error) {
    console.error("Agreement notification sweep failed to fetch due rows:", error.message);
    return;
  }

  for (const row of due) {
    try {
      const result = await createInAppNotification({
        ecno: row.notify_ecno,
        type: "warning",
        title: "Upcoming recurring PO",
        message: `Service Agreement ${row.agreement_no} (${row.service_name}) will auto-generate its next PO on ${new Date(row.due_date).toLocaleDateString("en-IN")}.`,
        data: { agreement_sno: row.agreement_sno, due_date: row.due_date },
      });

      await repo.markAgreementNotificationSent({
        agreement_sno: row.agreement_sno,
        billing_period_start: row.due_date,
        status: result.sent ? "SENT" : "FAILED",
        notif_sno: result.notif?.notif_sno,
        error_message: result.sent ? null : result.reason,
      });

      if (!result.sent) {
        console.error(`Agreement notification for ${row.agreement_no} failed to send: ${result.reason}`);
      }
    } catch (error) {
      console.error(`Agreement notification sweep crashed on agreement ${row.agreement_sno}:`, error.message);
    }
  }
}

// Service PO date alerts (sql/103): on the notification date, on the PO date, and every
// day after the PO date while the PO is still not raised, the approver AND the
// PO-raising department get a bell notification. createInAppNotification stores it and
// pushes it live over Socket.IO (notification:new), so it is real time. Overdue ones are
// type "error" (red in the bell) and say how many days late.
const plural = (n) => `${n} day${n === 1 ? "" : "s"}`;
const ALERT_COPY = {
  NOTIFY_DATE: (r, when) => ({
    type: "warning",
    title: "Upcoming Service PO",
    message: `${r.service_name} (${r.agreement_no}) — PO is due on ${when}. ${
      r.recipient_role === "APPROVER" ? "It will come to you for approval." : "Please get it ready to raise."
    }`,
  }),
  PO_DATE: (r, when) => ({
    type: "info",
    title: "Service PO due today",
    message: `${r.service_name} (${r.agreement_no}) — PO date is ${when} (${r.pr_no ?? "cycle"}). ${
      r.recipient_role === "APPROVER" ? "Please approve it today." : "Please raise it today."
    }`,
  }),
  OVERDUE: (r, when) => ({
    type: "error",
    title: `Service PO overdue — ${plural(r.days_late)} late`,
    message: `${r.service_name} (${r.agreement_no}) — PO date was ${when}, still ${
      r.cycle_status === "PENDING_ENTRY" ? "awaiting rate entry" : "awaiting approval"
    }. ${plural(r.days_late)} late.`,
  }),
};

async function runServicePoAlertSweep(io) {
  let rows;
  try {
    rows = await repo.claimServicePoAlerts();
  } catch (error) {
    console.error("Service PO alert sweep failed to claim alerts:", error.message);
    return;
  }
  if (!rows?.length) return;

  const byAlert = new Map();
  for (const r of rows) {
    if (!byAlert.has(r.alert_sno)) byAlert.set(r.alert_sno, []);
    byAlert.get(r.alert_sno).push(r);
  }

  for (const [alert_sno, recipients] of byAlert) {
    let failed = 0;
    let lastReason = null;
    for (const r of recipients) {
      const when = new Date(r.due_date).toLocaleDateString("en-IN", { timeZone: "UTC" });
      const result = await createInAppNotification({
        ecno: r.recipient_ecno,
        ...ALERT_COPY[r.alert_kind](r, when),
        data: {
          kind: "service_po_alert",
          alert_kind: r.alert_kind,
          severity: r.alert_kind === "OVERDUE" ? "overdue" : "reminder",
          days_late: r.days_late ?? undefined,
          agreement_sno: r.agreement_sno,
          agreement_no: r.agreement_no,
          cycle_sno: r.cycle_sno ?? undefined,
          due_date: r.due_date,
          role: r.recipient_role,
          // clicking the notification opens this screen
          screen: r.recipient_role === "APPROVER" ? "ServicePoApprovalScreen" : "ServicePoPage",
        },
      });
      if (!result.sent) {
        failed += 1;
        lastReason = result.reason;
        console.error(`Service PO alert ${alert_sno} to ${r.recipient_ecno} failed: ${result.reason}`);
      }
    }
    await repo
      .markServicePoAlertSent({
        alert_sno,
        status: failed ? "FAILED" : "SENT",
        recipient_count: recipients.length - failed,
        error_message: failed ? `${failed} of ${recipients.length} failed: ${lastReason}` : null,
      })
      .catch((err) => console.error(`Could not mark service PO alert ${alert_sno}:`, err.message));
  }

  // Service PO lists / approval queues refresh live too.
  io?.to("service_po:approval").emit("service_po:approval:updated", { action: "alert" });
}

// sql/104: every approver is told, once per item, when a PR / PO / quotation / KYC / Service
// Agreement / Service PO / Service Vendor KYC / loan voucher is waiting for them. data.screen
// is the approval screen the bell opens on click.
async function runApprovalNoticeSweep(io) {
  let rows;
  try {
    rows = await repo.claimApprovalNotices();
  } catch (error) {
    console.error("Approval notice sweep failed to claim notices:", error.message);
    return;
  }
  if (!rows?.length) return;

  for (const r of rows) {
    const result = await createInAppNotification({
      ecno: r.recipient_ecno,
      type: "approval",
      title: "Approval pending",
      message: `${r.label} is waiting for your approval.`,
      data: { kind: "approval_pending", entity_type: r.entity_type, entity_id: r.entity_id, screen: r.screen },
    });
    if (!result.sent) console.error(`Approval notice ${r.notice_sno} to ${r.recipient_ecno} failed: ${result.reason}`);
    await repo
      .markApprovalNoticeSent({
        notice_sno: r.notice_sno,
        status: result.sent ? "SENT" : "FAILED",
        error_message: result.sent ? null : result.reason,
      })
      .catch((err) => console.error(`Could not mark approval notice ${r.notice_sno}:`, err.message));
  }
  io?.to("service_po:approval").emit("service_po:approval:updated", { action: "notice" });
}

// The 60s sweep is the safety net; anything that just handed an item to an approver (submit,
// approve onward, forward, send back) calls this so the bell rings within a second or two instead
// of up to a minute later. Safe to call any time — the SP claims each notice exactly once.
function notifyApproversNow(io) {
  setTimeout(() => {
    runApprovalNoticeSweep(io).catch((error) => console.error("Immediate approval notice sweep crashed:", error.message));
  }, 750);
}

// sql/115: when a workflow's approver is replaced, everything pending with the old approver was moved to the
// new one by trigger; here both people are told. The old approver learns who replaced them; the new
// approver learns whose items they now own (clicking opens the approval screen).
async function runApproverChangeNoticeSweep(io) {
  let rows;
  try {
    rows = await repo.claimApproverChangeNotices();
  } catch (error) {
    console.error("Approver-change sweep failed to claim notices:", error.message);
    return;
  }
  if (!rows?.length) return;

  // Live-refresh every open approval list of the affected kind: the old approver's list drops the
  // item and the new approver's list gains it without a page reload (the screens refetch on these).
  const LIVE_REFRESH = {
    PurchaseRequisition: ["pr:approval", "pr:approval:updated"],
    PurchaseOrder: ["po:approval", "po:approval:updated"],
    Quotation: ["po:approval", "po:approval:updated"],
    KYC: ["kyc:approval", "kyc:approval:updated"],
    ServiceAgreement: ["service_agreement:approval", "service_agreement:approval:updated"],
    ServicePO: ["service_po:approval", "service_po:approval:updated"],
    BankPaymentVoucher: ["loan_voucher:approval", "loan_voucher:approval:updated"],
  };
  for (const entityType of new Set(rows.map((r) => r.entity_type))) {
    const target = LIVE_REFRESH[entityType];
    if (target) io?.to(target[0]).emit(target[1], { action: "approver_changed", entity_type: entityType });
  }

  for (const r of rows) {
    const isOld = r.recipient_role === "OLD";
    const result = await createInAppNotification({
      ecno: r.recipient_ecno,
      type: isOld ? "warning" : "approval",
      title: isOld ? "Approver changed" : "Approval reassigned to you",
      message: isOld
        ? `The approver for ${r.label} has been changed: ${r.new_name} (${r.new_ecno}) now replaces you (${r.old_name}). It is no longer in your approval list.`
        : `${r.label} has been reassigned to you — you replace ${r.old_name} (${r.old_ecno}) as approver and it is waiting for your approval.`,
      data: {
        kind: "approver_changed",
        role: r.recipient_role,
        entity_type: r.entity_type,
        entity_id: r.entity_id,
        old_ecno: r.old_ecno,
        new_ecno: r.new_ecno,
        ...(isOld ? {} : { screen: r.screen }),
      },
    });
    if (!result.sent) console.error(`Approver-change notice ${r.notice_sno} to ${r.recipient_ecno} failed: ${result.reason}`);
    await repo
      .markApproverChangeNoticeSent({
        notice_sno: r.notice_sno,
        status: result.sent ? "SENT" : "FAILED",
        error_message: result.sent ? null : result.reason,
      })
      .catch((err) => console.error(`Could not mark approver-change notice ${r.notice_sno}:`, err.message));
  }
}

function startServiceAgreementScheduledJobs(io) {
  const sweep = () => {
    runRecurringPoSweep(io).catch((error) => console.error("Recurring service PO sweep crashed:", error.message));
    runAgreementExpirySweep(io).catch((error) => console.error("Agreement expiry sweep crashed:", error.message));
    // Supersedes runAgreementNotificationSweep (creator-only, notify-date-only); running both
    // would double-notify the creator on the notification date.
    runServicePoAlertSweep(io).catch((error) => console.error("Service PO alert sweep crashed:", error.message));
    runApprovalNoticeSweep(io).catch((error) => console.error("Approval notice sweep crashed:", error.message));
    runApproverChangeNoticeSweep(io).catch((error) => console.error("Approver-change sweep crashed:", error.message));
  };

  setTimeout(sweep, STARTUP_DELAY_MS);
  setInterval(sweep, SWEEP_INTERVAL_MS);
  console.log(`Service Agreement scheduled jobs started (sweep every ${SWEEP_INTERVAL_MS}ms, first run in ${STARTUP_DELAY_MS}ms).`);
}

export { notifyApproversNow, startServiceAgreementScheduledJobs, runRecurringPoSweep, runAgreementExpirySweep, runAgreementNotificationSweep, runServicePoAlertSweep, runApprovalNoticeSweep, runApproverChangeNoticeSweep };
