// Backend test setup — shared mocks and helpers
// ESM + --experimental-vm-modules: jest global must be imported explicitly
import { jest } from "@jest/globals";

/** Build a minimal Express-like mock request */
export function mockReq(overrides = {}) {
  return {
    user:        { ecno: "TEST001", ename: "Test User" },
    redisClient: null,   // override per test
    io:          null,
    body:        {},
    params:      {},
    query:       {},
    headers:     {},
    ...overrides,
  };
}

/** Build a minimal mock response with jest spy methods */
export function mockRes() {
  const res = {};
  res.statusCode = 200;
  res.status     = jest.fn().mockImplementation((code) => { res.statusCode = code; return res; });
  res.json       = jest.fn().mockReturnValue(res);
  res.send       = jest.fn().mockReturnValue(res);
  res.setHeader  = jest.fn().mockReturnValue(res);
  return res;
}

/** In-memory Redis mock */
export function createMockRedis() {
  const store = new Map();
  const lists = new Map();

  return {
    isReady: true,
    // String ops
    get:    async (k)         => store.get(k) ?? null,
    set:    async (k, v)      => store.set(k, v),
    setEx:  async (k, _t, v)  => store.set(k, v),   // setEx(key, ttl, value)
    del:    async (k)         => lists.delete(k) || store.delete(k),
    expire: async ()          => 1,

    // List ops
    lPush:  async (k, v)    => { const l = lists.get(k) ?? []; l.unshift(v); lists.set(k, l); return l.length; },
    lRange: async (k, s, e) => { const l = lists.get(k) ?? []; return e === -1 ? l : l.slice(s, e + 1); },
    lTrim:  async (k, s, e) => { const l = lists.get(k) ?? []; lists.set(k, l.slice(s, e + 1)); },
    lSet:   async (k, i, v) => { const l = lists.get(k) ?? []; l[i] = v; lists.set(k, l); },
    lLen:   async (k)       => (lists.get(k) ?? []).length,

    // Expose internals for assertions
    _store: store,
    _lists: lists,
  };
}
