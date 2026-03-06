import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";
let mssqlPool = await initializeDatabase();

class HierarchyMasterRepo {
  constructor() {
    this.storedProcedureMap = {
      HierarchyMaster: "sp_GetHierarchicalData",
    };
  }

  async getAllHierarchyData(data) {
    try {
      const storedProcedure = this.storedProcedureMap["HierarchyMaster"];

      if (!storedProcedure) {
        throw new Error(`Invalid master field: ${masterField}`);
      }

      const result = await this.executeStoredProcedure(storedProcedure, data);
      return result;
    } catch (error) {
      throw new Error(`Error fetching ${masterField} data: ${error.message}`);
    }
  }
  async executeStoredProcedure(procedureName, data) {
    try {
      const request = mssqlPool.request();
      if (data) {
        request.input("FormData", mssql.VarChar(mssql.MAX), JSON.stringify(data));
      }
    //   if (Object.keys(parameters.Filters).length > 0) {
    //     request.input("Filters", mssql.NVarChar(mssql.MAX), parameters.Filters);
    //   }
      const result = await request.execute(procedureName);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }
}

export default HierarchyMasterRepo;
