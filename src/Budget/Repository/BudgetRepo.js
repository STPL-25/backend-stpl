
import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";
let mssqlPool = await initializeDatabase();

class BudgetRepo {
    constructor() {
       

        this.createProcedureMap = {
            'budget': 'sp_nt_CreateBudgetRecords',
            'getBudget': 'sp_Get_Budget_Details'
        };

       
    }

    async postBudgetData(data) {
        try {
            const procedureName = this.createProcedureMap.budget;     
            const result = await this.executeStoredProcedure(procedureName, data);
            return result;
        } catch (error) {
            throw new Error(`Error in postBudgetData: ${error.message}`);
        }
    }
        async getBudgetData(data) {
        try {
            const procedureName = this.createProcedureMap.getBudget;     
            const result = await this.executeStoredProcedure(procedureName, data);
            return result;
        } catch (error) {
            throw new Error(`Error in postBudgetData: ${error.message}`);
        }
    }

    async executeStoredProcedure(procedureName, parameters = {}) {
        try {
            const request = mssqlPool.request();
            if (Object.keys(parameters).length > 0) {
                request.input('jsonInput', mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
            }
            const result = await request.execute(procedureName);
            return result.recordset;

        } catch (error) {
            throw new Error(`Database error: ${error.message}`);
        }
    }
}

export default BudgetRepo;
