// Standalone load-test harness for the Non-Trade backend.
// Reuses the REAL performance-relevant middleware (helmet, compression,
// payloadCrypto AES-GCM, the real apiLimiter) but stubs Redis/DB/FTP so the
// server can actually start. The DB is modelled as a semaphore of `POOL_MAX`
// (mirrors Dbconnections.js pool.max = 50) plus a fixed query latency, so the
// "realistic" route reproduces the real bottleneck.
import express from "express";
import helmet from "helmet";
import compression from "compression";
import { configDotenv } from "dotenv";
import { payloadCrypto } from "../src/Middleware/payloadCrypto.js";
import { apiLimiter } from "../src/Middleware/rateLimiter.js";

configDotenv();

const POOL_MAX = parseInt(process.env.LT_POOL_MAX || "50");      // mirrors DB pool.max
const DB_LATENCY_MS = parseInt(process.env.LT_DB_MS || "15");    // simulated avg query time
const PORT = parseInt(process.env.LT_PORT || "9099");

// ── Simple async semaphore modelling the fixed-size DB connection pool ────────
class Semaphore {
  constructor(max) { this.max = max; this.cur = 0; this.q = []; this.peak = 0; this.queuedPeak = 0; }
  async acquire() {
    if (this.cur < this.max) { this.cur++; this.peak = Math.max(this.peak, this.cur); return; }
    this.queuedPeak = Math.max(this.queuedPeak, this.q.length + 1);
    await new Promise((res) => this.q.push(res));
    this.cur++; this.peak = Math.max(this.peak, this.cur);
  }
  release() { this.cur--; const n = this.q.shift(); if (n) n(); }
}
const dbPool = new Semaphore(POOL_MAX);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

const app = express();
app.disable("x-powered-by");
// NOTE: trust proxy intentionally NOT set — mirrors the real index.js
app.use(helmet());
app.use(compression());
app.use(express.json({ limit: "1mb" }));

// Absolute ceiling: no crypto, no DB
app.get("/ping", (_req, res) => res.send("pong"));

// CPU ceiling: real payloadCrypto AES-GCM on the response, no DB
app.get("/api/light", payloadCrypto, (_req, res) => {
  res.json({ success: true, ts: Date.now(), rows: [{ id: 1, name: "demo" }] });
});

// Realistic: acquire DB pool slot + simulated query latency + AES-GCM response
app.get("/api/realistic", payloadCrypto, async (_req, res) => {
  await dbPool.acquire();
  try {
    await wait(DB_LATENCY_MS);
    res.json({ success: true, ts: Date.now(), rows: Array.from({ length: 20 }, (_, i) => ({ id: i, v: i * 7 })) });
  } finally {
    dbPool.release();
  }
});

// Realistic + the REAL apiLimiter (200 req / min / IP) to demonstrate throttling
app.get("/api/limited", apiLimiter, payloadCrypto, async (_req, res) => {
  await dbPool.acquire();
  try {
    await wait(DB_LATENCY_MS);
    res.json({ success: true, ts: Date.now() });
  } finally {
    dbPool.release();
  }
});

// Server-side metrics snapshot for the report
let cpuStart = process.cpuUsage();
let tStart = Date.now();
app.get("/__stats", (_req, res) => {
  const cpu = process.cpuUsage(cpuStart);
  const elapsedMs = Date.now() - tStart;
  const mem = process.memoryUsage();
  res.set("Cache-Control", "no-store");
  // bypass payloadCrypto (not mounted here) — plain json
  res.json({
    poolMax: POOL_MAX,
    dbLatencyMs: DB_LATENCY_MS,
    poolPeakActive: dbPool.peak,
    poolQueuePeak: dbPool.queuedPeak,
    cpuUserMs: +(cpu.user / 1000).toFixed(1),
    cpuSystemMs: +(cpu.system / 1000).toFixed(1),
    cpuPctOneCore: +(((cpu.user + cpu.system) / 1000 / elapsedMs) * 100).toFixed(1),
    rssMB: +(mem.rss / 1048576).toFixed(1),
    heapUsedMB: +(mem.heapUsed / 1048576).toFixed(1),
    elapsedMs,
  });
});
app.post("/__reset", (_req, res) => {
  cpuStart = process.cpuUsage(); tStart = Date.now();
  dbPool.peak = 0; dbPool.queuedPeak = 0;
  res.json({ ok: true });
});

const server = app.listen(PORT, () => {
  console.log(`[harness] listening on ${PORT} | POOL_MAX=${POOL_MAX} DB_LATENCY_MS=${DB_LATENCY_MS}`);
});
server.maxConnections = 100000;
