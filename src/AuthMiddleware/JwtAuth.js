import jwt from "jsonwebtoken";
import crypto from "crypto";
import { configDotenv } from "dotenv";
configDotenv();

const JWT_SECRET = process.env.JWT_SECRET;
const CRYPTO_SECRET = process.env.CRYPTO_SECRET;

/**
 * Decrypts the AES-256-CBC encrypted token from the Authorization header.
 */
function decryptToken(encryptedObj) {
  const key = crypto.pbkdf2Sync(CRYPTO_SECRET, "salt", 1000, 32, "sha256");
  const iv = Buffer.from(encryptedObj.iv, "hex");
  const decipher = crypto.createDecipheriv("aes-256-cbc", key, iv);
  let decrypted = decipher.update(encryptedObj.token, "hex", "utf8");
  decrypted += decipher.final("utf8");
  return JSON.parse(decrypted);
}

/**
 * JWT verification middleware.
 * Expects the client to send the encrypted token object as a Bearer token
 * in JSON-stringified + base64 form, or as the raw token in Authorization header.
 *
 * Frontend should send:
 *   Authorization: Bearer <base64(JSON.stringify({token, iv}))>
 */
const verifyJWT = (req, res, next) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return res.status(401).json({ success: false, message: "Access denied. No token provided." });
    }

    const raw = authHeader.slice(7);

    let jwtToken;
    try {
      // Try to decode as base64 JSON (encrypted token object)
      const decoded = Buffer.from(raw, "base64").toString("utf8");
      const encryptedObj = JSON.parse(decoded);
      if (encryptedObj.token && encryptedObj.iv) {
        const decrypted = decryptToken(encryptedObj);
        jwtToken = decrypted.token;
      } else {
        jwtToken = raw;
      }
    } catch {
      // Treat as plain JWT
      jwtToken = raw;
    }

    const payload = jwt.verify(jwtToken, JWT_SECRET, { algorithms: ["HS256"] });
    req.user = payload.user ?? payload;
    next();
  } catch (error) {
    if (error.name === "TokenExpiredError") {
      return res.status(401).json({ success: false, message: "Token expired. Please log in again." });
    }
    return res.status(401).json({ success: false, message: "Invalid token." });
  }
};

export default verifyJWT;
