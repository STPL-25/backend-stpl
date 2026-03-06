/**
 * Redis caching middleware and helpers.
 *
 * Usage in a route:
 *   import { cacheMiddleware, invalidateCache } from '../../Middleware/redisCache.js';
 *   router.get('/my-route', cacheMiddleware('my_key', 300), controller);
 *
 * invalidateCache is used in POST/PUT/DELETE handlers to clear stale data.
 */

const DEFAULT_TTL = 300; // 5 minutes

/**
 * Express middleware that caches the JSON response in Redis.
 * @param {string|Function} keyOrFn  - Cache key string or a function(req) => string
 * @param {number}          ttl      - Time-to-live in seconds
 */
export function cacheMiddleware(keyOrFn, ttl = DEFAULT_TTL) {
  return async (req, res, next) => {
    const redisClient = req.redisClient;
    if (!redisClient) return next();

    const cacheKey = typeof keyOrFn === "function" ? keyOrFn(req) : keyOrFn;

    try {
      const cached = await redisClient.get(cacheKey);
      if (cached) {
        res.setHeader("X-Cache", "HIT");
        return res.json(JSON.parse(cached));
      }
    } catch {
      // Cache miss or Redis error — fall through to handler
    }

    // Patch res.json to store result in cache before sending
    const originalJson = res.json.bind(res);
    res.json = async (data) => {
      res.setHeader("X-Cache", "MISS");
      try {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          await redisClient.setEx(cacheKey, ttl, JSON.stringify(data));
        }
      } catch {
        // Non-fatal — send response even if caching fails
      }
      return originalJson(data);
    };

    next();
  };
}

/**
 * Delete one or more Redis keys (call inside mutation handlers).
 * @param {import('redis').RedisClientType} redisClient
 * @param {...string} keys
 */
export async function invalidateCache(redisClient, ...keys) {
  if (!redisClient) return;
  try {
    await Promise.all(keys.map((k) => redisClient.del(k)));
  } catch {
    // Non-fatal
  }
}

/**
 * Delete all Redis keys matching a glob pattern (e.g. "master:*").
 * Use sparingly — SCAN is O(N) over keyspace.
 */
export async function invalidateCacheByPattern(redisClient, pattern) {
  if (!redisClient) return;
  try {
    let cursor = 0;
    do {
      const reply = await redisClient.scan(cursor, { MATCH: pattern, COUNT: 100 });
      cursor = reply.cursor;
      if (reply.keys.length) {
        await redisClient.del(reply.keys);
      }
    } while (cursor !== 0);
  } catch {
    // Non-fatal
  }
}
