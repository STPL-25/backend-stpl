import { describe, it, expect, beforeEach, jest } from "@jest/globals";
import { mockReq, mockRes, createMockRedis } from "./setup.js";
import {
  createNotification,
  getNotifications,
  markAsRead,
  markAllAsRead,
  clearNotifications,
  getUnreadCount,
} from "../src/Notifications/services/Notifications.service.js";
import {
  listNotifications,
  sendNotification,
  markRead,
  markAllRead,
  clearAll,
  unreadCount,
} from "../src/Notifications/controllers/Notifications.controller.js";

// ─── Service Tests ────────────────────────────────────────────────────────────
describe("Notification Service", () => {
  let redis;

  beforeEach(() => {
    redis = createMockRedis();
  });

  it("createNotification — pushes to Redis and returns notif object", async () => {
    const io = { to: jest.fn().mockReturnValue({ emit: jest.fn() }) };
    const notif = await createNotification(redis, io, {
      ecno: "E001", type: "info", title: "Test", message: "Hello",
    });

    expect(notif.id).toBeTruthy();
    expect(notif.title).toBe("Test");
    expect(notif.read).toBe(false);
    expect(notif.type).toBe("info");

    // Check Redis list has one item
    const list = await redis.lRange("notifications:E001", 0, -1);
    expect(list.length).toBe(1);
    expect(JSON.parse(list[0]).title).toBe("Test");
  });

  it("createNotification — emits socket event notification:new", async () => {
    const emitFn = jest.fn();
    const io = { to: jest.fn().mockReturnValue({ emit: emitFn }) };

    await createNotification(redis, io, { ecno: "E002", title: "PR", message: "Approved" });

    expect(io.to).toHaveBeenCalledWith("user:E002");
    expect(emitFn).toHaveBeenCalledWith("notification:new", expect.objectContaining({ title: "PR" }));
  });

  it("getNotifications — returns all notifications for user", async () => {
    const io = { to: jest.fn().mockReturnValue({ emit: jest.fn() }) };
    await createNotification(redis, io, { ecno: "E003", title: "A", message: "msg1" });
    await createNotification(redis, io, { ecno: "E003", title: "B", message: "msg2" });

    const list = await getNotifications(redis, "E003");
    expect(list.length).toBe(2);
    // Newest first (lPush → reverse chronological)
    expect(list[0].title).toBe("B");
    expect(list[1].title).toBe("A");
  });

  it("markAsRead — marks a single notification read", async () => {
    const io = { to: jest.fn().mockReturnValue({ emit: jest.fn() }) };
    const n  = await createNotification(redis, io, { ecno: "E004", title: "X", message: "m" });

    const updated = await markAsRead(redis, "E004", n.id);
    expect(updated.read).toBe(true);

    const list = await getNotifications(redis, "E004");
    expect(list[0].read).toBe(true);
  });

  it("markAsRead — returns null for non-existent id", async () => {
    const result = await markAsRead(redis, "E005", "does-not-exist");
    expect(result).toBeNull();
  });

  it("markAllAsRead — marks every notification read", async () => {
    const io = { to: jest.fn().mockReturnValue({ emit: jest.fn() }) };
    await createNotification(redis, io, { ecno: "E006", title: "A", message: "m1" });
    await createNotification(redis, io, { ecno: "E006", title: "B", message: "m2" });

    await markAllAsRead(redis, "E006");
    const list = await getNotifications(redis, "E006");
    expect(list.every((n) => n.read)).toBe(true);
  });

  it("getUnreadCount — returns correct count", async () => {
    const io = { to: jest.fn().mockReturnValue({ emit: jest.fn() }) };
    const n1 = await createNotification(redis, io, { ecno: "E007", title: "A", message: "m1" });
    await createNotification(redis, io, { ecno: "E007", title: "B", message: "m2" });

    expect(await getUnreadCount(redis, "E007")).toBe(2);
    await markAsRead(redis, "E007", n1.id);
    expect(await getUnreadCount(redis, "E007")).toBe(1);
  });

  it("clearNotifications — deletes the Redis key", async () => {
    const io = { to: jest.fn().mockReturnValue({ emit: jest.fn() }) };
    await createNotification(redis, io, { ecno: "E008", title: "C", message: "m" });
    await clearNotifications(redis, "E008");

    const list = await getNotifications(redis, "E008");
    expect(list.length).toBe(0);
  });
});

// ─── Controller Tests ─────────────────────────────────────────────────────────
describe("Notification Controller", () => {
  let redis;

  beforeEach(() => {
    redis = createMockRedis();
  });

  it("listNotifications — 401 if no user", async () => {
    const req = mockReq({ user: null, redisClient: redis });
    const res = mockRes();
    await listNotifications(req, res);
    expect(res.status).toHaveBeenCalledWith(401);
  });

  it("listNotifications — 200 with empty array initially", async () => {
    const req = mockReq({ user: { ecno: "EC1" }, redisClient: redis });
    const res = mockRes();
    await listNotifications(req, res);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ success: true, unread: 0 }));
  });

  it("sendNotification — 400 on missing title", async () => {
    const req = mockReq({ user: { ecno: "EC2" }, redisClient: redis, io: null, body: { message: "hi" } });
    const res = mockRes();
    await sendNotification(req, res);
    expect(res.status).toHaveBeenCalledWith(400);
  });

  it("sendNotification — 201 on success", async () => {
    const ioMock = { to: jest.fn().mockReturnValue({ emit: jest.fn() }) };
    const req = mockReq({
      user: { ecno: "EC3" }, redisClient: redis, io: ioMock,
      body: { title: "PR Approved", message: "Your PR has been approved", type: "success" },
    });
    const res = mockRes();
    await sendNotification(req, res);
    expect(res.status).toHaveBeenCalledWith(201);
    const call = res.json.mock.calls[0][0];
    expect(call.success).toBe(true);
    expect(call.data.title).toBe("PR Approved");
  });

  it("markRead — 404 for unknown id", async () => {
    const req = mockReq({ user: { ecno: "EC4" }, redisClient: redis, params: { id: "no-such-id" } });
    const res = mockRes();
    await markRead(req, res);
    expect(res.status).toHaveBeenCalledWith(404);
  });

  it("clearAll — 200 and empty list after clear", async () => {
    const ioMock = { to: jest.fn().mockReturnValue({ emit: jest.fn() }) };
    // seed one notification
    await createNotification(redis, ioMock, { ecno: "EC5", title: "T", message: "m" });

    const req = mockReq({ user: { ecno: "EC5" }, redisClient: redis });
    const res = mockRes();
    await clearAll(req, res);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ success: true }));

    const list = await getNotifications(redis, "EC5");
    expect(list.length).toBe(0);
  });

  it("unreadCount — returns correct count via controller", async () => {
    const ioMock = { to: jest.fn().mockReturnValue({ emit: jest.fn() }) };
    await createNotification(redis, ioMock, { ecno: "EC6", title: "X", message: "m" });
    await createNotification(redis, ioMock, { ecno: "EC6", title: "Y", message: "m" });

    const req = mockReq({ user: { ecno: "EC6" }, redisClient: redis });
    const res = mockRes();
    await unreadCount(req, res);
    expect(res.json).toHaveBeenCalledWith({ success: true, count: 2 });
  });
});
