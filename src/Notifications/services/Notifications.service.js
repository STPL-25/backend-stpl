import { nanoid } from "nanoid";

const NOTIF_KEY   = (ecno)  => `notifications:${ecno}`;
const MAX_NOTIFS  = 50;

/**
 * Push a new notification into Redis for a user.
 * Also emits socket event `notification:new` to that user's room.
 */
export async function createNotification(redisClient, io, { ecno, type = "info", title, message, data = {} }) {
  const notif = {
    id:        nanoid(10),
    type,        // info | success | warning | error | pr | approval
    title,
    message,
    read:      false,
    createdAt: new Date().toISOString(),
    data,
  };

  const key = NOTIF_KEY(ecno);
  // Push to head; cap list
  await redisClient.lPush(key, JSON.stringify(notif));
  await redisClient.lTrim(key, 0, MAX_NOTIFS - 1);
  await redisClient.expire(key, 60 * 60 * 24 * 7); // 7 days TTL

  // Emit in real-time via Socket.IO to user room
  if (io) {
    io.to(`user:${ecno}`).emit("notification:new", notif);
  }

  return notif;
}

/**
 * Get all notifications for a user from Redis.
 */
export async function getNotifications(redisClient, ecno) {
  const raw = await redisClient.lRange(NOTIF_KEY(ecno), 0, -1);
  return raw.map((s) => JSON.parse(s));
}

/**
 * Mark a single notification as read.
 */
export async function markAsRead(redisClient, ecno, notifId) {
  const key  = NOTIF_KEY(ecno);
  const raw  = await redisClient.lRange(key, 0, -1);
  const list = raw.map((s) => JSON.parse(s));
  const idx  = list.findIndex((n) => n.id === notifId);

  if (idx === -1) return null;

  list[idx].read = true;
  // Update in-place using LSET
  await redisClient.lSet(key, idx, JSON.stringify(list[idx]));
  return list[idx];
}

/**
 * Mark all notifications as read for a user.
 */
export async function markAllAsRead(redisClient, ecno) {
  const key  = NOTIF_KEY(ecno);
  const raw  = await redisClient.lRange(key, 0, -1);
  const list = raw.map((s) => JSON.parse(s));

  await Promise.all(
    list.map((n, idx) => {
      if (!n.read) {
        n.read = true;
        return redisClient.lSet(key, idx, JSON.stringify(n));
      }
    })
  );
  return list.map((n) => ({ ...n, read: true }));
}

/**
 * Delete all notifications for a user.
 */
export async function clearNotifications(redisClient, ecno) {
  await redisClient.del(NOTIF_KEY(ecno));
}

/**
 * Unread count helper.
 */
export async function getUnreadCount(redisClient, ecno) {
  const raw  = await redisClient.lRange(NOTIF_KEY(ecno), 0, -1);
  return raw.map((s) => JSON.parse(s)).filter((n) => !n.read).length;
}
