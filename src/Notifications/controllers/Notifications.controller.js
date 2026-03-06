import * as NotifService from "../services/Notifications.service.js";

/** GET /api/notifications */
export async function listNotifications(req, res) {
  try {
    const ecno  = req.user?.ecno;
    if (!ecno) return res.status(401).json({ success: false, message: "Unauthorized" });

    const list  = await NotifService.getNotifications(req.redisClient, ecno);
    const unread = list.filter((n) => !n.read).length;

    res.json({ success: true, data: list, unread });
  } catch (err) {
    res.status(500).json({ success: false, message: err.message });
  }
}

/** POST /api/notifications   (body: { ecno?, type, title, message, data }) */
export async function sendNotification(req, res) {
  try {
    const { ecno, type, title, message, data } = req.body;
    const targetEcno = ecno || req.user?.ecno;
    if (!targetEcno || !title || !message) {
      return res.status(400).json({ success: false, message: "ecno, title and message are required" });
    }

    const notif = await NotifService.createNotification(req.redisClient, req.io, {
      ecno: targetEcno, type, title, message, data,
    });

    res.status(201).json({ success: true, data: notif });
  } catch (err) {
    res.status(500).json({ success: false, message: err.message });
  }
}

/** PATCH /api/notifications/:id/read */
export async function markRead(req, res) {
  try {
    const ecno = req.user?.ecno;
    if (!ecno) return res.status(401).json({ success: false, message: "Unauthorized" });

    const updated = await NotifService.markAsRead(req.redisClient, ecno, req.params.id);
    if (!updated) return res.status(404).json({ success: false, message: "Notification not found" });

    res.json({ success: true, data: updated });
  } catch (err) {
    res.status(500).json({ success: false, message: err.message });
  }
}

/** PATCH /api/notifications/read-all */
export async function markAllRead(req, res) {
  try {
    const ecno = req.user?.ecno;
    if (!ecno) return res.status(401).json({ success: false, message: "Unauthorized" });

    const list = await NotifService.markAllAsRead(req.redisClient, ecno);
    res.json({ success: true, data: list });
  } catch (err) {
    res.status(500).json({ success: false, message: err.message });
  }
}

/** DELETE /api/notifications */
export async function clearAll(req, res) {
  try {
    const ecno = req.user?.ecno;
    if (!ecno) return res.status(401).json({ success: false, message: "Unauthorized" });

    await NotifService.clearNotifications(req.redisClient, ecno);
    res.json({ success: true, message: "All notifications cleared" });
  } catch (err) {
    res.status(500).json({ success: false, message: err.message });
  }
}

/** GET /api/notifications/unread-count */
export async function unreadCount(req, res) {
  try {
    const ecno  = req.user?.ecno;
    if (!ecno) return res.status(401).json({ success: false, message: "Unauthorized" });
    const count = await NotifService.getUnreadCount(req.redisClient, ecno);
    res.json({ success: true, count });
  } catch (err) {
    res.status(500).json({ success: false, message: err.message });
  }
}
