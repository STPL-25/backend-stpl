// Load generator: maintains a target number of in-flight requests (concurrency)
// against a URL for a fixed duration, then reports latency percentiles,
// throughput and status-code distribution.
//
// Usage: node run.js <path> <concurrency> <durationSec> [label]
import http from "node:http";

const PORT = parseInt(process.env.LT_PORT || "9099");
const path = "/" + (process.argv[2] || "api/realistic").replace(/^\/+/, "");
const CONCURRENCY = parseInt(process.argv[3] || "10000");
const DURATION_MS = (parseInt(process.argv[4] || "15")) * 1000;
const LABEL = process.argv[5] || path;

const agent = new http.Agent({ keepAlive: true, maxSockets: CONCURRENCY, maxFreeSockets: CONCURRENCY });

const lat = [];                 // latency samples (ms)
const status = {};              // status code -> count
let errors = 0, done = 0, inflight = 0, running = true;

function once() {
  inflight++;
  const t0 = process.hrtime.bigint();
  const req = http.get({ host: "127.0.0.1", port: PORT, path, agent }, (res) => {
    res.on("data", () => {});
    res.on("end", () => {
      const ms = Number(process.hrtime.bigint() - t0) / 1e6;
      lat.push(ms);
      status[res.statusCode] = (status[res.statusCode] || 0) + 1;
      done++; inflight--;
      if (running) once();
    });
  });
  req.on("error", () => { errors++; done++; inflight--; if (running) once(); });
}

function pct(sorted, p) {
  if (!sorted.length) return 0;
  const i = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return +sorted[i].toFixed(2);
}

const startedAt = Date.now();
for (let i = 0; i < CONCURRENCY; i++) once();

setTimeout(() => {
  running = false;
  setTimeout(() => {
    const elapsed = (Date.now() - startedAt) / 1000;
    const sorted = lat.slice().sort((a, b) => a - b);
    const sum = sorted.reduce((a, b) => a + b, 0);
    const ok2xx = Object.entries(status).filter(([k]) => k.startsWith("2")).reduce((a, [, v]) => a + v, 0);
    const result = {
      label: LABEL, path, concurrency: CONCURRENCY, durationSec: +elapsed.toFixed(1),
      completed: done, throughputRps: +(done / elapsed).toFixed(0),
      ok2xx, errors, statusDist: status,
      latencyMs: {
        mean: +(sum / (sorted.length || 1)).toFixed(2),
        p50: pct(sorted, 50), p90: pct(sorted, 90), p95: pct(sorted, 95),
        p99: pct(sorted, 99), max: +(sorted[sorted.length - 1] || 0).toFixed(2),
      },
    };
    console.log("RESULT " + JSON.stringify(result));
    process.exit(0);
  }, 2500); // drain window for in-flight requests
}, DURATION_MS);
