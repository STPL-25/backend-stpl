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

  /* DEPRECATED — replaced by the JSON-column based methods below.
  static async saveUserPermissions(permissionData) {
    return this.userMasterRepo.saveUserPermissions(permissionData);
  }

  static async getUserPermissionsById(userId) {
    return this.userMasterRepo.getUserPermissionsById(userId);
  }
  */

  /* DEPRECATED — replaced by getUserScreensAndPermissionsJson below.
  static async getUserScreensAndPermissions(ecno) {
    return this.userMasterRepo.getUserScreensAndPermissions(ecno);
  }
  */

  static async getUserScreensAndPermissionsJson(ecno) {
    return this.userMasterRepo.getUserScreensAndPermissionsJson(ecno);
  }

  static async saveUserPermissionsJson(data) {
    return this.userMasterRepo.saveUserPermissionsJson(data);
  }

  static async getUserPermissionsJsonById(userId) {
    return this.userMasterRepo.getUserPermissionsJsonById(userId);
  }

  static async updateUserPermissionsJson(userId, data) {
    return this.userMasterRepo.updateUserPermissionsJson(userId, data);
  }

  static async deleteUserPermissionsJson(userId) {
    return this.userMasterRepo.deleteUserPermissionsJson(userId);
  }
}

export default UserApprovalService;
