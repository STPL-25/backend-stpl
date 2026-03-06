import rateLimit from "express-rate-limit";

/**
 * Strict limiter for auth endpoints (login / signup).
 * 10 attempts per IP per 15 minutes.
 */
export const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: {
    success: false,
    message: "Too many login attempts. Please try again after 15 minutes.",
  },
  skipSuccessfulRequests: true,
});

/**
 * General API limiter for regular endpoints.
 * 200 requests per IP per minute — suitable for high-traffic ERP.
 */
export const apiLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 200,
  standardHeaders: true,
  legacyHeaders: false,
  message: {
    success: false,
    message: "Too many requests. Please slow down.",
  },
});
