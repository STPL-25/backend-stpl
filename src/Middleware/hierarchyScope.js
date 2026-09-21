/**
 * Company/Division/Branch access scoping.
 *
 * Resolves the requesting employee's allowed org scope from
 * nt_user_permissions_json.hierarchy_json (via sp_nt_GetUserHierarchy) and
 * attaches it as req.hierarchyJson — an array of {com_sno, div_sno, brn_sno}
 * rows to hand to any SP with an @HierarchyJson parameter.
 *
 * Fail-closed default: an ecno with no active permissions row (or any
 * lookup error) gets [] — an empty array, never null/undefined — so a GET
 * handler that forwards it straight into @HierarchyJson sees zero rows
 * rather than an unfiltered table. Passing an actual NULL to those SPs
 * means "no filter", which must never happen implicitly from this path.
 */
import mssql from "mssql";
import { initializeDatabase } from "../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

const CACHE_TTL_SECONDS = 60;

export async function getHierarchyJson(ecno) {
  if (!ecno) return [];
  try {
    const request = mssqlPool.request();
    request.input("Ecno", mssql.VarChar(50), ecno);
    const result = await request.execute("sp_nt_GetUserHierarchy");
    return result.recordset ?? [];
  } catch (error) {
    console.error(`[hierarchyScope] failed to resolve hierarchy for ${ecno}:`, error.message);
    return [];
  }
}

async function getHierarchyJsonCached(req, ecno) {
  const redisClient = req.redisClient;
  if (!ecno || !redisClient) return getHierarchyJson(ecno);

  const cacheKey = `hier:${ecno}`;
  try {
    const cached = await redisClient.get(cacheKey);
    if (cached) return JSON.parse(cached);
  } catch {
    // fall through to a live lookup
  }

  const hierarchy = await getHierarchyJson(ecno);
  redisClient.setEx(cacheKey, CACHE_TTL_SECONDS, JSON.stringify(hierarchy)).catch(() => {});
  return hierarchy;
}

// Mount on individual GET routes, after verifyJWT (needs req.user_ecno).
export async function attachHierarchyScope(req, res, next) {
  req.hierarchyJson = await getHierarchyJsonCached(req, req.user_ecno);
  next();
}

/**
 * Socket.IO room scheme for org-scoped real-time broadcasts, shared between
 * this middleware (client-side: which rooms a connecting socket should
 * join) and grn-service's socketBroadcast.js (server-side: which rooms an
 * event should be emitted to). A hierarchy row with div_sno/brn_sno/
 * dept_sno = NULL means "this whole company/division/branch" — mirrored
 * here as one room per row, at whatever granularity that row actually
 * grants:
 *   {com_sno, div:null, brn:null, dept:null} -> "<domain>:live:com:X"
 *   {com_sno, div_sno,  brn:null, dept:null} -> "<domain>:live:com:X:div:Y"
 *   {com_sno, div_sno,  brn_sno,  dept:null} -> "<domain>:live:com:X:div:Y:brn:Z"
 *   {com_sno, div_sno,  brn_sno,  dept_sno}  -> "<domain>:live:com:X:div:Y:brn:Z:dept:W"
 *
 * A broadcaster then targets the decomposition of the EVENT's own
 * (com,div,brn,dept) up to however deep it's known — io.to([...]) dedupes
 * automatically, so a socket sitting in any one matching room (exact or a
 * broader wildcard it holds) gets the event exactly once. See
 * orgRoomTargets below.
 */
export function orgRoomsForHierarchy(domain, hierarchy) {
  const rooms = new Set();
  for (const h of hierarchy ?? []) {
    if (h?.com_sno == null) continue;
    if (h.div_sno == null) rooms.add(`${domain}:live:com:${h.com_sno}`);
    else if (h.brn_sno == null) rooms.add(`${domain}:live:com:${h.com_sno}:div:${h.div_sno}`);
    else if (h.dept_sno == null) rooms.add(`${domain}:live:com:${h.com_sno}:div:${h.div_sno}:brn:${h.brn_sno}`);
    else rooms.add(`${domain}:live:com:${h.com_sno}:div:${h.div_sno}:brn:${h.brn_sno}:dept:${h.dept_sno}`);
  }
  return [...rooms];
}

// Target rooms for one event's own org — the decomposition a broadcaster
// emits to, as deep as the event's own data goes. Falls back to the plain
// unscoped `${domain}:live` room when the event carries no com_sno (e.g. a
// legacy/manually-created inventory item with no org ever assigned) so the
// event still reaches whoever is in that room rather than silently
// vanishing.
export function orgRoomTargets(domain, { com_sno, div_sno, brn_sno, dept_sno } = {}) {
  if (com_sno == null) return [`${domain}:live`];
  const rooms = [`${domain}:live:com:${com_sno}`];
  if (div_sno != null) {
    rooms.push(`${domain}:live:com:${com_sno}:div:${div_sno}`);
    if (brn_sno != null) {
      rooms.push(`${domain}:live:com:${com_sno}:div:${div_sno}:brn:${brn_sno}`);
      if (dept_sno != null) rooms.push(`${domain}:live:com:${com_sno}:div:${div_sno}:brn:${brn_sno}:dept:${dept_sno}`);
    }
  }
  return rooms;
}
