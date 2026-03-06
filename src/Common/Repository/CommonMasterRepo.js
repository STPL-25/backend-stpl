
import mssql from "mssql";
import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";
let mssqlPool = await initializeDatabase();

class CommonMasterRepo {
    constructor() {
        this.storedProcedureMap = {
            'CompanyMaster': 'sp_nt_GetCompanyRecords',
            'DivisionMaster': 'sp_nt_GetDivisionsRecords', 
            'BranchMaster': 'sp_nt_GetBranchesRecords',
            'UomMaster': 'sp_nt_GetUomRecords',
            'GSTStateCodeMaster': 'sp_nt_GetStateGstRecords',
            'AcYearMaster': 'sp_nt_GetAcYearRecords',
            'PriorityMaster': 'sp_nt_GetPriorityRecords',
            'DeptMaster': 'sp_nt_GetDeptRecords',
        };

        this.createProcedureMap = {
            'CompanyMaster': 'sp_nt_CreateCompanyRecords',
            'DivisionMaster': 'sp_nt_CreateDivRecords',
            'BranchMaster': 'sp_nt_CreateBranchRecords',
            'UomMaster': 'sp_nt_CreateUomRecords',
            'GSTStateCodeMaster': 'sp_nt_CreateGstStateRecords',
            'AcYearMaster': 'sp_nt_CreateAcYearRecords',
            'PriorityMaster': 'sp_nt_CreatePriorityRecords',
            'DeptMaster': 'sp_nt_CreateDeptRecords',
            'HierarchyMaster': 'sp_GetHierarchicalData'
        };

        this.updateProcedureMap = {
            'CompanyMaster': 'sp_nt_UpdateCompanyRecords',
            'department': 'sp_nt_UpdateDepartmentRecords',
            'employee': 'sp_nt_UpdateEmployeeRecords',
            'role': 'sp_nt_UpdateRoleRecords',
            'location': 'sp_nt_UpdateLocationRecords',
        };

        this.deleteProcedureMap = {
            'CompanyMaster': 'sp_nt_DeleteCompanyRecords',
            'department': 'sp_nt_DeleteDepartmentRecords',
            'employee': 'sp_nt_DeleteEmployeeRecords',
            'role': 'sp_nt_DeleteRoleRecords',
            'location': 'sp_nt_DeleteLocationRecords',
        };
    }

    async getAllCommonMasters(masterField) {
        try {
            const storedProcedure = this.storedProcedureMap[masterField];
            
            if (!storedProcedure) {
                throw new Error(`Invalid master field: ${masterField}`);
            }

            // Execute stored procedure - replace with your DB connection logic
            const result = await this.executeStoredProcedure(storedProcedure);
            return result;
        } catch (error) {
            throw new Error(`Error fetching ${masterField} data: ${error.message}`);
        }
    }

    async getCommonMasterById(id, masterField) {
        try {
            const storedProcedure = this.storedProcedureMap[masterField.toLowerCase()];
            
            if (!storedProcedure) {
                throw new Error(`Invalid master field: ${masterField}`);
            }

            // Modify SP name for getting by ID or use parameters
            const result = await this.executeStoredProcedure(storedProcedure, { id });
            return result;
        } catch (error) {
            throw new Error(`Error fetching ${masterField} by ID: ${error.message}`);
        }
    }

    async createCommonMaster(masterField, data) {
        try {
            const storedProcedure = this.createProcedureMap[masterField];
            
            if (!storedProcedure) {
                throw new Error(`Invalid master field: ${masterField}`);
            }

            const result = await this.executeStoredProcedure(storedProcedure, data);
            return result;
        } catch (error) {
            throw new Error(`Error creating ${masterField}: ${error.message}`);
        }
    }

    async updateCommonMaster(id, masterField, data) {
        try {
            const storedProcedure = this.updateProcedureMap[masterField.toLowerCase()];
            
            if (!storedProcedure) {
                throw new Error(`Invalid master field: ${masterField}`);
            }

            const result = await this.executeStoredProcedure(storedProcedure, { id, ...data });
            return result;
        } catch (error) {
            throw new Error(`Error updating ${masterField}: ${error.message}`);
        }
    }

    async deleteCommonMaster(id, masterField) {
        try {
            const storedProcedure = this.deleteProcedureMap[masterField.toLowerCase()];
            
            if (!storedProcedure) {
                throw new Error(`Invalid master field: ${masterField}`);
            }

            const result = await this.executeStoredProcedure(storedProcedure, { id });
            return result;
        } catch (error) {
            throw new Error(`Error deleting ${masterField}: ${error.message}`);
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

export default CommonMasterRepo;
