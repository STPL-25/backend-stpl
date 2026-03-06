import { Router } from "express";
import {
  listNotifications,
  sendNotification,
  markRead,
  markAllRead,
  clearAll,
  unreadCount,
} from "../controllers/Notifications.controller.js";

const router = Router();

/**
 * @swagger
 * tags:
 *   name: Notifications
 *   description: Real-time notification management (Redis + Socket.IO)
 */

/**
 * @swagger
 * /api/notifications:
 *   get:
 *     summary: Get all notifications for the authenticated user
 *     tags: [Notifications]
 *     security:
 *       - bearerAuth: []
 *     responses:
 *       200:
 *         description: List of notifications with unread count
 *         content:
 *           application/json:
 *             schema:
 *               type: object
 *               properties:
 *                 success: { type: boolean }
 *                 data:
 *                   type: array
 *                   items:
 *                     $ref: '#/components/schemas/Notification'
 *                 unread: { type: integer }
 */
router.get("/", listNotifications);

/**
 * @swagger
 * /api/notifications/unread-count:
 *   get:
 *     summary: Get unread notification count
 *     tags: [Notifications]
 *     security:
 *       - bearerAuth: []
 *     responses:
 *       200:
 *         description: Unread count
 */
router.get("/unread-count", unreadCount);

/**
 * @swagger
 * /api/notifications:
 *   post:
 *     summary: Create and broadcast a notification
 *     tags: [Notifications]
 *     security:
 *       - bearerAuth: []
 *     requestBody:
 *       required: true
 *       content:
 *         application/json:
 *           schema:
 *             type: object
 *             required: [title, message]
 *             properties:
 *               ecno:    { type: string }
 *               type:    { type: string, enum: [info, success, warning, error, pr, approval] }
 *               title:   { type: string }
 *               message: { type: string }
 *               data:    { type: object }
 *     responses:
 *       201:
 *         description: Notification created and emitted
 */
router.post("/", sendNotification);

/**
 * @swagger
 * /api/notifications/read-all:
 *   patch:
 *     summary: Mark all notifications as read
 *     tags: [Notifications]
 *     security:
 *       - bearerAuth: []
 *     responses:
 *       200:
 *         description: All notifications marked as read
 */
router.patch("/read-all", markAllRead);

/**
 * @swagger
 * /api/notifications/{id}/read:
 *   patch:
 *     summary: Mark a single notification as read
 *     tags: [Notifications]
 *     security:
 *       - bearerAuth: []
 *     parameters:
 *       - in: path
 *         name: id
 *         required: true
 *         schema: { type: string }
 *     responses:
 *       200:
 *         description: Notification marked as read
 *       404:
 *         description: Not found
 */
router.patch("/:id/read", markRead);

/**
 * @swagger
 * /api/notifications:
 *   delete:
 *     summary: Clear all notifications for the authenticated user
 *     tags: [Notifications]
 *     security:
 *       - bearerAuth: []
 *     responses:
 *       200:
 *         description: All notifications cleared
 */
router.delete("/", clearAll);

export default router;
