import express from "express";
import NonStaffUserController from "../controllers/NonStaffUser.controller.js";
import verifyJWT from "../../AuthMiddleware/JwtAuth.js";

const NonStaffUserRouter = express.Router();

// Staff-only — admin create/list (Non-Staff User Management screen)
NonStaffUserRouter.post("/create", verifyJWT, NonStaffUserController.createUser);
NonStaffUserRouter.get("/list", verifyJWT, NonStaffUserController.listUsers);

// Public — signs in via the same session cookie as staff (see controller)
NonStaffUserRouter.post("/login", NonStaffUserController.login);

// Session-authenticated (verifyJWT) — same mechanism as staff
NonStaffUserRouter.post("/reset-password", verifyJWT, NonStaffUserController.resetPassword);
NonStaffUserRouter.get("/me", verifyJWT, NonStaffUserController.me);

export default NonStaffUserRouter;
