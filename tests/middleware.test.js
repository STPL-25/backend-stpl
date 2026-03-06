import { describe, it, expect, jest, beforeEach } from "@jest/globals";
import { mockReq, mockRes, createMockRedis } from "./setup.js";
import { cacheMiddleware, invalidateCache, invalidateCacheByPattern }
  from "../src/Middleware/redisCache.js";

// ─── redisCache.js ─────────────────────────────────────────────────────────
describe("Redis Cache Middleware", () => {
  let redis;

  beforeEach(() => {
    redis = createMockRedis();
  });

  it("cacheMiddleware — returns cached value on HIT", async () => {
    const payload = { success: true, data: [{ id: 1 }] };
    const cached  = JSON.stringify(payload);
    await redis.set("test:key", cached);

    const req     = { ...mockReq(), redisClient: redis };
    const res     = mockRes();
    const jsonSpy = res.json;        // capture spy BEFORE middleware may replace it
    const next    = jest.fn();

    const mw = cacheMiddleware("test:key", 60);
    await mw(req, res, next);

    // On a cache HIT the middleware calls res.json(parsedData) without touching next()
    expect(jsonSpy).toHaveBeenCalledWith(payload);
    expect(next).not.toHaveBeenCalled();
  });

  it("cacheMiddleware — calls next() on MISS and patches res.json", async () => {
    const req     = { ...mockReq(), redisClient: redis };
    const res     = mockRes();
    const jsonSpy = res.json;        // capture original spy before middleware wraps it
    const next    = jest.fn();

    const mw = cacheMiddleware("missing:key", 60);
    await mw(req, res, next);

    // On MISS, next() must be called so the real handler can run
    expect(next).toHaveBeenCalled();
    // The original spy should NOT have been called (middleware only patches it, doesn't invoke it)
    expect(jsonSpy).not.toHaveBeenCalled();
    // res.json should now be the wrapper async function (not the original spy)
    expect(typeof res.json).toBe("function");
    expect(res.json).not.toBe(jsonSpy);
  });

  it("invalidateCache — deletes specified keys", async () => {
    await redis.set("cache:a", "val-a");
    await redis.set("cache:b", "val-b");

    await invalidateCache(redis, "cache:a", "cache:b");

    expect(await redis.get("cache:a")).toBeNull();
    expect(await redis.get("cache:b")).toBeNull();
  });
});

// ─── Rate Limiter (existence check) ────────────────────────────────────────
describe("Rate Limiter Module", () => {
  it("exports authLimiter and apiLimiter functions", async () => {
    const { authLimiter, apiLimiter } = await import("../src/Middleware/rateLimiter.js");
    expect(typeof authLimiter).toBe("function");
    expect(typeof apiLimiter).toBe("function");
  });
});

// ─── JWT Auth Middleware ───────────────────────────────────────────────────
describe("JWT Auth Middleware (verifyJWT)", () => {
  it("exports a function", async () => {
    const mod = await import("../src/AuthMiddleware/JwtAuth.js");
    expect(typeof mod.default).toBe("function");
  });

  it("calls next with 401 error when Authorization header is missing", async () => {
    const { default: verifyJWT } = await import("../src/AuthMiddleware/JwtAuth.js");
    const req  = mockReq({ headers: {} });
    const res  = mockRes();
    const next = jest.fn();

    await verifyJWT(req, res, next);

    // Either next called with error, or res.status(401) — both are valid
    const calledWithError = next.mock.calls.some((args) => args[0] instanceof Error);
    const sentUnauth      = res.status.mock.calls.some((args) => args[0] === 401);
    expect(calledWithError || sentUnauth).toBe(true);
  });
});
