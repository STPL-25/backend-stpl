import express from "express";
import cors from "cors";
import helmet from "helmet";
import compression from "compression";
import { createServer } from "node:http";
import { Server } from "socket.io";
import session from "express-session";
// Redis integration commented out — will be reintegrated later.
// import { RedisStore } from "connect-redis";
// import { createClient } from "redis";
// import { createAdapter } from "@socket.io/redis-adapter";
import cookieParser from "cookie-parser";
import { configDotenv } from "dotenv";
import swaggerUi from "swagger-ui-express";
import { swaggerSpec } from "./src/swagger/swaggerConfig.js";
import commonMasterRouter from "./src/Masters/Routes/CommonMasterRoutes.js";
import commonBasicDetailsRouter from "./src/Common/Routes/CommonMasterRoutes.js";
import signUpRouter from "./src/Login/Routes/SignUpRoutes.js";
import BudgetRouter from "./src/Budget/Routes/BudgetRoutes.js";
import basicAuth from "./src/AuthMiddleware/BasicAuth.js";
import verifyJWT from "./src/AuthMiddleware/JwtAuth.js";
import { getHierarchyJson, orgRoomsForHierarchy } from "./src/Middleware/hierarchyScope.js";
import UserApprovalrouter from "./src/UserApproval/routes/UserApproval.routes.js";
import Kycrouter from "./src/Kyc/routes/Kyc.routes.js";
import ServiceAgreementRouter from "./src/ServiceAgreement/routes/ServiceAgreement.routes.js";
import { startServiceAgreementScheduledJobs } from "./src/ServiceAgreement/jobs/AgreementPoJob.js";
import ServicePoRouter from "./src/ServicePo/routes/ServicePo.routes.js";
import LoanVoucherRouter from "./src/LoanVoucher/routes/LoanVoucher.routes.js";
import ServiceGrnRouter from "./src/ServiceGrn/routes/ServiceGrn.routes.js";
import ServiceVendorKycRouter from "./src/ServiceVendorKyc/routes/ServiceVendorKyc.routes.js";
import PublicKycRouter from "./src/Kyc/routes/PublicKyc.routes.js";
import imageRouter from "./src/Utils/ImagesUpload/imageRoute.js";
import WorkFlowApprovalrouter from "./src/WorkFlowApproval/routes/WorkFlowApproval.routes.js";
import PRrouter from "./src/PR/routes/PR.routes.js";
import POrouter from "./src/PO/routes/PO.routes.js";
import PRTrackingRouter from "./src/PRTracking/routes/PRTracking.routes.js";
import StorePOrouter from "./src/StorePO/routes/StorePO.routes.js";
import PurchaseTeamRouter from "./src/PurchaseTeam/routes/PurchaseTeam.routes.js";
import NonStaffUserRouter from "./src/NonStaffUser/routes/NonStaffUser.routes.js";
import TermsConditionsRouter from "./src/TermsConditions/routes/TermsConditions.routes.js";
import ProductStockLevelRouter from "./src/ProductStockLevel/routes/ProductStockLevel.routes.js";
import GRNRouter from "./src/GRN/routes/GRN.routes.js";
import { authLimiter, apiLimiter } from "./src/Middleware/rateLimiter.js";
import { payloadCrypto } from "./src/Middleware/payloadCrypto.js";
import cryptoDebugRouter from "./src/Utils/CryptoDebug/cryptoDebugRoutes.js";
import jwt from "jsonwebtoken";
configDotenv({ path: `.env.${process.env.NODE_ENV || "development"}` });

const app = express();
const server = createServer(app);
app.set("trust proxy", 1); // behind API gateway — real client IP for rate limiting / logs

// Shared secret for grn-service -> this backend service calls (currently
// just POST /internal/broadcast). Must match grn-service's env value.
const INTERNAL_BROADCAST_SECRET = process.env.INTERNAL_BROADCAST_SECRET;

// ----------------------------
// REDIS SETUP
// ----------------------------
// Redis integration commented out — will be reintegrated later.
// const redisClient = createClient({
//     socket: {
//         host: process.env.REDIS_HOST || "localhost",
//         port: parseInt(process.env.REDIS_PORT || "6379"),
//         reconnectStrategy: (retries) => {
//             if (retries > 10) return new Error("Redis connection failed after 10 retries");
//             return Math.min(retries * 50, 500);
//         },
//     },
//     // password: process.env.REDIS_PASSWORD,
// });
//
// redisClient.on("error", (err) => console.error("Redis Client Error:", err));
// redisClient.on("connect", () => console.log("Redis Client Connected"));
// await redisClient.connect();
// console.log("Redis Client:", redisClient);
//
// // Pub/Sub clients for Socket.IO adapter
// const pubClient = redisClient.duplicate();
// const subClient = redisClient.duplicate();
// await Promise.all([pubClient.connect(), subClient.connect()]);
const redisClient = null;

// ----------------------------
// SOCKET.IO (in-memory adapter — Redis adapter commented out, will be reintegrated later)
// ----------------------------
// Allowed CORS origins (HTTP + Socket.IO) — CLIENT_URL may be a comma-separated
// list; localhost dev origins are only added outside production
// const allowedOrigins = [
//     ...(process.env.CLIENT_URL?.split(",").map((o) => o.trim()) ?? []),
//     ...(process.env.NODE_ENV !== "production"
//         ? ["http://localhost:5173"]
//         : []),
// ].filter(Boolean);
const allowedOrigins = true;

const io = new Server(server, {
    cors: {
        origin: allowedOrigins,
        credentials: true,
    },
    // adapter: createAdapter(pubClient, subClient),
});

// Redis integration commented out — will be reintegrated later.
// Separate subscriber: bridges grn-service (stateless, no Socket.IO of its
// own) into this process's `io` instance. grn-service publishes
// { room, event, payload } JSON on "socket:broadcast" whenever GRN/Gate
// Entry/Inventory data changes; we just re-emit it to the target room.
// const appSubClient = redisClient.duplicate();
// await appSubClient.connect();
// await appSubClient.subscribe("socket:broadcast", (message) => {
//     try {
//         const { room, event, payload } = JSON.parse(message);
//         if (room && event) io.to(room).emit(event, payload);
//     } catch (err) {
//         console.error("socket:broadcast message error:", err.message);
//     }
// });

// Socket.IO: load the express session from the cookie so socket.request.session.jwt is available
io.use((socket, next) => {
    sessionMiddleware(socket.request, {}, next);
});

// Socket.IO session authentication — reads JWT from server-side session (HttpOnly cookie)
io.use((socket, next) => {
    try {
        const jwtToken = socket.request.session?.jwt;
        if (!jwtToken) return next(new Error("Authentication required"));
        const payload = jwt.verify(jwtToken, process.env.JWT_SECRET, { algorithms: ["HS256"] });
        socket.user = payload.user ?? payload;
        next();
    } catch {
        next(new Error("Invalid or expired session"));
    }
});

// scopeKey is "{com_sno|x}:{div_sno|x}:{brn_sno|x}" (see PR.repository.js's
// buildScopeKey) — validates it against a resolved hierarchy using the same
// wildcard rule as the SQL @HierarchyJson filters (a hierarchy row with
// div_sno/brn_sno = NULL grants everything under it).
function hierarchyAllowsScopeKey(hierarchy, scopeKey) {
    if (!scopeKey || typeof scopeKey !== "string") return false;
    const [comStr, divStr, brnStr] = scopeKey.split(":");
    const com = comStr === "x" ? null : Number(comStr);
    const div = divStr === "x" ? null : Number(divStr);
    const brn = brnStr === "x" ? null : Number(brnStr);
    if (com == null) return false;
    return (hierarchy ?? []).some(
        (h) => h.com_sno === com && (h.div_sno == null || h.div_sno === div) && (h.brn_sno == null || h.brn_sno === brn)
    );
}

io.on("connection", (socket) => {
    const user = Array.isArray(socket.user) ? socket.user[0] : socket.user;
    const ecno = user?.ecno;
    if (ecno) socket.join(`user:${ecno}`);

    // Resolved once per connection and reused for every scoped join below —
    // an ecno with no assigned hierarchy resolves to [] (sees nothing),
    // same fail-closed default as the GET-endpoint scoping.
    let hierarchyReady = getHierarchyJson(ecno).then((hierarchy) => {
        socket.hierarchy = hierarchy;
        // Org-scoped rooms for domains converted so far (GRN, Inventory) are
        // joined automatically alongside their existing flat rooms below —
        // see join-grn/join-inventory.
        return hierarchy;
    });

       // PR dept-scope rooms: pr:scope:{com_sno}:{div_sno}:{brn_sno} — only
       // joined when the caller's own hierarchy actually covers that scope,
       // not trusted blindly from the client.
    socket.on("join-pr-scope", async (scopeKey) => {
        const hierarchy = socket.hierarchy ?? (await hierarchyReady);
        if (scopeKey && typeof scopeKey === "string" && hierarchyAllowsScopeKey(hierarchy, scopeKey)) {
            socket.join(`pr:scope:${scopeKey}`);
        }
    });

    socket.on("leave-pr-scope", (scopeKey) => {
        if (scopeKey && typeof scopeKey === "string") socket.leave(`pr:scope:${scopeKey}`);
    });

    socket.on("join-pr-approval", () => {
        socket.join("pr:approval");
    });

    socket.on("leave-pr-approval", () => {
        socket.leave("pr:approval");
    });

    socket.on("join-po-approval", () => {
        socket.join("po:approval");
    });

    socket.on("leave-po-approval", () => {
        socket.leave("po:approval");
    });

    // Purchase Team room: live PR-split updates on the purchase screen sidebar
    socket.on("join-purchase-team", () => {
        socket.join("purchase-team");
    });

    socket.on("leave-purchase-team", () => {
        socket.leave("purchase-team");
    });

    socket.on("join-kyc-approval", () => {
        socket.join("kyc:approval");
    });

    socket.on("leave-kyc-approval", () => {
        socket.leave("kyc:approval");
    });

    socket.on("join-service-agreement-approval", () => {
        socket.join("service_agreement:approval");
    });

    socket.on("leave-service-agreement-approval", () => {
        socket.leave("service_agreement:approval");
    });

    socket.on("join-service-po-approval", () => {
        socket.join("service_po:approval");
    });

    socket.on("leave-service-po-approval", () => {
        socket.leave("service_po:approval");
    });

    socket.on("join-loan-voucher-approval", () => {
        socket.join("loan_voucher:approval");
    });

    socket.on("leave-loan-voucher-approval", () => {
        socket.leave("loan_voucher:approval");
    });

    socket.on("join-service-vendor-kyc-approval", () => {
        socket.join("service_vendor_kyc:approval");
    });

    socket.on("leave-service-vendor-kyc-approval", () => {
        socket.leave("service_vendor_kyc:approval");
    });

    // GRN / Gate Entry room: live updates on the GRN + Gate Entry pages.
    // gate_entry:*/grn:draft:* events still go out on the flat "grn:live"
    // room (unchanged, unscoped) — grn:created is now org-scoped instead
    // (see grn-service's broadcastGRNCreated/hierarchyScope.js's
    // orgRoomTargets), so this also joins the caller's own org-scoped rooms
    // so they keep receiving it.
    socket.on("join-grn", async () => {
        socket.join("grn:live");
        const hierarchy = socket.hierarchy ?? (await hierarchyReady);
        for (const room of orgRoomsForHierarchy("grn", hierarchy)) socket.join(room);
    });

    socket.on("leave-grn", () => {
        socket.leave("grn:live");
        for (const room of [...socket.rooms]) {
            if (room.startsWith("grn:live:com:")) socket.leave(room);
        }
    });

    // PR Tracking room: one requester's full PR journey (pr:track:updated),
    // fired from every touch point along PR -> Quotation -> PO -> Dispatch ->
    // Gate Entry -> GRN -> Inventory. Keyed per pr_no (unlike the broader
    // scope/domain rooms above) so a single tracking page doesn't have to
    // filter a firehose of every other PR's events client-side.
    socket.on("join-pr-track", (pr_no) => {
        if (pr_no && typeof pr_no === "string") socket.join(`pr:track:${pr_no}`);
    });

    socket.on("leave-pr-track", (pr_no) => {
        if (pr_no && typeof pr_no === "string") socket.leave(`pr:track:${pr_no}`);
    });

    // Invoice / Payment rooms: live updates on the Invoice and Payment pages,
    // bridged from grn-service via /internal/broadcast
    socket.on("join-invoice", () => {
        socket.join("invoice:live");
    });

    socket.on("leave-invoice", () => {
        socket.leave("invoice:live");
    });

    socket.on("join-payment", () => {
        socket.join("payment:live");
    });

    socket.on("leave-payment", () => {
        socket.leave("payment:live");
    });

    // Inventory room: live stock updates (inventory:updated) and stock
    // request updates (stockrequest:updated), including auto-posted
    // receipts from GRN. Both event types are now org-scoped (see
    // hierarchyScope.js's orgRoomTargets) — falls back to the flat
    // "inventory:live" room only for the rare item with no org ever
    // assigned, so this also joins the caller's own org-scoped rooms.
    socket.on("join-inventory", async () => {
        socket.join("inventory:live");
        const hierarchy = socket.hierarchy ?? (await hierarchyReady);
        for (const room of orgRoomsForHierarchy("inventory", hierarchy)) socket.join(room);
    });

    socket.on("leave-inventory", () => {
        socket.leave("inventory:live");
        for (const room of [...socket.rooms]) {
            if (room.startsWith("inventory:live:com:")) socket.leave(room);
        }
    });

    socket.on("disconnect", () => {});
});

// ----------------------------
// SECURITY HEADERS
// ----------------------------
app.use(helmet({
    crossOriginResourcePolicy: { policy: "cross-origin" },
    contentSecurityPolicy: false, // Allow Swagger UI inline scripts
}));
app.use(compression());

// ----------------------------
// CORS
// ----------------------------
app.use(cors({
    origin: allowedOrigins,
    credentials: true,
    methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allowedHeaders: ["Content-Type", "Authorization"],
}));

app.use(express.json({ limit: "50mb" }));
app.use(express.urlencoded({ extended: true, limit: "50mb" }));

// ----------------------------
// SESSION (in-memory store — Redis store commented out, will be reintegrated later)
// ----------------------------
app.use(cookieParser());
const sessionMiddleware = session({
    // store: new RedisStore({
    //     client: redisClient,
    //     prefix: "sess:",
    //     ttl: 7200, // 2 hours max in Redis (inactivity timeout is 30 min server-side)
    // }),
    secret: process.env.SESSION_SECRET,
    resave: false,
    saveUninitialized: false,
    rolling: true, // resets cookie maxAge on every response (keeps session alive while active)
    name: "sessionId",
    cookie: {
        httpOnly: true,
        secure: process.env.NODE_ENV === "production",
        sameSite: process.env.NODE_ENV === "production" ? "none" : "lax",
        maxAge: 1000 * 60 * 60 * 2, // 2 hours cookie lifetime (server enforces 30-min inactivity)
    },
});
app.use(sessionMiddleware);


// Make io and redisClient available in all route handlers
app.use((req, _res, next) => {
    req.io          = io;
    req.redisClient = redisClient;
    next();
});

// ----------------------------
// SWAGGER API DOCS  (public — no auth required)
// ----------------------------
app.use(
    "/api-docs",
    swaggerUi.serve,
    swaggerUi.setup(swaggerSpec, {
        customSiteTitle: "Non-Trade ERP API Docs",
        customCss: `
            .swagger-ui .topbar { background: linear-gradient(135deg,#1e293b 0%,#334155 100%); }
            .swagger-ui .topbar-wrapper img { display:none; }
            .swagger-ui .topbar-wrapper::before { content:" Non-Trade ERP API"; color:#fff; font-size:18px; font-weight:700; }
        `,
        swaggerOptions: { persistAuthorization: true, filter: true, displayRequestDuration: true },
    })
);
// app.get("/api-docs.json", (_req, res) => res.json(swaggerSpec));

// Public health check (probed by the API gateway)
app.get("/health", (_req, res) =>
    res.json({ status: "ok", timestamp: new Date().toISOString(), docs: "/api-docs" })
);

// Internal: resolves the caller's session cookie to its JWT. grn-service is
// stateless and only accepts Authorization: Bearer <jwt>, so the gateway
// calls this (forwarding the client's Cookie header) to bridge the browser's
// session cookie into a bearer token — without either service sharing a
// session store.
app.get("/internal/session-jwt", (req, res) => {
    if (!req.session?.jwt) return res.status(401).json({ success: false });
    res.json({ jwt: req.session.jwt });
});

// Internal: grn-service (stateless, no Socket.IO of its own) posts here to
// re-emit a real-time event on this process's `io` instance. Replaces the
// old Redis pub/sub bridge (see grn-service/src/utils/socketBroadcast.js),
// which silently dropped every event because neither service had a Redis
// client wired up. Authenticated with a shared secret, not the user's
// session — this is a service-to-service call, not a browser request.
app.post("/internal/broadcast", (req, res) => {
    if (!INTERNAL_BROADCAST_SECRET || req.headers["x-internal-secret"] !== INTERNAL_BROADCAST_SECRET) {
        return res.status(403).json({ success: false });
    }
    const { room, event, payload } = req.body ?? {};
    if (!room || !event) {
        return res.status(400).json({ success: false, message: "room and event are required" });
    }
    io.to(room).emit(event, payload);
    res.json({ success: true });
});

// ----------------------------
// ROUTES
// ----------------------------

// Crypto debug routes — DEV/TESTING only (blocked in production by the router itself)
app.use("/api/debug", cryptoDebugRouter);

// Auth routes — BasicAuth + rate limiter (no JWT required at this stage)
app.use("/api/secure",   signUpRouter);

// Protected API routes — require valid JWT + general rate limit + payload encryption
app.use("/api/common_master",      verifyJWT,   commonMasterRouter);
app.use("/api/user_approval",      verifyJWT,    UserApprovalrouter);
app.use("/api/common_basic_details",     commonBasicDetailsRouter);
app.use("/api/budget",            verifyJWT,      BudgetRouter);
app.use("/api/kyc",                verifyJWT,    Kycrouter);
app.use("/api/service_vendor_kyc", verifyJWT,    ServiceVendorKycRouter);
app.use("/api/service_agreement",  verifyJWT,    ServiceAgreementRouter);
app.use("/api/service_grn",        verifyJWT,    ServiceGrnRouter);
app.use("/api/service_po",         verifyJWT,    ServicePoRouter);
app.use("/api/loan_voucher",       verifyJWT,    LoanVoucherRouter);
app.use("/api/workflow_approval",     verifyJWT,     WorkFlowApprovalrouter);
app.use("/api/pr",                    verifyJWT,                    PRrouter);
app.use("/api/po",                    verifyJWT,                    POrouter);
app.use("/api/pr_tracking",           verifyJWT,          PRTrackingRouter);
// app.use("/api/store_po",             apiLimiter, verifyJWT, payloadCrypto, StorePOrouter);
app.use("/api/purchase_team",       verifyJWT,       PurchaseTeamRouter);
app.use("/api/terms_conditions",    verifyJWT,       TermsConditionsRouter);
app.use("/api/product_stock_level", verifyJWT,       ProductStockLevelRouter);
// Not globally wrapped in verifyJWT — per-route auth inside the router
// itself (create/list are staff-only; login is public and issues the same
// session cookie as staff login, so a non-staff user lands on the same
// Dashboard, not a separate portal), same pattern as grn-service's
// SupplierRouter.
app.use("/api/nonstaff",            NonStaffUserRouter);
// Anonymous self-service supplier KYC intake — the /supplier_kyc frontend
// route. No staff session exists at submission time, so this can never be
// wrapped in verifyJWT; see PublicKyc.routes.js for exactly what it exposes.
app.use("/api/public_kyc",          PublicKycRouter);
// app.use("/api/grn",                  apiLimiter, verifyJWT, payloadCrypto, GRNRouter);
// In-app notifications now live in notification-service (see
// notification-service/src/notifications) — the gateway routes
// /api/notifications there directly instead of here.
app.use(imageRouter);


// ----------------------------
// GLOBAL ERROR HANDLER
// ----------------------------
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
    const status = err.status ?? 500;
    res.status(status).json({
        success: false,
        message: process.env.NODE_ENV === "production" ? "Internal server error" : err.message,
    });
});

// ----------------------------
// 404 HANDLER
// ----------------------------
app.use((req, res) => {
    res.status(404).json({ success: false, message: `Route ${req.originalUrl} not found` });
});

// ----------------------------
// GRACEFUL SHUTDOWN
// ----------------------------
async function shutdown() {
    console.log("Shutting down server...");
    // Redis integration commented out — will be reintegrated later.
    // await Promise.all([redisClient.quit(), pubClient.quit(), subClient.quit(), appSubClient.quit()]);
    server.close(() => {
        console.log("HTTP server closed");
        process.exit(0);
    });
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

// ----------------------------
// START SERVER
// ----------------------------
const PORT = process.env.PORT||8081 ;
server.listen(PORT, () => {
    console.log(`Server running on port ${PORT} [${process.env.NODE_ENV || "development"}]`);
    console.log(`API Docs → http://localhost:${PORT}/api-docs`);
    console.log(` Health  → http://localhost:${PORT}/health`);
    startServiceAgreementScheduledJobs();
});
