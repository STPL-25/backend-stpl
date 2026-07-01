import jwt from "jsonwebtoken";
import { configDotenv } from "dotenv";
configDotenv();

const JWT_SECRET = process.env.JWT_SECRET;

// Dev bypass: only active when NODE_ENV !== 'production' AND DEV_BYPASS_TOKEN is set
const DEV_BYPASS_TOKEN = process.env.DEV_BYPASS_TOKEN;
const DEV_BYPASS_ECNO = process.env.DEV_BYPASS_ECNO || "DEV001";

// Session ID rotates every 1 hour
const SESSION_ROTATION_INTERVAL = 60 * 60 * 1000; // 1 hour in ms

// Auto-logout after 2 hours of inactivity (matches frontend useInactivityLogout)
const INACTIVITY_TIMEOUT = parseInt(process.env.INACTIVITY_TIMEOUT_MS) || 2 * 60 * 60 * 1000;

function getBearerToken(req) {
  const authorization = req.headers?.authorization ?? req.headers?.Authorization;
  if (typeof authorization !== "string") return null;

  const [scheme, token] = authorization.trim().split(/\s+/);
  if (scheme?.toLowerCase() !== "bearer" || !token) return null;

  return token;
}

function getUserFromPayload(payload) {
  return payload.user ?? payload;
}

function getEcnoFromUser(user) {
  const normalizedUser = Array.isArray(user) ? user[0] : user;
  return normalizedUser?.ecno ?? null;
}

/**
 * JWT verification middleware.
 * - Reads JWT from server-side session (req.session.jwt). Client never holds the JWT.
 * - In non-production only, also accepts Authorization: Bearer <jwt> for Postman/backend testing.
 * - Checks inactivity: destroys session if no activity within INACTIVITY_TIMEOUT.
 * - Rotates session ID every SESSION_ROTATION_INTERVAL to prevent session fixation.
 * - Updates lastActivity on every successful authenticated request.
 */
function wrapDevResponse(req, res) {
  const requestSnapshot = {
    method: req.method,
    url: req.originalUrl,
    params: req.params,
    query: req.query,
    body: req.body,
    user: req.user,
  };

  const originalJson = res.json.bind(res);
  res.json = (data) => {
    return originalJson({
      _dev: true,
      request: requestSnapshot,
      response: data,
      meta: {
        timestamp: new Date().toISOString(),
        status: res.statusCode,
        ecno: req.user_ecno,
      },
    });
  };
}

const verifyJWT = async (req, res, next) => {
  // Dev bypass: static token for Postman/API documentation — never active in production
  if (process.env.NODE_ENV !== "production" && DEV_BYPASS_TOKEN) {
    const incoming = getBearerToken(req);
    if (incoming === DEV_BYPASS_TOKEN) {
      req.user = { ecno: DEV_BYPASS_ECNO, name: "Dev User", role: "dev" };
      req.user_ecno = DEV_BYPASS_ECNO;
      wrapDevResponse(req, res);
      return next();
    }
  }

  const sessionJwt = req.session?.jwt;
  const bearerJwt = process.env.NODE_ENV !== "production" ? getBearerToken(req) : null;
  
  const jwtToken = sessionJwt || bearerJwt;
  const isSessionAuth = Boolean(sessionJwt);
  if (!jwtToken) {
    return res.status(401).json({ success: false, message: "Access denied. Please log in." });
  }

  const now = Date.now();

  // --- Inactivity check ---
  const lastActivity = isSessionAuth ? req.session.lastActivity || 0 : 0;
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
    req.user = getUserFromPayload(payload);
    req.user_ecno = getEcnoFromUser(req.user);


    // --- Session ID rotation every 1 hour ---
    const sessionAge = isSessionAuth ? now - (req.session.createdAt || now) : 0;
    if (isSessionAuth && sessionAge >= SESSION_ROTATION_INTERVAL) {
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
    } else if (isSessionAuth) {
      // Update last activity timestamp (fire-and-forget — don't block the request)
      req.session.lastActivity = now;
      req.session.save(() => {});
    }

    next();
  } catch (error) {
    if (isSessionAuth) req.session.destroy(() => {});
    if (error.name === "TokenExpiredError") {
      return res.status(401).json({ success: false, message: "Session expired. Please log in again." });
    }
    return res.status(401).json({ success: false, message: "Invalid session." });
  }
};

export default verifyJWT;
