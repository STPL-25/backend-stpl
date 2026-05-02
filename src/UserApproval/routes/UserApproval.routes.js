import express from "express";
import UserApprovalController from "../controllers/UserApproval.controller.js";
import { cacheMiddleware } from "../../Middleware/redisCache.js";

const UserApprovalrouter = express.Router();

UserApprovalrouter.get("/get_hierachy_com_details", cacheMiddleware("ua:hierarchy", 600), UserApprovalController.getAllCompanyByHierarchy);
UserApprovalrouter.get("/get_screens_with_groups", cacheMiddleware("ua:screens", 600), UserApprovalController.getAllScreensWithGroups);
UserApprovalrouter.get("/get_permission_details", cacheMiddleware("ua:permissions", 600), UserApprovalController.getPermissionDetails);
UserApprovalrouter.post("/save_user_permissions", UserApprovalController.saveUserPermissions);
UserApprovalrouter.get("/get_user_screens_and_permisssions/:ecno", cacheMiddleware((req) => `ua:user_screens:${req.params.ecno}`, 300), UserApprovalController.getUserScreensAndPermissions);
UserApprovalrouter.get("/get_user_permissions/:userId", cacheMiddleware((req) => `ua:user_perms:${req.params.userId}`, 300), UserApprovalController.getUserPermissions);

export default UserApprovalrouter;
