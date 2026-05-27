import swaggerJSDoc from "swagger-jsdoc";

const options = {
  definition: {
    openapi: "3.0.0",
    info: {
      title: "Non-Trade ERP API",
      version: "1.0.0",
      description:
        "REST API documentation for the Non-Trade ERP Procurement System. " +
        "Protected routes use the HttpOnly session cookie created by `/api/secure/log_user`. " +
        "For non-production Postman testing, generate a Bearer token with `/api/debug/token`.",
      contact: { name: "SKTM IT", email: "it@sktm.com" },
    },
    servers: [
      { url: "http://localhost:5000", description: "Local Development" },
    ],
    components: {
      securitySchemes: {
        bearerAuth: {
          type: "http",
          scheme: "bearer",
          bearerFormat: "JWT",
          description:
            "Non-production only: pass the raw JWT returned by `/api/debug/token`.",
        },
      },
      schemas: {
        Notification: {
          type: "object",
          properties: {
            id:        { type: "string", example: "abc123xyz" },
            type:      { type: "string", enum: ["info","success","warning","error","pr","approval"], example: "info" },
            title:     { type: "string", example: "PR Approved" },
            message:   { type: "string", example: "Your purchase requisition #PR-001 has been approved." },
            read:      { type: "boolean", example: false },
            createdAt: { type: "string", format: "date-time" },
            data:      { type: "object" },
          },
        },
        ApiResponse: {
          type: "object",
          properties: {
            success: { type: "boolean" },
            message: { type: "string" },
            data:    { type: "object" },
          },
        },
        ErrorResponse: {
          type: "object",
          properties: {
            success: { type: "boolean", example: false },
            message: { type: "string", example: "Unauthorized" },
          },
        },
      },
    },
    security: [{ bearerAuth: [] }],
  },
  apis: [
    "./src/Login/Routes/*.js",
    "./src/Masters/Routes/*.js",
    "./src/Budget/Routes/*.js",
    "./src/Kyc/routes/*.js",
    "./src/PR/routes/*.js",
    "./src/UserApproval/routes/*.js",
    "./src/WorkFlowApproval/routes/*.js",
    "./src/Notifications/routes/*.js",
  ],
};

export const swaggerSpec = swaggerJSDoc(options);
