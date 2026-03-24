import jwt from "jsonwebtoken";
import { configDotenv } from "dotenv";
configDotenv();

const JWT_SECRET = process.env.JWT_SECRET;

/**
 * JWT verification middleware.
 * Reads the JWT from the server-side session (req.session.jwt).
 * The client never holds the JWT — only the HttpOnly session cookie is sent.
 */
const verifyJWT = (req, res, next) => {
  const jwtToken = req.session?.jwt;
  if (!jwtToken) {
    return res.status(401).json({ success: false, message: "Access denied. Please log in." });
  }
  try {
    const payload = jwt.verify(jwtToken, JWT_SECRET, { algorithms: ["HS256"] });
    req.user = payload.user ?? payload;
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
