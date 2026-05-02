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
