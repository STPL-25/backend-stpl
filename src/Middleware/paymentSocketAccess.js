import mssql from "mssql";
import { initializeDatabase } from "../Dbconnections/Dbconnections.js";
import { getHierarchyJson, orgRoomsForHierarchy } from "./hierarchyScope.js";

export async function paymentSocketRooms(user) {
  const normalized = Array.isArray(user) ? user[0] : user;
  const identity = normalized?.ecno ?? normalized?.login_id;
  if (!identity) return [];
  const pool = await initializeDatabase();
  const result = await pool.request()
    .input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify({ ecno: identity }))
    .execute("sp_nt_GetUserScreensAndPermissionsJson");
  const canView = (result.recordset ?? []).some((row) =>
    String(row.comp ?? row.screen_comp).toLowerCase() === "paymentpage" && Number(row.permission_id) === 2);
  if (!canView) return [];
  const hierarchy = (await getHierarchyJson(identity)).filter((h) =>
    !(h.div_sno == null && (h.brn_sno != null || h.dept_sno != null)) && !(h.brn_sno == null && h.dept_sno != null));
  return orgRoomsForHierarchy("payment", hierarchy);
}
