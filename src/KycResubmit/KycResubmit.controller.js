import multer from "multer";
import KycResubmitService from "./KycResubmit.service.js";
import { invalidateCache } from "../Middleware/redisCache.js";
import {
  FileRejected, MAX_FILES, MAX_FILE_BYTES, ALLOWED_EXTENSIONS_TEXT, RESUBMIT_DOCUMENT_FIELDS, extensionKind,
} from "./fileSecurity.js";

const GENERIC_ERROR = "Something went wrong on our side. Please try again in a few minutes.";

/** One place that decides what a caller (often anonymous) is allowed to learn about a failure. */
function sendError(res, error) {
  if (error instanceof multer.MulterError) {
    const text = {
      LIMIT_FILE_SIZE: `A file is larger than ${MAX_FILE_BYTES / 1024 / 1024} MB.`,
      LIMIT_FILE_COUNT: `You can upload at most ${MAX_FILES} files at a time.`,
      LIMIT_UNEXPECTED_FILE: "One of the files was sent for a document we do not accept.",
    }[error.code] ?? "The upload could not be read. Please try again.";
    return res.status(error.code === "LIMIT_FILE_SIZE" ? 413 : 400).json({ success: false, error: text });
  }
  if (error?.userFacing) return res.status(error.status ?? 400).json({ success: false, error: error.message });
  console.error("[kyc-resubmit]", error);
  return res.status(500).json({ success: false, error: GENERIC_ERROR });
}

/**
 * multipart parser for the public save. Limits are set so an anonymous caller cannot make the server buffer more than a few MB.
 * The page sends `token` as the FIRST field, so by the time the first file starts the token is known: an unusable link is
 * refused before any file bytes are kept, and a file with the wrong name / extension is refused before it is read.
 */
const parser = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: MAX_FILE_BYTES, files: MAX_FILES, fields: 6, fieldSize: 512 * 1024, parts: MAX_FILES + 6, headerPairs: 40 },
  fileFilter(req, file, cb) {
    if (!Object.hasOwn(RESUBMIT_DOCUMENT_FIELDS, file.fieldname)) {
      return cb(new FileRejected("One of the files was sent for a document we do not accept."));
    }
    if (!extensionKind(file.originalname)) {
      return cb(new FileRejected(`Only ${ALLOWED_EXTENSIONS_TEXT} files can be uploaded.`));
    }
    req.linkCheck ??= KycResubmitService.assertLinkUsable(String(req.body?.token ?? ""));
    req.linkCheck.then(() => cb(null, true), (err) => cb(err));
  },
}).any();

export const parseUpload = (req, res, next) =>
  parser(req, res, (err) => {
    if (err) {
      req.linkCheck?.catch(() => {}); // already handled through `err`
      return sendError(res, err);
    }
    return next();
  });

class KycResubmitController {
  // ── public (the supplier, no login) ────────────────────────────────────────────────────────────

  static async open(req, res) {
    try {
      const data = await KycResubmitService.open(String(req.body?.token ?? ""));
      res.json({ success: true, data });
    } catch (error) {
      sendError(res, error);
    }
  }

  static async save(req, res) {
    try {
      let form;
      try {
        form = JSON.parse(String(req.body?.payload ?? ""));
      } catch {
        throw new FileRejected("The form could not be read. Reload the page and try again.", 400);
      }
      const row = await KycResubmitService.save({
        token: String(req.body?.token ?? ""),
        form,
        files: req.files,
        clientIp: req.ip,
      });

      await invalidateCache(req.redisClient, "kyc:list", "kyc:pending").catch(() => {});
      req.io?.to("kyc:approval").emit("kyc:submitted", { company_name: row?.company_name, created_by: "SUPPLIER", resubmitted: true });

      res.json({
        success: true,
        data: { company_name: row?.company_name },
        message: "Thank you. Your corrected KYC has been sent for approval. We will e-mail you once it is reviewed.",
      });
    } catch (error) {
      sendError(res, error);
    }
  }

  // ── staff (verifyJWT) ───────────────────────────────────────────────────────────────────────────

  /** POST /api/kyc/resubmit/send { kyc_basic_info_sno, reason? } - a new link for a rejected KYC. */
  static async send(req, res) {
    try {
      const ecno = req.user_ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const kycId = Number(req.body?.kyc_basic_info_sno);
      if (!Number.isInteger(kycId) || kycId <= 0) {
        return res.status(400).json({ success: false, error: "kyc_basic_info_sno is required" });
      }
      const reason = String(req.body?.reason ?? "").trim().slice(0, 1000) || undefined;
      const result = await KycResubmitService.issueAndSend({ kycId, reason, createdBy: ecno, throwOnError: true });
      res.json({
        success: true,
        data: result,
        message: result.emailSent ? `A new correction link was e-mailed to ${result.sent_to}` : result.reason,
      });
    } catch (error) {
      if (error?.userFacing) return res.status(error.status === 429 ? 429 : 400).json({ success: false, error: error.message });
      console.error("[kyc-resubmit]", error);
      res.status(500).json({ success: false, error: error.message });
    }
  }

  /** GET /api/kyc/resubmit/status/:kycId - the latest link of a KYC (never the token). */
  static async status(req, res) {
    try {
      const kycId = Number.parseInt(req.params.kycId, 10);
      if (!Number.isInteger(kycId) || kycId <= 0) return res.status(400).json({ success: false, error: "kycId must be a number" });
      const data = await KycResubmitService.getLinkStatus(kycId);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default KycResubmitController;
