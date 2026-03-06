import UserApprovalRepository from "../repository/UserApproval.repository.js";

class UserApprovalService {
  static userMasterRepo = new UserApprovalRepository();

  static async getAllCompanyByHierarchy() {
    return this.userMasterRepo.getAllCompanyByHierarchy();
  }

  static async getScreensWithGroups() {
    return this.userMasterRepo.getScreensWithGroups();
  }

  static async getPermissionDetails(userId) {
    return this.userMasterRepo.getPermissionDetails(userId);
  }

  static async saveUserPermissions(permissionData) {
    return this.userMasterRepo.saveUserPermissions(permissionData);
  }

  static async getUserScreensAndPermissions(ecno) {
    return this.userMasterRepo.getUserScreensAndPermissions(ecno);
  }

  static async getUserPermissionsById(userId) {
    return this.userMasterRepo.getUserPermissionsById(userId);
  }
}

export default UserApprovalService;
