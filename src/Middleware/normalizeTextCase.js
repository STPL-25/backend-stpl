/**
 * Normalizes free-text "name-like" fields in JSON request bodies to Title Case
 * ("aravali ELECTRICAL" -> "Aravali Electrical") so stored data is consistent
 * no matter how the user typed it.
 *
 * Only keys that look like names/addresses/places are touched (whitelist),
 * so codes, enums, emails, GSTIN/PAN/IFSC, passwords, tokens, URLs, dates and
 * base64/file data are never altered.
 */

// Key must contain one of these ...
const INCLUDE = /(name|address|addr|city|town|state|district|country|location|place|designation|department|dept|title|landmark|street|area|branch|bank|contact_person|person)/i;
// ... and none of these.
const EXCLUDE = /(user|login|file|path|url|email|mail|password|pwd|token|secret|code|_no$|number|_id$|^id$|gst|pan|ifsc|swift|iban|base64|image|img|logo|signature|status|type|role|mobile|phone)/i;

const SKIP_ROUTES = ["/api/secure", "/api/debug"];

export function toTitleCase(str) {
  const cleaned = str.trim().replace(/\s+/g, " ");
  if (!cleaned) return cleaned;
  return cleaned.toLowerCase().replace(/(^|[\s\-/(&.,])([a-z])/g, (_m, sep, ch) => sep + ch.toUpperCase());
}

function shouldNormalizeKey(key) {
  return typeof key === "string" && INCLUDE.test(key) && !EXCLUDE.test(key);
}

function normalize(value, key) {
  if (Array.isArray(value)) return value.map((v) => normalize(v, key));
  if (value && typeof value === "object") {
    for (const k of Object.keys(value)) value[k] = normalize(value[k], k);
    return value;
  }
  if (typeof value === "string" && shouldNormalizeKey(key)) {
    // leave anything that isn't plain text (data URIs, emails, URLs) alone
    if (/^data:|@|https?:\/\//i.test(value)) return value;
    return toTitleCase(value);
  }
  return value;
}

export function normalizeTextCase(req, _res, next) {
  try {
    if (
      ["POST", "PUT", "PATCH"].includes(req.method) &&
      req.is("application/json") &&
      req.body &&
      typeof req.body === "object" &&
      !SKIP_ROUTES.some((r) => req.path.startsWith(r) || req.originalUrl.startsWith(r))
    ) {
      normalize(req.body, "");
    }
  } catch (err) {
    console.error("normalizeTextCase error:", err.message);
  }
  next();
}
