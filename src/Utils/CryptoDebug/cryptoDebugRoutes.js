/**
 * Crypto Debug Routes  (DEVELOPMENT / TESTING ONLY)
 *
 * Available only when NODE_ENV !== "production".
 * Uses the same AES-256-GCM key as payloadCrypto middleware.
 *
 * POST /api/debug/decrypt  — decrypt an encrypted payload { d, iv } → raw JSON
 * POST /api/debug/encrypt  — encrypt a plain JSON body           → { d, iv }
 */

import express from "express";
import crypto from "crypto";
import { configDotenv } from "dotenv";
configDotenv();

const router = express.Router();

// Derive the same key used by payloadCrypto middleware
const API_PAYLOAD_KEY = crypto.pbkdf2Sync(
    process.env.CRYPTO_SECRET,
    process.env.CRYPTO_SALT,
    1000,
    32,
    "sha256"
);

function encryptJson(data) {
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv("aes-256-gcm", API_PAYLOAD_KEY, iv);
    const text = JSON.stringify(data);
    const ciphertext = Buffer.concat([cipher.update(text, "utf8"), cipher.final()]);
    const tag = cipher.getAuthTag();
    return {
        d: Buffer.concat([ciphertext, tag]).toString("base64"),
        iv: iv.toString("base64"),
    };
}

function decryptJson(payload) {
    const iv = Buffer.from(payload.iv, "base64");
    const combined = Buffer.from(payload.d, "base64");
    const tag = combined.subarray(combined.length - 16);
    const ciphertext = combined.subarray(0, combined.length - 16);
    const decipher = crypto.createDecipheriv("aes-256-gcm", API_PAYLOAD_KEY, iv);
    decipher.setAuthTag(tag);
    const decrypted = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
    return JSON.parse(decrypted.toString("utf8"));
}

// Guard — block access in production regardless of how the route was registered
router.use((_req, res, next) => {
    if (process.env.NODE_ENV === "production") {
        return res.status(403).json({ success: false, message: "Debug endpoints are disabled in production." });
    }
    next();
});

/**
 * POST /api/debug/decrypt
 * Body: { d: "<base64>", iv: "<base64>" }
 * Returns the decrypted JSON wrapped in { success, decrypted }
 */
router.post("/decrypt", (req, res) => {
    const { d, iv } = req.body ?? {};

    if (typeof d !== "string" || typeof iv !== "string") {
        return res.status(400).json({
            success: false,
            message: 'Request body must be { d: "<base64 ciphertext+tag>", iv: "<base64 iv>" }',
        });
    }

    try {
        const decrypted = decryptJson({ d, iv });
        return res.json({ success: true, decrypted });
    } catch (err) {
        return res.status(422).json({
            success: false,
            message: "Decryption failed — invalid payload, wrong key, or tampered ciphertext.",
            detail: err.message,
        });
    }
});

/**
 * POST /api/debug/encrypt
 * Body: any valid JSON object / value
 * Returns { success, encrypted: { d, iv } }
 */
router.post("/encrypt", (req, res) => {
    const body = req.body;

    if (body === undefined || body === null) {
        return res.status(400).json({ success: false, message: "Request body must be a valid JSON value." });
    }

    try {
        const encrypted = encryptJson(body);
        return res.json({ success: true, encrypted });
    } catch (err) {
        return res.status(500).json({
            success: false,
            message: "Encryption failed.",
            detail: err.message,
        });
    }
});

export default router;
