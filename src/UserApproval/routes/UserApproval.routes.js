import express from "express";
import UserApprovalController from "../controllers/UserApproval.controller.js";
import { cacheMiddleware } from "../../Middleware/redisCache.js";

const UserApprovalrouter = express.Router();

UserApprovalrouter.get("/get_hierachy_com_details",  UserApprovalController.getAllCompanyByHierarchy);
UserApprovalrouter.get("/get_screens_with_groups",  UserApprovalController.getAllScreensWithGroups);
UserApprovalrouter.get("/get_permission_details",  UserApprovalController.getPermissionDetails);
// DEPRECATED — replaced by the nt_user_permissions_json JSON-column API below.
// UserApprovalrouter.post("/save_user_permissions", UserApprovalController.saveUserPermissions);
// UserApprovalrouter.get("/get_user_permissions/:userId", UserApprovalController.getUserPermissions);

// DEPRECATED — replaced by get_user_screens_and_permisssions_json below.
// UserApprovalrouter.get("/get_user_screens_and_permisssions/:ecno", UserApprovalController.getUserScreensAndPermissions);

// nt_user_permissions_json — hierarchy + screens/permissions stored as JSON columns
UserApprovalrouter.get("/get_user_screens_and_permisssions_json/:ecno", UserApprovalController.getUserScreensAndPermissionsJson);
UserApprovalrouter.post("/save_user_permissions_json", UserApprovalController.saveUserPermissionsJson);
UserApprovalrouter.get("/get_user_permissions_json/:userId", UserApprovalController.getUserPermissionsJson);
UserApprovalrouter.put("/update_user_permissions_json/:userId", UserApprovalController.updateUserPermissionsJson);
UserApprovalrouter.delete("/delete_user_permissions_json/:userId", UserApprovalController.deleteUserPermissionsJson);

export default UserApprovalrouter;
