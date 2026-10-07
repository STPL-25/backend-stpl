import axios from "axios";
import { configDotenv } from "dotenv";
configDotenv();
// Cashfree Secure ID (Verification Suite) — https://www.cashfree.com/docs/api-reference/vrs
// Production: https://api.cashfree.com/verification
// Sandbox:    https://sandbox.cashfree.com/verification
// Production calls only work from an IP whitelisted in the Cashfree dashboard.
const BASE_URL = process.env.CASH_FREE_URL;
const TIMEOUT_MS = Number(process.env.CASHFREE_TIMEOUT_MS) || 30000;

export async function cashfreePost(path, body) {
  const clientId = process.env.CASHFREE_CLIENT_ID;
  const clientSecret = process.env.CASHFREE_CLIENT_SECRET;
  if (!clientId || !clientSecret) {
    const err = new Error("Cashfree verification is not configured (CASHFREE_CLIENT_ID / CASHFREE_CLIENT_SECRET missing).");
    err.statusCode = 503;
    throw err;
  }

  const headers = {
    "Content-Type": "application/json",
    "x-client-id": clientId,
    "x-client-secret": clientSecret,
  };
  if (process.env.CASHFREE_API_VERSION) headers["x-api-version"] = process.env.CASHFREE_API_VERSION;

  try {
    const res = await axios.post(`${BASE_URL}${path}`, body, { headers, timeout: TIMEOUT_MS });
    return res.data;
  } catch (e) {
    // Cashfree errors look like { type, code, message } — surface its message as-is.
    const data = e.response?.data;
    const err = new Error(data?.message || e.message || "Cashfree verification failed");
    err.statusCode = e.response?.status && e.response.status < 500 ? e.response.status : 502;
    err.code = data?.code;
    throw err;
  }
}
