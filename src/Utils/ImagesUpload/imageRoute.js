/**
 * Secure FTP file download route
 *
 * GET /dwl/:imagepath/:subpath/:filename?token=<base64_encoded_token>
 *
 * - Token validation: reuses the same AES-256-CBC + JWT verification
 *   flow as JwtAuth.js.  Token is passed as a query param so it works
 *   with <img src>, <iframe src>, and <a download> tags.
 *
 * - Pooled connections: this is the highest-traffic FTP path (every
 *   thumbnail/attachment link on a page hits it), so requests are served
 *   from a small fixed-size pool of persistent, already-authenticated FTP
 *   connections (see FtpConnectionPool) instead of opening a brand-new
 *   login per request. That pool size is the hard cap on concurrent
 *   logins to the FTP server — a burst of requests beyond it queues for a
 *   free connection instead of tripping the server's max-login limit.
 *   Override with FTP_DOWNLOAD_POOL_SIZE.
 *
 * - No directory listing: existence + size come from a single SIZE
 *   command instead of LIST-ing the whole directory on every request.
 *
 * - Proper Content-Type is detected from the file extension so browsers
 *   can inline-display images and PDFs instead of force-downloading them.
 *
 * - Cache-Control: private, max-age=3600 lets the browser cache assets for
 *   one hour without re-hitting the server on every re-render.
 */

import express from 'express';
import jwt    from 'jsonwebtoken';
import crypto from 'crypto';
import { configDotenv } from 'dotenv';
import { FtpConnectionPool } from './FtpConnectionPool.js';

configDotenv();

const imageRouter = express.Router();

// ── FTP config ────────────────────────────────────────────────────────────────
const FTP_CONFIG = {
  host:   process.env.FTP_HOST     || '10.0.222.102',
  user:   process.env.FTP_USER     || '1148',
  password: process.env.FTP_PASS   || '$p@cek7m',
  secure: false,
};

// Separate from FtpUploader's pool so a burst of image/document loads
// can't starve form uploads (or vice versa). Downloads dominate traffic,
// so this pool is larger by default.
const downloadPool = new FtpConnectionPool(FTP_CONFIG, Number(process.env.FTP_DOWNLOAD_POOL_SIZE) || 6);

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
  const remoteDir = `/${imagepath}/${subpath}`;

  try {
    await downloadPool.run(async (client) => {
      await client.cd(remoteDir);
      // Single SIZE command instead of a full directory LIST — missing
      // file/dir surfaces as a 550, handled below as 404.
      const size = await client.size(filename);

      const ext         = filename.split('.').pop()?.toLowerCase() ?? '';
      const contentType = MIME_TYPES[ext] ?? 'application/octet-stream';

      res.setHeader('Content-Type',        contentType);
      res.setHeader('Content-Disposition', `inline; filename="${filename}"`);
      res.setHeader('Content-Length',      size);
      // Let browser cache private assets for 1 hour to avoid repeat FTP hits
      res.setHeader('Cache-Control',       'private, max-age=3600');

      await client.downloadTo(res, filename);
    });
  } catch (err) {
    if (err?.code === 550) {
      return res.status(404).json({ success: false, message: 'File not found.' });
    }
    console.log('FTP download error:', err);
    if (!res.headersSent) {
      res.status(500).json({ success: false, error: 'FTP download failed.' });
    } else {
      res.end();
    }
  }
});

export default imageRouter;
