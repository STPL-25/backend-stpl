import RfqRepository from "../repository/Rfq.repository.js";
import { sendRfqRequestEmail, notifySupplier } from "../../Utils/Notify/notifyClient.js";

const SUPPLIER_PORTAL_URL = process.env.SUPPLIER_PORTAL_URL || "http://localhost:5173/supplier";

const NO_LOGIN_REASON = "No portal login yet - send a portal invite from the KYC screen, then use Resend";
const NO_EMAIL_REASON = "No e-mail address on the supplier's portal login or KYC record";

const badRequest = (message) => Object.assign(new Error(message), { status: 400 });

class RfqService {
  static repo = new RfqRepository();

  /**
   * Creates the RFQ (tables only), then e-mails every invited supplier. The RFQ is saved whatever happens to the
   * mails: each supplier's row keeps its own e-mail outcome, so a failure shows up in the screen with a Resend button
   * instead of losing the request.
   */
  static async createRfq(body, ecno) {
    const created = await this.repo.createRfq({ ...body, created_by: ecno });
    const emails = await this.emailSuppliers({ rfq_sno: created.rfq_sno, kind: "request", by: ecno });
    return { ...created, emails };
  }

  static getRfqs(prBasicSno, prNo) {
    return this.repo.getRfqsForPR(prBasicSno, prNo);
  }

  static getResponseVersions(rfqSupplierSno) {
    return this.repo.getResponseVersions(rfqSupplierSno);
  }

  static getSupplierContacts() {
    return this.repo.getSupplierContacts();
  }

  /** Buyer asks a supplier to revise: status change first (it validates), then the mail. */
  static async requestRevision({ rfq_supplier_sno, note, response_due_date }, ecno) {
    const done = await this.repo.requestRevision({ rfq_supplier_sno, note, response_due_date, requested_by: ecno });
    const emails = await this.emailSuppliers({ rfq_supplier_sno, kind: "revision", by: ecno, revisionNote: note });
    return { ...done, email: emails[0] ?? null };
  }

  /** Sends the mail again - a reminder, or the revision request when that is what the supplier is waiting on. */
  static async resendEmail(rfq_supplier_sno, ecno) {
    const payload = await this.repo.getEmailPayload({ rfq_supplier_sno });
    const supplier = payload.suppliers[0];
    if (!payload.header || !supplier) throw badRequest("Quotation request not found.");
    if (payload.header.status !== "O") throw badRequest("This RFQ is closed.");
    if (["TAKEN", "CLOSED"].includes(supplier.status)) throw badRequest("This supplier can no longer respond to the RFQ.");
    const revision = supplier.status === "REVISION_REQUESTED";
    const emails = await this.emailSuppliers({
      rfq_supplier_sno,
      kind: revision ? "revision" : "reminder",
      by: ecno,
      revisionNote: revision ? supplier.revision_note : undefined,
      payload,
    });
    return { email: emails[0] ?? null };
  }

  static closeRfq({ rfq_sno, reason }, ecno) {
    return this.repo.closeRfq({ rfq_sno, reason, closed_by: ecno });
  }

  /** Turns one submitted version into a normal supplier quotation (see sp_nt_TakeRfqResponse). */
  static takeResponse({ rfq_response_sno }, ecno) {
    return this.repo.takeResponse({ rfq_response_sno, taken_by: ecno });
  }

  /**
   * The supplier's bell for an RFQ request / reminder / revision. Fire-and-forget: a notification
   * problem must never fail (or slow) the RFQ itself. Opens that RFQ's Quotation Entry on click.
   */
  static notifyPortal({ header, supplier, kind, revisionNote }) {
    const due = supplier.due_date || header.response_due_date;
    const dueText = due ? ` Please respond by ${due}.` : "";
    const copy = {
      request: {
        type: "info",
        title: "New quotation request",
        message: `${header.com_name || "A buyer"} has asked you to quote for ${header.rfq_no}.${dueText}`,
      },
      reminder: {
        type: "warning",
        title: "Quotation request reminder",
        message: `${header.rfq_no} is still waiting for your quotation.${dueText}`,
      },
      revision: {
        type: "warning",
        title: "Revised quotation requested",
        message: `${header.rfq_no}: please revise your quotation.${revisionNote ? ` Note: ${revisionNote}` : ""}${dueText}`,
      },
    }[kind];
    if (!copy) return;

    notifySupplier({
      supplier_sno: supplier.vendor_sno,
      ...copy,
      data: { kind: "rfq", view: "rfq-entry", rfq_supplier_sno: supplier.rfq_supplier_sno, rfq_no: header.rfq_no },
    }).catch(() => {});
  }

  /**
   * Mails the suppliers of an RFQ (or one supplier) and records each outcome. Never throws.
   * kind: 'request' | 'reminder' | 'revision'. Suppliers without a portal login are not mailed - they could not act on
   * it - and are reported with the reason instead.
   */
  static async emailSuppliers({ rfq_sno, rfq_supplier_sno, kind, by, revisionNote, payload }) {
    let data = payload;
    try {
      data = data ?? (await this.repo.getEmailPayload({ rfq_sno, rfq_supplier_sno }));
    } catch (error) {
      console.error("RFQ e-mail payload failed:", error.message);
      return [];
    }
    const { header, suppliers, items } = data;
    if (!header) return [];

    const results = [];
    for (const s of suppliers) {
      const base = {
        rfq_supplier_sno: s.rfq_supplier_sno,
        vendor_sno: s.vendor_sno,
        company_name: s.company_name,
        has_login: !!s.has_login,
        email_to: s.email_to ?? null,
      };
      if (!s.has_login) { results.push({ ...base, sent: false, error: NO_LOGIN_REASON }); continue; }
      // Bell inside the portal - independent of the e-mail, so a supplier with no address on file
      // (or a mail that bounces) still sees the request the next time they open the portal.
      this.notifyPortal({ header, supplier: s, kind, revisionNote });
      if (!s.email_to) { results.push({ ...base, sent: false, error: NO_EMAIL_REASON }); continue; }
      try {
        const mail = await sendRfqRequestEmail({
          to: s.email_to,
          companyName: s.company_name || "Supplier",
          rfqNo: header.rfq_no,
          kind,
          dueDate: s.due_date || header.response_due_date,
          notes: header.notes,
          revisionNote,
          buyerCompany: header.com_name,
          items,
          suppCode: s.supp_code,
          portalUrl: SUPPLIER_PORTAL_URL,
        });
        results.push({ ...base, sent: !!mail.sent, error: mail.sent ? undefined : (mail.reason ?? "The e-mail was not sent") });
      } catch (error) {
        results.push({ ...base, sent: false, error: error.message });
      }
    }

    try {
      await this.repo.setEmailStatus({
        event_type: kind === "request" ? "EMAILED" : kind === "reminder" ? "REMINDED" : "REVISION_EMAILED",
        event_by: by,
        results: results.map((r) => ({ rfq_supplier_sno: r.rfq_supplier_sno, email_to: r.email_to, sent: r.sent, error: r.error })),
      });
    } catch (error) {
      console.error("RFQ e-mail status was not recorded:", error.message);
    }
    return results;
  }
}

export default RfqService;
