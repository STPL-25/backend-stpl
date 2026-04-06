import jwt from "jsonwebtoken";
import { configDotenv } from "dotenv";
configDotenv();

const JWT_SECRET = process.env.JWT_SECRET;

// Session ID rotates every 1 hour
const SESSION_ROTATION_INTERVAL = 60 * 60 * 1000; // 1 hour in ms

// Auto-logout after 2 hours of inactivity (matches frontend useInactivityLogout)
const INACTIVITY_TIMEOUT = parseInt(process.env.INACTIVITY_TIMEOUT_MS) || 2 * 60 * 60 * 1000;
/**
 * JWT verification middleware.
 * - Reads JWT from server-side session (req.session.jwt). Client never holds the JWT.
 * - Checks inactivity: destroys session if no activity within INACTIVITY_TIMEOUT.
 * - Rotates session ID every SESSION_ROTATION_INTERVAL to prevent session fixation.
 * - Updates lastActivity on every successful authenticated request.
 */
const verifyJWT = async (req, res, next) => {
  const jwtToken = req.session?.jwt;
  if (!jwtToken) {
    return res.status(401).json({ success: false, message: "Access denied. Please log in." });
  }

  const now = Date.now();

  // --- Inactivity check ---
  const lastActivity = req.session.lastActivity || 0;
  if (lastActivity && now - lastActivity > INACTIVITY_TIMEOUT) {
    req.session.destroy(() => {});
    return res.status(401).json({
      success: false,
      message: "Session expired due to inactivity. Please log in again.",
      code: "INACTIVITY_TIMEOUT",
    });
  }

  try {
    const payload = jwt.verify(jwtToken, JWT_SECRET, { algorithms: ["HS256"] });
    req.user = payload.user ?? payload;

    // --- Session ID rotation every 1 hour ---
    const sessionAge = now - (req.session.createdAt || now);
    if (sessionAge >= SESSION_ROTATION_INTERVAL) {
      const savedJwt = req.session.jwt;
      const savedCreatedAt = req.session.createdAt;

      // regenerate() creates a new session ID and copies nothing — we re-populate manually
      await new Promise((resolve, reject) => {
        req.session.regenerate((err) => (err ? reject(err) : resolve()));
      });

      req.session.jwt = savedJwt;
      req.session.createdAt = savedCreatedAt; // keep original creation time for audit
      req.session.lastActivity = now;
      req.session.rotatedAt = now; // track when rotation happened

      await new Promise((resolve, reject) => {
        req.session.save((err) => (err ? reject(err) : resolve()));
      });
    } else {
      // Update last activity timestamp (fire-and-forget — don't block the request)
      req.session.lastActivity = now;
      req.session.save(() => {});
    }

    next();
  } catch (error) {
    req.session.destroy(() => {});
    if (error.name === "TokenExpiredError") {
      return res.status(401).json({ success: false, message: "Session expired. Please log in again." });
    }
    return res.status(401).json({ success: false, message: "Invalid session." });
  }
};

export default verifyJWT;
