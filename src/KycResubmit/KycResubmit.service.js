import crypto from "node:crypto";
import KycResubmitRepo from "./KycResubmit.repository.js";
import { ftpUploader } from "../Utils/ImagesUpload/ImgUpload.js";
import { sendKycResubmitEmail, createInAppNotification } from "../Utils/Notify/notifyClient.js";
import { parseResubmitPayload } from "./resubmit.validation.js";
import { inspectUploads, FileRejected, RESUBMIT_DOCUMENT_FIELDS, ALLOWED_EXTENSIONS_TEXT, MAX_FILE_BYTES, MAX_FILES } from "./fileSecurity.js";

const repo = new KycResubmitRepo();

const FTP_FOLDER = "NON_TRADE_DATAS/KYC_DATAS";
const VALID_DAYS = Number(process.env.KYC_RESUBMIT_VALID_DAYS) || 7;

/** 32 random bytes as 43 URL-safe characters. */
const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;
export const newToken = () => crypto.randomBytes(32).toString("base64url");
/** Only this hash is stored: the database never holds a usable link. */
export const hashToken = (token) => crypto.createHash("sha256").update(token).digest("hex").toUpperCase();

function userError(message, status = 400) {
  const err = new Error(message);
  err.userFacing = true;
  err.status = status;
  return err;
}

/** A token that is not even the right shape never reaches the database. */
export function assertTokenShape(token) {
  if (typeof token !== "string" || !TOKEN_RE.test(token)) {
    throw userError("This link is not valid. Open the latest link we e-mailed you, or ask our purchase team to send a new one.", 410);
  }
}

/** Where the correction page lives: KYC_RESUBMIT_BASE_URL, else the origin of the supplier portal URL, else local dev. */
export function resubmitBaseUrl() {
  const explicit = process.env.KYC_RESUBMIT_BASE_URL;
  if (explicit) return explicit.replace(/\/+$/, "");
  try {
    return new URL(process.env.SUPPLIER_PORTAL_URL || "http://localhost:5173/supplier").origin;
  } catch {
    return "http://localhost:5173";
  }
}

/** The token goes after # so it is never sent to a server, never written to an access log and never leaves in a Referer. */
export const resubmitLink = (token) => `${resubmitBaseUrl()}/kyc_resubmit#t=${token}`;

class KycResubmitService {
  /**
   * Makes a link for a rejected KYC and e-mails it to the supplier. Used when an approver rejects (never throws there) and
   * when staff send a new one (throws, so the screen can say why not).
   * @returns {{issued: boolean, emailSent: boolean, sent_to?: string, expires_at?: Date, reason?: string}}
   */
  static async issueAndSend({ kycId, reason, createdBy, throwOnError = false }) {
    let row;
    try {
      const token = newToken();
      row = await repo.issue({ kycId, tokenHash: hashToken(token), reason, createdBy, validDays: VALID_DAYS });
      const mail = await sendKycResubmitEmail({
        to: row.sent_to,
        companyName: row.company_name || "Supplier",
        reason: row.reject_reason,
        link: resubmitLink(token),
        expiresAt: row.expires_at,
      });
      try {
        await repo.markEmail(row.link_sno, mail.sent, mail.sent ? null : mail.reason ?? "mail service unavailable");
      } catch (error) {
        console.error(`[kyc-resubmit] could not record the e-mail result for link ${row.link_sno}:`, error.message);
      }
      return {
        issued: true,
        emailSent: Boolean(mail.sent),
        sent_to: row.sent_to,
        expires_at: row.expires_at,
        ...(mail.sent ? {} : { reason: `The correction link was created but the e-mail was not sent (${mail.reason ?? "mail service unavailable"}). Use "Send new link" to try again.` }),
      };
    } catch (error) {
      if (throwOnError) throw error;
      console.error(`[kyc-resubmit] link for KYC ${kycId} failed:`, error.message);
      return { issued: false, emailSent: false, reason: error.userFacing ? error.message : "The correction link could not be created." };
    }
  }

  static getLinkStatus(kycId) {
    return repo.linkStatus(kycId);
  }

  /** Throws when the link cannot be used. Reads only. */
  static async assertLinkUsable(token) {
    assertTokenShape(token);
    await repo.check(hashToken(token));
  }

  /** What the correction page shows. */
  static async open(token) {
    assertTokenShape(token);
    const [head, addresses, banks, contacts, documents, businessTypes, accountTypes, categories] = await repo.open(hashToken(token));
    const k = head[0];
    return {
      link: { reject_reason: k.reject_reason, rejected_date: k.rejected_date, expires_at: k.expires_at },
      kyc: {
        company_name: k.company_name, legal_name: k.legal_name, trade_name: k.trade_name, contact_person: k.contact_person,
        email: k.email, mobile_number: k.mobile_number, business_type: k.business_type, supplier_cat_code: k.supplier_cat_code,
        pan_no: k.pan_no, is_gst_avail: k.is_gst_avail, gst_no: k.gst_no, is_msme_avail: k.is_msme_avail, msme_no: k.msme_no,
        msme_type: k.msme_type, pay_via_portal: k.pay_via_portal, payment_portal_name: k.payment_portal_name,
        payment_portal_url: k.payment_portal_url, payment_instructions: k.payment_instructions,
      },
      addresses,
      banks,
      contacts,
      // names only: the stored files stay private
      documents: documents.map((d) => ({
        document_type: d.document_type, label: RESUBMIT_DOCUMENT_FIELDS[d.document_type] ?? d.document_type,
        document_name: d.document_name, uploaded_date: d.uploaded_date,
      })),
      choices: { business_types: businessTypes, account_types: accountTypes, supplier_categories: categories },
      uploads: {
        fields: Object.entries(RESUBMIT_DOCUMENT_FIELDS).map(([type, label]) => ({ type, label })),
        allowed: ALLOWED_EXTENSIONS_TEXT,
        max_mb: MAX_FILE_BYTES / 1024 / 1024,
        max_files: MAX_FILES,
      },
    };
  }

  /**
   * Saves the corrected KYC. Order matters: the link, the form and EVERY file are checked first; only then do files go to the
   * FTP server and the database change happen.
   * @param req {{ token, form, files, clientIp }}
   */
  static async save({ token, form, files, clientIp }) {
    assertTokenShape(token);
    const tokenHash = hashToken(token);

    const sets = await repo.open(tokenHash); // also proves the link is usable
    const current = sets[0][0];
    const payload = parseResubmitPayload(form, {
      business_types: sets[5].map((r) => r.value),
      account_types: sets[6].map((r) => r.value),
      supplier_categories: sets[7].map((r) => r.value),
      business_type: current.business_type,
      supplier_cat_code: current.supplier_cat_code,
    });

    const checked = await inspectUploads(files);
    const hasPanOnFile = sets[4].some((d) => d.document_type === "pan_file");
    if (!hasPanOnFile && !checked.some((f) => f.fieldname === "pan_file")) throw new FileRejected("Upload your PAN card.");

    const documents = [];
    for (const f of checked) {
      const url = await ftpUploader.uploadFileIfExists({ originalname: f.originalname, buffer: f.buffer }, FTP_FOLDER);
      if (!url) throw userError("A file could not be stored. Please try again in a few minutes.", 502);
      documents.push({ document_type: f.fieldname, document_name: f.originalname, document_path: url, file_size: f.size });
    }
    const filesJson = checked.map((f) => ({ type: f.fieldname, name: f.originalname, size: f.size, detected: f.kind, sha256: f.sha256, antivirus: f.av }));

    const row = await repo.save({ tokenHash, payload, documents, filesJson, clientIp });

    // Best effort: the KYC is already saved and back with the approver.
    if (row?.approver_ecno) {
      createInAppNotification({
        ecno: String(row.approver_ecno).trim(),
        type: "info",
        title: "KYC corrected and sent again",
        message: `${row.company_name || "A supplier"} corrected its rejected KYC and sent it again for approval (attempt ${row.resubmit_count}). Open KYC Approval to review it.`,
        data: { kind: "kyc_resubmitted", kyc_basic_info_sno: row.kyc_basic_info_sno, screen: "KYCApprovalScreen" },
      }).catch(() => {});
    }
    return row;
  }
}

export default KycResubmitService;
