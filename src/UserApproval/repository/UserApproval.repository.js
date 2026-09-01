import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";
let mssqlPool = await initializeDatabase();

class UserApprovalRepository {
  constructor() {
    this.storedProcedureMap = {
    'getCompanyDetailsByHierarchy': 'sp_nt_all_com_details_in_hierachy',
    'getScreensWithGroups': 'sp_get_screen_groups_with_screens',
    'getPermission': 'sp_getPermission'

    };

    this.createProcedureMap = {
        // DEPRECATED — replaced by nt_user_permissions_json JSON-column storage below.
        // 'saveUserPermissions': 'dbo.SaveUserPermissions'
    };

    this.updateProcedureMap = {
    
    };

    this.deleteProcedureMap = {
   
    };
  }

  

  async #executeStoredProcedure(procedureName, parameters = {}) {
    try {
      const request = mssqlPool.request();
      if (Object.keys(parameters).length > 0) {
        request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
      }
      const result = await request.execute(procedureName);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }
 async getAllCompanyByHierarchy() {
        try {
            const storedProcedure = this.storedProcedureMap['getCompanyDetailsByHierarchy']; 
            if (!storedProcedure) {
                throw new Error(`Invalid stored procedure `);
            }
            const result = await this.#executeStoredProcedure(storedProcedure);
            return result;
        } catch (error) {
            throw new Error(`Error fetching hierarchical data: ${error.message}`);
        }
    }
    async getScreensWithGroups() {
        try {
            const storedProcedure = this.storedProcedureMap['getScreensWithGroups'];
            if (!storedProcedure) {
                throw new Error(`Invalid stored procedure `);
            }
            const result = await this.#executeStoredProcedure(storedProcedure);
            return result;
        } catch (error) {
            throw new Error(`Error fetching hierarchical data: ${error.message}`);
        }
    }
    async getPermissionDetails() {
        try {
            const storedProcedure = this.storedProcedureMap['getPermission'];   
            if (!storedProcedure) {
                throw new Error(`Invalid stored procedure `);
            }
            const result = await this.#executeStoredProcedure(storedProcedure);
            return result;
        } catch (error) {
            throw new Error(`Error fetching permission details: ${error.message}`);
        }
    }
    /* DEPRECATED — replaced by saveUserPermissionsJson() below, which writes to nt_user_permissions_json.
    async saveUserPermissions(permissionData) {
        try {
            console.log(permissionData)
            const storedProcedure = this.createProcedureMap['saveUserPermissions'];
            if (!storedProcedure) {
                throw new Error(`Invalid stored procedure`);
            }
            const result = await this.#executeStoredProcedure(storedProcedure, permissionData);
            return result;
        } catch (error) {
            console.log(error)
            throw new Error(`Error saving user permissions: ${error.message}`);
        }
    }
    */
    /* DEPRECATED — replaced by getUserScreensAndPermissionsJson() below, which reads from nt_user_permissions_json
       via sp_nt_GetUserScreensAndPermissionsJson.
    async getUserScreensAndPermissions(ecno) {
      try {
          const storedProcedure = 'sp_nt_GetUserScreenPermissions';
          const result = await this.#executeStoredProcedure(storedProcedure, { ecno });
          return result;
      } catch (error) {
          throw new Error(`Error fetching user screens and permissions: ${error.message}`);
      }
    }
    */

    /* DEPRECATED — replaced by getUserPermissionsJsonById() below, which reads from nt_user_permissions_json.
    // Fetch permissions by nt_sign_up_sno (used in PermissionManager for pre-population)
    async getUserPermissionsById(userId) {
        console.log(userId)
      try {
          const storedProcedure = 'sp_nt_GetUserScreenPermissions';
          const result = await this.#executeStoredProcedure(storedProcedure, { ecno: userId });
          return result;
      } catch (error) {
        console.log(error)
          throw new Error(`Error fetching user permissions by id: ${error.message}`);
      }
    }
    */

    // ── nt_user_permissions_json — hierarchy + screen permissions stored as JSON columns ──
    // All reads/writes go through stored procedures (sp_nt_*Json), matching the rest of this module's convention.

    // user_id (staff) and login_id (non-staff, dbo.nt_nonstaff_login) are mutually
    // exclusive — sp_nt_SaveUserPermissionsJson stores whichever one is present.
    async saveUserPermissionsJson({ user_id, user_ecno, login_id, hierarchy, screens }) {
        try {
            const result = await this.#executeStoredProcedure('sp_nt_SaveUserPermissionsJson', {
                user_id: user_id ?? null,
                ecno: user_ecno ?? null,
                login_id: login_id ?? null,
                hierarchy: hierarchy ?? [],
                screens: screens ?? [],
            });
            return result[0];
        } catch (error) {
            throw new Error(`Error saving user permissions: ${error.message}`);
        }
    }

    // { userId } for a staff nt_sign_up_sno, or { loginId } for a non-staff login_id — exactly one.
    async getUserPermissionsJsonById({ userId, loginId } = {}) {
        try {
            const result = await this.#executeStoredProcedure('sp_nt_GetUserPermissionsJson', {
                userId: userId ?? null,
                loginId: loginId ?? null,
            });
            return result[0] ?? null;
        } catch (error) {
            throw new Error(`Error fetching user permissions by id: ${error.message}`);
        }
    }

    async updateUserPermissionsJson({ userId, loginId } = {}, { hierarchy, screens }) {
        try {
            const result = await this.#executeStoredProcedure('sp_nt_UpdateUserPermissionsJson', {
                userId: userId ?? null,
                loginId: loginId ?? null,
                hierarchy: hierarchy ?? [],
                screens: screens ?? [],
            });
            return result[0]?.rows_affected ?? 0;
        } catch (error) {
            throw new Error(`Error updating user permissions: ${error.message}`);
        }
    }

    // Returns { rowsAffected, ecno } — ecno is the deleted row's ecno, needed so the
    // controller can push a real-time "permissions revoked" event to that user's socket room.
    // (Non-staff rows have no ecno, so no socket event fires for them — expected, they don't
    // use the staff Dashboard shell this event refreshes.)
    async deleteUserPermissionsJson({ userId, loginId } = {}) {
        try {
            const result = await this.#executeStoredProcedure('sp_nt_DeleteUserPermissionsJson', {
                userId: userId ?? null,
                loginId: loginId ?? null,
            });
            return { rowsAffected: result[0]?.rows_affected ?? 0, ecno: result[0]?.ecno ?? null };
        } catch (error) {
            throw new Error(`Error deleting user permissions: ${error.message}`);
        }
    }

    // Sidebar reader — builds the same flat row shape the old vw_UserPermissions-backed
    // sp_nt_GetUserScreenPermissions returned, but sourced from nt_user_permissions_json.
    async getUserScreensAndPermissionsJson({ ecno, loginId } = {}) {
        try {
            const result = await this.#executeStoredProcedure('sp_nt_GetUserScreensAndPermissionsJson', {
                ecno: ecno ?? null,
                loginId: loginId ?? null,
            });
            return result;
        } catch (error) {
            throw new Error(`Error fetching user screens and permissions: ${error.message}`);
        }
    }
}

export default UserApprovalRepository;
