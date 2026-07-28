import UserApprovalService from "../services/UserApproval.service.js";
import { invalidateCache, invalidateCacheByPattern } from "../../Middleware/redisCache.js";

class UserApprovalController {
  static async getAllCompanyByHierarchy(req, res) {
    try {
      const data = await UserApprovalService.getAllCompanyByHierarchy();

      if (!Array.isArray(data)) {
        return res.status(500).json({ success: false, error: "Invalid data from service" });
      }

      const hierarchy = UserApprovalController.#arrangeHierarchy(data);
      res.json({ success: true, data: hierarchy });
    } catch (error) {
      res.status(500).json({ success: false, error: error?.message ?? "Internal server error" });
    }
  }

  static #arrangeHierarchy(rows) {
    const hierarchy = { companies: [] };
    if (!Array.isArray(rows)) return hierarchy;

    const companyMap = new Map();

    for (const item of rows) {
      if (!item) continue;

      const companyId = item.company_id ?? item.com_sno ?? null;
      if (companyId == null) continue;
      const companyKey = String(companyId);

      let company = companyMap.get(companyKey);
      if (!company) {
        company = {
          company_id: companyId,
          com_sno: item.com_sno ?? null,
          com_name: item.com_name ?? null,
          divisions: [],
          _divisionMap: new Map(),
        };
        companyMap.set(companyKey, company);
      }

      const divisionId = item.division_id ?? item.div_sno ?? null;
      if (divisionId != null) {
        const divisionKey = String(divisionId);
        let division = company._divisionMap.get(divisionKey);
        if (!division) {
          division = {
            division_id: divisionId,
            div_sno: item.div_sno ?? null,
            div_name: item.div_name ?? null,
            branches: [],
            _branchSet: new Set(),
          };
          company._divisionMap.set(divisionKey, division);
        }

        const branchId = item.brn_sno ?? null;
        if (branchId != null) {
          const branchKey = String(branchId);
          if (!division._branchSet.has(branchKey)) {
            division.branches.push({ brn_sno: item.brn_sno, brn_name: item.brn_name ?? null });
            division._branchSet.add(branchKey);
          }
        }
      }
    }

    for (const company of companyMap.values()) {
      const divisions = [];
      for (const division of company._divisionMap.values()) {
        delete division._branchSet;
        divisions.push(division);
      }
      delete company._divisionMap;
      company.divisions = divisions;
      hierarchy.companies.push(company);
    }

    return hierarchy;
  }

  static async getAllScreensWithGroups(req, res) {
    try {
      const data = await UserApprovalService.getScreensWithGroups();
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getPermissionDetails(req, res) {
    try {
      const data = await UserApprovalService.getPermissionDetails();
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  /* DEPRECATED — replaced by saveUserPermissionsJson / getUserPermissionsJson below
     (nt_branch_permissions + nt_screen_permissions rows → single JSON-column row in nt_user_permissions_json).
  static async saveUserPermissions(req, res) {
    try {
      const permissionData = req.body;
      await UserApprovalService.saveUserPermissions(permissionData);

      const targetEcno = permissionData.user_ecno || permissionData.ecno;
      const targetUserId = permissionData.user_id;

      await invalidateCache(req.redisClient, "ua:permissions");
      if (targetEcno) await invalidateCache(req.redisClient, `ua:user_screens:${targetEcno}`);
      if (targetUserId) await invalidateCache(req.redisClient, `ua:user_perms:${targetUserId}`);
      else await invalidateCacheByPattern(req.redisClient, "ua:user_perms:*");

      if (req.io) {
        // 1. Notify the affected user — their sidebar refreshes immediately
        if (targetEcno) {
          req.io.to(`user:${targetEcno}`).emit("permissions:updated", {
            message: "Your permissions have been updated by an administrator",
            timestamp: new Date().toISOString(),
          });
        }

        // 2. Broadcast to ALL admins — so any open approval page auto-refreshes
        req.io.emit("admin:permissions:updated", {
          user_id:   targetUserId ?? null,
          user_ecno: targetEcno  ?? null,
          timestamp: new Date().toISOString(),
        });
      }

      res.json({ success: true, message: "Permissions saved successfully" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
  */

  /* DEPRECATED — replaced by getUserScreensAndPermissionsJson below, sourced from nt_user_permissions_json.
  static async getUserScreensAndPermissions(req, res) {
    try {
      const ecno = req.params.ecno;
      const data = await UserApprovalService.getUserScreensAndPermissions(ecno);
      const consolidatedData = await UserApprovalController.#consolidatePermissions(data);
      res.json({ success: true, data: consolidatedData });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
  */

  // Sidebar / login menu — GET /get_user_screens_and_permisssions_json/:ecno
  // Same response shape as the old handler ({ success, data: { companies, screens } }),
  // reconstructed from the single nt_user_permissions_json row for this ecno.
  static async getUserScreensAndPermissionsJson(req, res) {
    try {
      const ecno = req.params.ecno;
      const data = await UserApprovalService.getUserScreensAndPermissionsJson(ecno);
      const consolidatedData = await UserApprovalController.#consolidatePermissions(data);
      res.json({ success: true, data: consolidatedData });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  /* DEPRECATED — replaced by getUserPermissionsJson below.
  // Returns permissions in the format expected by PermissionManager (UserRoleApprovalScreen)
  static async getUserPermissions(req, res) {
    try {
      const userId = req.params.userId;
      const data = await UserApprovalService.getUserPermissionsById(userId);

      if (!data || data.length === 0) {
        return res.json({ success: true, permissions: {}, companies: [], divisions: [], branches: [] });
      }

      const permissions = {};
      const companiesSet = new Set();
      const divisionsSet = new Set();
      const branchesSet = new Set();

      for (const row of data) {
        if (row.com_sno) companiesSet.add(String(row.com_sno));
        if (row.div_sno) divisionsSet.add(String(row.div_sno));
        if (row.brn_sno) branchesSet.add(String(row.brn_sno));

        if (row.screen_name && row.permission_id != null) {
          if (!permissions[row.screen_name]) permissions[row.screen_name] = {};
          permissions[row.screen_name][row.permission_id] = true;
        }
      }

      res.json({
        success: true,
        permissions,
        companies: Array.from(companiesSet),
        divisions: Array.from(divisionsSet),
        branches: Array.from(branchesSet),
      });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
  */

  // ── nt_user_permissions_json — hierarchy + screens/permissions stored as JSON columns ──

  // Shared: screen_id -> screen_name lookup, used to turn stored screens_json back into
  // the { screen_name: { permission_id: true } } shape PermissionManager expects.
  static async #buildScreenNameMap() {
    const screensList = await UserApprovalService.getScreensWithGroups();
    return new Map((screensList ?? []).map((s) => [s.screen_id, s.screen_name]));
  }

  static #rowToPermissionsResponse(row, screenNameById) {
    if (!row) {
      return { success: true, exists: false, permissions: {}, companies: [], divisions: [], branches: [] };
    }

    const hierarchy = row.hierarchy_json ? JSON.parse(row.hierarchy_json) : [];
    const screensData = row.screens_json ? JSON.parse(row.screens_json) : [];

    const companiesSet = new Set();
    const divisionsSet = new Set();
    const branchesSet  = new Set();
    for (const h of hierarchy) {
      if (h.com_sno != null) companiesSet.add(String(h.com_sno));
      if (h.div_sno != null) divisionsSet.add(String(h.div_sno));
      if (h.brn_sno != null) branchesSet.add(String(h.brn_sno));
    }

    const permissions = {};
    for (const s of screensData) {
      const screenName = screenNameById.get(s.screen_id);
      if (!screenName) continue;
      permissions[screenName] = {};
      for (const permId of s.permissions ?? []) {
        permissions[screenName][permId] = true;
      }
    }

    return {
      success: true,
      exists: true,
      permissions,
      companies: Array.from(companiesSet),
      divisions: Array.from(divisionsSet),
      branches: Array.from(branchesSet),
    };
  }

  // Create — POST /save_user_permissions_json
  static async saveUserPermissionsJson(req, res) {
    try {
      const { user_id, user_ecno, hierarchy, screens } = req.body;
      if (!user_id) {
        return res.status(400).json({ success: false, error: "user_id is required" });
      }

      await UserApprovalService.saveUserPermissionsJson({ user_id, user_ecno, hierarchy, screens });

      await invalidateCache(req.redisClient, "ua:permissions");
      if (user_ecno) await invalidateCache(req.redisClient, `ua:user_screens:${user_ecno}`);
      await invalidateCache(req.redisClient, `ua:user_perms:${user_id}`);

      if (req.io) {
        if (user_ecno) {
          req.io.to(`user:${user_ecno}`).emit("permissions:updated", {
            message: "Your permissions have been updated by an administrator",
            timestamp: new Date().toISOString(),
          });
        }
        req.io.emit("admin:permissions:updated", {
          user_id:   user_id ?? null,
          user_ecno: user_ecno ?? null,
          timestamp: new Date().toISOString(),
        });
      }

      res.json({ success: true, message: "Permissions saved successfully" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // Read — GET /get_user_permissions_json/:userId
  // Returns permissions in the same format the old getUserPermissions returned.
  static async getUserPermissionsJson(req, res) {
    try {
      const userId = req.params.userId;
      const [row, screenNameById] = await Promise.all([
        UserApprovalService.getUserPermissionsJsonById(userId),
        UserApprovalController.#buildScreenNameMap(),
      ]);

      res.json(UserApprovalController.#rowToPermissionsResponse(row, screenNameById));
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // Update — PUT /update_user_permissions_json/:userId
  static async updateUserPermissionsJson(req, res) {
    try {
      const userId = req.params.userId;
      const { hierarchy, screens, user_ecno } = req.body;

      const rowsAffected = await UserApprovalService.updateUserPermissionsJson(userId, { hierarchy, screens });
      if (!rowsAffected) {
        return res.status(404).json({ success: false, error: "No existing permissions record found for this user — use save_user_permissions_json to create one" });
      }

      await invalidateCache(req.redisClient, "ua:permissions");
      if (user_ecno) await invalidateCache(req.redisClient, `ua:user_screens:${user_ecno}`);
      await invalidateCache(req.redisClient, `ua:user_perms:${userId}`);

      if (req.io) {
        if (user_ecno) {
          req.io.to(`user:${user_ecno}`).emit("permissions:updated", {
            message: "Your permissions have been updated by an administrator",
            timestamp: new Date().toISOString(),
          });
        }
        req.io.emit("admin:permissions:updated", {
          user_id:   userId ?? null,
          user_ecno: user_ecno ?? null,
          timestamp: new Date().toISOString(),
        });
      }

      res.json({ success: true, message: "Permissions updated successfully" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // Delete — DELETE /delete_user_permissions_json/:userId
  static async deleteUserPermissionsJson(req, res) {
    try {
      const userId = req.params.userId;
      const { rowsAffected, ecno } = await UserApprovalService.deleteUserPermissionsJson(userId);

      await invalidateCache(req.redisClient, "ua:permissions");
      await invalidateCache(req.redisClient, `ua:user_perms:${userId}`);
      if (ecno) await invalidateCache(req.redisClient, `ua:user_screens:${ecno}`);

      if (req.io) {
        // Push to the revoked user immediately — their sidebar re-fetches and goes empty in real time.
        if (ecno) {
          req.io.to(`user:${ecno}`).emit("permissions:updated", {
            message: "Your permissions have been revoked by an administrator",
            timestamp: new Date().toISOString(),
          });
        }
        req.io.emit("admin:permissions:updated", {
          user_id:   userId ?? null,
          user_ecno: ecno   ?? null,
          timestamp: new Date().toISOString(),
        });
      }

      res.json({ success: true, message: rowsAffected ? "Permissions deleted successfully" : "No record found", deletedCount: rowsAffected });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async #consolidatePermissions(data) {
    const companyMap = new Map();
    const screenMap = new Map();

    for (const item of data) {
      if (item.com_sno != null) {
        if (!companyMap.has(item.com_sno)) {
          companyMap.set(item.com_sno, {
            com_name: item.com_name,
            com_sno: item.com_sno,
            divisions: new Map(),
          });
        }

        const company = companyMap.get(item.com_sno);

        if (item.div_sno != null) {
          if (!company.divisions.has(item.div_sno)) {
            company.divisions.set(item.div_sno, {
              div_name: item.div_name,
              div_sno: item.div_sno,
              branches: new Map(),
            });
          }

          const division = company.divisions.get(item.div_sno);

          if (item.brn_sno != null && !division.branches.has(item.brn_sno)) {
            division.branches.set(item.brn_sno, {
              brn_name: item.brn_name,
              brn_sno: item.brn_sno,
            });
          }
        }
      }

      if (item.screen_id != null) {
        let screen = screenMap.get(item.screen_id);
        if (!screen) {
          screen = {
            screen_name: item.screen_name,
            screen_id: item.screen_id,
            screen_comp: item.comp,
            screen_img: item.comp_img,
            group_id: item.group_id,
            permissions: new Map(),
          };
          screenMap.set(item.screen_id, screen);
        }
        if (item.permission_id != null && !screen.permissions.has(item.permission_id)) {
          screen.permissions.set(item.permission_id, {
            permission_id: item.permission_id,
            permission_name: item.permission_name,
          });
        }
      }
    }

    const companies = Array.from(companyMap.values()).map((company) => ({
      com_name: company.com_name,
      com_sno: company.com_sno,
      divisions: Array.from(company.divisions.values()).map((division) => ({
        div_name: division.div_name,
        div_sno: division.div_sno,
        branches: Array.from(division.branches.values()),
      })),
    }));

    const screens = Array.from(screenMap.values()).map((s) => ({
      screen_name: s.screen_name,
      screen_id: s.screen_id,
      screen_comp: s.screen_comp,
      screen_img: s.screen_img,
      group_id: s.group_id,
      permissions: Array.from(s.permissions.values()),
    }));

    return { companies, screens };
  }
}

export default UserApprovalController;
