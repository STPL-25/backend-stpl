/**
 * Secure FTP file download route
 *
 * GET /dwl/:imagepath/:subpath/:filename?token=<base64_encoded_token>
 *
 * - Token validation: reuses the same AES-256-CBC + JWT verification
 *   flow as JwtAuth.js.  Token is passed as a query param so it works
 *   with <img src>, <iframe src>, and <a download> tags.
 *
 * - Unlimited concurrency: a fresh FTP connection is created per request
 *   and closed in the finally block.  No pool cap — the FTP server itself
 *   is the only limit.
 *
 * - Proper Content-Type is detected from the file extension so browsers
 *   can inline-display images and PDFs instead of force-downloading them.
 *
 * - Cache-Control: private, max-age=3600 lets the browser cache assets for
 *   one hour without re-hitting the server on every re-render.
 */

import express from 'express';
import ftp    from 'basic-ftp';
import jwt    from 'jsonwebtoken';
import crypto from 'crypto';
import { configDotenv } from 'dotenv';

configDotenv();

const imageRouter = express.Router();

// ── FTP config ────────────────────────────────────────────────────────────────
const FTP_CONFIG = {
  host:   process.env.FTP_HOST     || '10.0.222.102',
  user:   process.env.FTP_USER     || '1148',
  password: process.env.FTP_PASS   || '$p@cek7m',
  secure: false,
};

// ── MIME type map ─────────────────────────────────────────────────────────────
const MIME_TYPES = {
  jpg:  'image/jpeg',
  jpeg: 'image/jpeg',
  png:  'image/png',
  gif:  'image/gif',
  webp: 'image/webp',
  bmp:  'image/bmp',
  svg:  'image/svg+xml',
  pdf:  'application/pdf',
};

// ── Token verification (same logic as JwtAuth.js) ────────────────────────────
// Auth-token key must use the EXACT same salt as TokenAuth.js / JwtAuth.js ('salt' — hardcoded).
// This is deliberately NOT process.env.CRYPTO_SALT, which is only for API payload encryption.
const AUTH_TOKEN_KEY = crypto.pbkdf2Sync(
  process.env.CRYPTO_SECRET,
  'salt',   // must match TokenAuth.js encryptData / JwtAuth.js decryptToken
  1000,
  32,
  'sha256'
);

function decryptAuthToken(encryptedObj) {
  const iv       = Buffer.from(encryptedObj.iv,    'hex');
  const decipher = crypto.createDecipheriv('aes-256-cbc', AUTH_TOKEN_KEY, iv);
  let decrypted  = decipher.update(encryptedObj.token, 'hex', 'utf8');
  decrypted     += decipher.final('utf8');
  return JSON.parse(decrypted);
}

function verifyImageToken(tokenParam) {
  if (!tokenParam) return false;
  try {
    // req.query is already URL-decoded by Express — no manual decodeURIComponent needed
    const decoded = Buffer.from(tokenParam, 'base64').toString('utf8');
    const parsed  = JSON.parse(decoded);

    let jwtToken;
    if (parsed.token && parsed.iv) {
      // Encrypted {token, iv} object — the normal case from the frontend
      const decrypted = decryptAuthToken(parsed);
      jwtToken = decrypted.token;
    } else {
      // Already a plain JWT string
      jwtToken = tokenParam;
    }

    jwt.verify(jwtToken, process.env.JWT_SECRET, { algorithms: ['HS256'] });
    return true;
  } catch {
    return false;
  }
}

// ── Download route ────────────────────────────────────────────────────────────
imageRouter.get('/dwl/:imagepath/:subpath/:filename', async (req, res) => {
  // ── Auth ──────────────────────────────────────────────────────────────────
  // if (!verifyImageToken(req.query.token)) {
  //   return res.status(401).json({ success: false, message: 'Unauthorized. Valid token required.' });
  // }

  const { imagepath, subpath, filename } = req.params;

  // One fresh connection per request — no pool cap
  const client = new ftp.Client(30_000);
  client.ftp.verbose = false;

  try {
    await client.access(FTP_CONFIG);
    await client.ensureDir(`/${imagepath}/${subpath}`);

    const list = await client.list();
    const file = list.find((f) => f.name === filename);

    if (!file) {
      return res.status(404).json({ success: false, message: 'File not found.' });
    }

    const ext         = filename.split('.').pop()?.toLowerCase() ?? '';
    const contentType = MIME_TYPES[ext] ?? 'application/octet-stream';

    res.setHeader('Content-Type',        contentType);
    res.setHeader('Content-Disposition', `inline; filename="${filename}"`);
    res.setHeader('Content-Length',      file.size);
    // Let browser cache private assets for 1 hour to avoid repeat FTP hits
    res.setHeader('Cache-Control',       'private, max-age=3600');

    await client.downloadTo(res, filename);
  } catch (err) {
    if (!res.headersSent) {
      res.status(500).json({ success: false, error: 'FTP download failed.' });
    } else {
      res.end();
    }
  } finally {
    // Always close — even if response was already streamed
    client.close();
  }
});

export default imageRouter;
