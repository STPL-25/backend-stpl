import express from "express";
import cors from "cors";
import helmet from "helmet";
import compression from "compression";
import { createServer } from "node:http";
import { Server } from "socket.io";
import session from "express-session";
import { RedisStore } from "connect-redis";
import { createClient } from "redis";
import { createAdapter } from "@socket.io/redis-adapter";
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
import UserApprovalrouter from "./src/UserApproval/routes/UserApproval.routes.js";
import Kycrouter from "./src/Kyc/routes/Kyc.routes.js";
import imageRouter from "./src/Utils/ImagesUpload/imageRoute.js";
import WorkFlowApprovalrouter from "./src/WorkFlowApproval/routes/WorkFlowApproval.routes.js";
import PRrouter from "./src/PR/routes/PR.routes.js";
import NotificationsRouter from "./src/Notifications/routes/Notifications.routes.js";
import { authLimiter, apiLimiter } from "./src/Middleware/rateLimiter.js";
import { payloadCrypto } from "./src/Middleware/payloadCrypto.js";
import jwt from "jsonwebtoken";

configDotenv();

const app = express();
const server = createServer(app);

// ----------------------------
// REDIS SETUP
// ----------------------------
const redisClient = createClient({
    url: process.env.REDIS_URL || "redis://localhost:6379",
    socket: {
        reconnectStrategy: (retries) => {
            if (retries > 10) return new Error("Redis connection failed after 10 retries");
            return Math.min(retries * 50, 500);
        },
    },
});

redisClient.on("error", (err) => console.error("Redis Client Error:", err));
redisClient.on("connect", () => console.log("Redis Client Connected"));
await redisClient.connect();
console.log("Redis Client:", redisClient);

// Pub/Sub clients for Socket.IO adapter
const pubClient = redisClient.duplicate();
const subClient = redisClient.duplicate();
await Promise.all([pubClient.connect(), subClient.connect()]);

// ----------------------------
// SOCKET.IO WITH REDIS ADAPTER
// ----------------------------
const io = new Server(server, {
    cors: {
        origin: process.env.CLIENT_URL,
        credentials: true,
    },
    adapter: createAdapter(pubClient, subClient),
});

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

io.on("connection", (socket) => {
    const user = Array.isArray(socket.user) ? socket.user[0] : socket.user;
    const ecno = user?.ecno;
    if (ecno) socket.join(`user:${ecno}`);
       // PR dept-scope rooms: pr:scope:{com_sno}:{div_sno}:{brn_sno}
    socket.on("join-pr-scope", (scopeKey) => {
        if (scopeKey && typeof scopeKey === "string") socket.join(`pr:scope:${scopeKey}`);
    });

    socket.on("leave-pr-scope", (scopeKey) => {
        if (scopeKey && typeof scopeKey === "string") socket.leave(`pr:scope:${scopeKey}`);
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
    origin: [process.env.CLIENT_URL, "http://localhost:5174","http://localhost:5176"].filter(Boolean),
    credentials: true,
    methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allowedHeaders: ["Content-Type", "Authorization"],
}));

app.use(express.json({ limit: "5mb" }));
app.use(express.urlencoded({ extended: true, limit: "5mb" }));

// ----------------------------
// SESSION WITH REDIS STORE
// ----------------------------
app.use(cookieParser());
const sessionMiddleware = session({
    store: new RedisStore({
        client: redisClient,
        prefix: "sess:",
        ttl: 86400,
    }),
    secret: process.env.SESSION_SECRET,
    resave: false,
    saveUninitialized: false,
    name: "sessionId",
    cookie: {
        httpOnly: true,
        secure: process.env.NODE_ENV === "production",
        sameSite: process.env.NODE_ENV === "production" ? "none" : "lax",
        maxAge: 1000 * 60 * 60 * 24,
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
            .swagger-ui .topbar-wrapper::before { content:"🏭 Non-Trade ERP API"; color:#fff; font-size:18px; font-weight:700; }
        `,
        swaggerOptions: { persistAuthorization: true, filter: true, displayRequestDuration: true },
    })
);
app.get("/api-docs.json", (_req, res) => res.json(swaggerSpec));

// Public health check
app.get("/health", (_req, res) =>
    res.json({ status: "ok", timestamp: new Date().toISOString(), redis: redisClient.isReady ? "connected" : "disconnected", docs: "/api-docs" })
);

// ----------------------------
// ROUTES
// ----------------------------

// Auth routes — BasicAuth + rate limiter (no JWT required at this stage)
app.use("/api/secure",  payloadCrypto, signUpRouter);

// Protected API routes — require valid JWT + general rate limit + payload encryption
app.use("/api/common_master",        apiLimiter, verifyJWT, payloadCrypto, commonMasterRouter);
app.use("/api/user_approval",        apiLimiter, verifyJWT, payloadCrypto, UserApprovalrouter);
app.use("/api/common_basic_details", apiLimiter, verifyJWT, payloadCrypto, commonBasicDetailsRouter);
app.use("/api/budget",               apiLimiter, verifyJWT, payloadCrypto, BudgetRouter);
app.use("/api/kyc",                  apiLimiter, verifyJWT, payloadCrypto, Kycrouter);
app.use("/api/workflow_approval",    apiLimiter, verifyJWT, payloadCrypto, WorkFlowApprovalrouter);
app.use("/api/pr",                   apiLimiter, verifyJWT, payloadCrypto, PRrouter);
app.use("/api/notifications",        apiLimiter, verifyJWT, payloadCrypto, NotificationsRouter);
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
    await Promise.all([redisClient.quit(), pubClient.quit(), subClient.quit()]);
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
const PORT = process.env.PORT || 5000;
server.listen(PORT, () => {
    console.log(`Server running on port ${PORT} [${process.env.NODE_ENV || "development"}]`);
    console.log(`API Docs → http://localhost:${PORT}/api-docs`);
    console.log(` Health  → http://localhost:${PORT}/health`);
});
