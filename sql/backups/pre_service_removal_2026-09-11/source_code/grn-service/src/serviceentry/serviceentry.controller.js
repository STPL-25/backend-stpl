import ServiceEntryService from "./serviceentry.service.js";
import { invalidateCache, invalidateCacheByPattern } from "../middleware/redisCache.js";
import { broadcast } from "../utils/socketBroadcast.js";

function getAuthUser(req) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  return user;
}

class ServiceEntryController {
  static async getPendingServicePOs(req, res) {
    try {
      const data = await ServiceEntryService.getPendingServicePOs(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getServiceEntriesByPO(req, res) {
    try {
      const { po_basic_sno } = req.params;
      const data = await ServiceEntryService.getServiceEntriesByPO(Number(po_basic_sno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async createServiceEntry(req, res) {
    try {
      const user = getAuthUser(req);
      const data = await ServiceEntryService.createServiceEntry({ ...req.body, created_by: user?.ecno });
      await invalidateCache(req.redisClient, "service_entry:all", "service_entry:pending_pos");
      await invalidateCacheByPattern(req.redisClient, "service_entry:by_po:*");
      broadcast("service_entry:live", "service_entry:created", data?.[0]);
      res.json({ success: true, data, message: "Service Entry created" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async approveServiceEntry(req, res) {
    try {
      const user = getAuthUser(req);
      const { service_entry_sno, comments, action } = req.body;
      if (!service_entry_sno || !action) {
        return res.status(400).json({ success: false, error: "service_entry_sno and action are required" });
      }
      if (action === "reject" && !comments?.trim()) {
        return res.status(400).json({ success: false, error: "comments are required when rejecting" });
      }
      const data = await ServiceEntryService.approveServiceEntry({
        service_entry_sno,
        approved_by: user?.ecno,
        comments: comments || "",
        action,
      });
      await invalidateCache(req.redisClient, "service_entry:all");
      broadcast("service_entry:live", "service_entry:approval:updated", { service_entry_sno, action, approved_by: user?.ecno });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getAllServiceEntries(req, res) {
    try {
      const user = getAuthUser(req);
      const { status, mine } = req.query;
      const filters = { status };
      if (mine === "true") filters.Ecno = user?.ecno;
      const data = await ServiceEntryService.getAllServiceEntries(filters);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default ServiceEntryController;
