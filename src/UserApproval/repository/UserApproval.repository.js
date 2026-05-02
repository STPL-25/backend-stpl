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
        'saveUserPermissions': 'dbo.SaveUserPermissions'
      
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
    async getUserScreensAndPermissions(ecno) {
      try {
          const storedProcedure = 'sp_nt_GetUserScreenPermissions';
          const result = await this.#executeStoredProcedure(storedProcedure, { ecno });
          return result;
      } catch (error) {
          throw new Error(`Error fetching user screens and permissions: ${error.message}`);
      }
    }

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
}

export default UserApprovalRepository;
