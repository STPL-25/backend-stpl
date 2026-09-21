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

const SWEEP_INTERVAL_MS = Number(process.env.RECURRING_PR_SWEEP_INTERVAL_MS) || 60 * 60 * 1000; // hourly
const STARTUP_DELAY_MS = 10_000;

async function runRecurringPoSweep() {
  try {
    const { summary, issued } = await repo.processDueRecurringServiceAgreements();
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

async function runAgreementExpirySweep() {
  try {
    const expiredCount = await repo.expireServiceAgreements();
    if (expiredCount > 0) {
      console.log(`Service agreement expiry sweep: flipped ${expiredCount} agreement(s) to Expired.`);
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

function startServiceAgreementScheduledJobs() {
  const sweep = () => {
    runRecurringPoSweep().catch((error) => console.error("Recurring service PO sweep crashed:", error.message));
    runAgreementExpirySweep().catch((error) => console.error("Agreement expiry sweep crashed:", error.message));
    runAgreementNotificationSweep().catch((error) => console.error("Agreement notification sweep crashed:", error.message));
  };

  setTimeout(sweep, STARTUP_DELAY_MS);
  setInterval(sweep, SWEEP_INTERVAL_MS);
  console.log(`Service Agreement scheduled jobs started (sweep every ${SWEEP_INTERVAL_MS}ms, first run in ${STARTUP_DELAY_MS}ms).`);
}

export { startServiceAgreementScheduledJobs, runRecurringPoSweep, runAgreementExpirySweep, runAgreementNotificationSweep };
