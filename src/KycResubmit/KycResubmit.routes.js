import express from "express";
import { rateLimit } from "express-rate-limit";
import KycResubmitController, { parseUpload } from "./KycResubmit.controller.js";

/**
 * The supplier's correction link - mounted under /api/public_kyc/resubmit (no login, no payload encryption: the gateway and the
 * app already exempt /api/public_kyc). The secret is the link's token: 32 random bytes, stored only as a hash, valid for a
 * few days, spent by the first successful save.
 */
const PublicKycResubmitRouter = express.Router();

const tooMany = (what) => ({ success: false, error: `Too many ${what}. Please wait a while and try again.` });
const openLimiter = rateLimit({ windowMs: 10 * 60_000, limit: 40, standardHeaders: "draft-7", legacyHeaders: false, message: tooMany("attempts") });
const saveLimiter = rateLimit({ windowMs: 60 * 60_000, limit: 12, standardHeaders: "draft-7", legacyHeaders: false, message: tooMany("submissions") });

// the page shows the supplier's own details: never cache it, never leak the page address
PublicKycResubmitRouter.use((req, res, next) => {
  res.set("Cache-Control", "no-store");
  res.set("Referrer-Policy", "no-referrer");
  next();
});

PublicKycResubmitRouter.post("/open", openLimiter, KycResubmitController.open);
PublicKycResubmitRouter.post("/save", saveLimiter, parseUpload, KycResubmitController.save);

export default PublicKycResubmitRouter;
