import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";
let mssqlPool = await initializeDatabase();

class SignUpRepo {
  constructor() {
    this.storedProcedureMap = {
      CompanyMaster: "sp_nt_GetCompanyRecords",
      get_all_users_sign_up: "sp_nt_GetAllUsersSignUp",
    };

    this.createProcedureMap = {
      sign_up: "sp_nt_sign_up",
      log_in: "sp_nt_Login",
    };
  }

  async createUser(masterField, userData) {
    try {
      const storedProcedure = this.createProcedureMap[masterField];
      if (!storedProcedure) {
        throw new Error(`Invalid master field: ${masterField}`);
      }
      const result = await this.executeStoredProcedure(
        storedProcedure,
        userData
      );
      return result;
    } catch (error) {
      throw new Error(`Error fetching ${masterField} data: ${error.message}`);
    }
  }
  async isUserExists(ecno) {
    try {
      if (!ecno) {
        return false; 
      }

      if (typeof ecno !== "string") {
        throw new Error("ECNO must be a string");
      }

      const trimmedEcno = ecno.trim();
      if (trimmedEcno === "") {
        return false; 
      }

      if (trimmedEcno.length > 10) {
        throw new Error("ECNO exceeds maximum length of 10 characters");
      }

      // Check if pool is available
      if (!mssqlPool || !mssqlPool.connected) {
        throw new Error("Database connection not available");
      }

      const request = mssqlPool.request();
      request.input("ecno", mssql.VarChar(10), trimmedEcno);

      const result = await request.execute("sp_nt_check_user_exists");

      // Handle result properly
      if (!result.recordset || result.recordset.length === 0) {
        return false;
      }

      const userExists = result.recordset[0]?.UserExists;

      // Ensure we return a boolean
      return Boolean(userExists);
    } catch (error) {
      console.error(`Database error in isUserExists for ECNO: ${ecno}`, {
        error: error.message,
        stack: error.stack,
        timestamp: new Date().toISOString(),
      });

      return false;
    }
  }
   async logInUser(masterField, ecno, sign_up_pass) {
  try {
    const storedProcedure = this.createProcedureMap[masterField];
    if (!storedProcedure) {
      throw new Error(`Invalid master field: ${masterField}`);
    }
    const isUserExists = await this.isUserExists(ecno);
    if (!isUserExists) {
      throw new Error("User does not exist. Please sign up first.");
    }
      const result = await this.executeStoredProcedure(storedProcedure, { ecno, sign_up_pass });
      return result;
    } catch (error) {
      console.error('Error in logInUser:', error);
      throw new Error(`Error logging in user: ${error.message}`);
    }
  }

  async executeStoredProcedure(procedureName, parameters = {}) {
    try {
      const request = mssqlPool.request();
      if (Object.keys(parameters).length > 0) {
        request.input(
          "jsonInput",
          mssql.NVarChar(mssql.MAX),
          JSON.stringify(parameters)
        );
      }
      const result = await request.execute(procedureName);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }
  async getAllUsers() {
    try {
      const storedProcedure = this.storedProcedureMap["get_all_users_sign_up"];
      if (!storedProcedure) {
        throw new Error(`Invalid stored procedure for get_all_users_sign_up`);
      }
      const result = await this.executeStoredProcedure(storedProcedure);
      return result;
    } catch (error) {
      console.error('Error in getAllUsers:', error);
      throw new Error(`Error fetching all users: ${error.message}`);
    }
  }
}

export default SignUpRepo;
