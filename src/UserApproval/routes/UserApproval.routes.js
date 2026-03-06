import express from "express";
import UserApprovalController from "../controllers/UserApproval.controller.js";

const UserApprovalrouter = express.Router();

UserApprovalrouter.get("/get_hierachy_com_details", UserApprovalController.getAllCompanyByHierarchy);
UserApprovalrouter.get("/get_screens_with_groups", UserApprovalController.getAllScreensWithGroups);
UserApprovalrouter.get("/get_permission_details", UserApprovalController.getPermissionDetails);
UserApprovalrouter.post("/save_user_permissions", UserApprovalController.saveUserPermissions);
UserApprovalrouter.get("/get_user_screens_and_permisssions/:ecno", UserApprovalController.getUserScreensAndPermissions);
// Pre-populate existing permissions for a selected user in PermissionManager
UserApprovalrouter.get("/get_user_permissions/:userId", UserApprovalController.getUserPermissions);

export default UserApprovalrouter;
