/**
 * API Payload Encryption/Decryption Middleware
 *
 * Uses AES-256-GCM (hardware-accelerated, authenticated encryption).
 * The key is derived ONCE at module load via synchronous PBKDF2 —
 * zero per-request key derivation overhead.
 *
 * Must stay in sync with frontend/src/Services/apiCrypto.ts
 *
 * Wire into protected routes after verifyJWT:
 *   app.use("/api/some_route", apiLimiter, verifyJWT, payloadCrypto, router);
 */

import crypto from 'crypto';
import { configDotenv } from 'dotenv';
configDotenv();

// Derive the API payload key once at startup (synchronous — no per-request cost)
const API_PAYLOAD_KEY = crypto.pbkdf2Sync(
  process.env.CRYPTO_SECRET,
  'api-payload-salt',
  1000,
  32,
  'sha256'
);

/**
 * Encrypt a JSON-serialisable value.
 * Returns { d: base64(ciphertext+authTag), iv: base64(12-byte-iv) }
 *
 * Concatenates authTag at the END of ciphertext — matches Web Crypto AES-GCM layout
 * so the frontend can decrypt with crypto.subtle.decrypt directly.
 */
function encryptJson(data) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', API_PAYLOAD_KEY, iv);
  const text = JSON.stringify(data);
  const ciphertext = Buffer.concat([cipher.update(text, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag(); // 16 bytes

  // Layout: ciphertext || tag  (same as Web Crypto output)
  return {
    d: Buffer.concat([ciphertext, tag]).toString('base64'),
    iv: iv.toString('base64'),
  };
}

/**
 * Decrypt a { d, iv } payload produced by the frontend (or encryptJson).
 * d = base64(ciphertext + 16-byte authTag)
 */
function decryptJson(payload) {
  const iv = Buffer.from(payload.iv, 'base64');
  const combined = Buffer.from(payload.d, 'base64');

  // Last 16 bytes = auth tag; everything before = ciphertext
  const tag = combined.subarray(combined.length - 16);
  const ciphertext = combined.subarray(0, combined.length - 16);

  const decipher = crypto.createDecipheriv('aes-256-gcm', API_PAYLOAD_KEY, iv);
  decipher.setAuthTag(tag);

  const decrypted = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  return JSON.parse(decrypted.toString('utf8'));
}

/**
 * Express middleware:
 *  1. Decrypts the request body if it has the encrypted shape { d, iv }.
 *  2. Wraps res.json to encrypt all outgoing JSON responses.
 *
 * Multipart/FormData requests are handled transparently — their bodies
 * will not have the { d, iv } shape so step 1 is a no-op for them.
 */
export function payloadCrypto(req, res, next) {
  // ── Decrypt incoming body ──────────────────────────────────────────────────
  const body = req.body;
  if (
    body &&
    typeof body.d === 'string' &&
    typeof body.iv === 'string' &&
    Object.keys(body).length === 2
  ) {
    try {
      req.body = decryptJson(body);
    } catch {
      return res.status(400).json({ success: false, message: 'Invalid encrypted payload.' });
    }
  }

  // ── Encrypt outgoing JSON responses ───────────────────────────────────────
  const originalJson = res.json.bind(res);
  res.json = function encryptedJson(data) {
    // Restore original immediately to avoid re-wrapping on recursive calls
    res.json = originalJson;
    try {
      return originalJson(encryptJson(data));
    } catch {
      return originalJson(data);
    }
  };

  next();
}
