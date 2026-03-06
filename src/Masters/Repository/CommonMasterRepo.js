
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
            'ScreenMaster': 'sp_nt_GetScreenRecords',
            'ScreenPermission': 'sp_nt_GetScreenPermissionRecords',
            'getCompanyDetailsByHierarchy': 'sp_nt_all_com_details_in_hierachy',
            'ProductMaster': 'sp_nt_GetProductRecords',
            'CategoryMaster': 'sp_nt_GetCategoryRecords',
            'SubCategoryMaster': 'sp_nt_GetSubCategoryRecords',
            'ProductCategoryMaster': "sp_product_catagory",
            'ProductSubCategoryMaster': "sp_product_sub_catagory",
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
             'HierarchyMaster': 'sp_GetHierarchicalData',
            'ScreenMaster': 'sp_nt_CreateScreenRecords',
            'ScreenPermission': 'sp_nt_CreatePermissionRecords',
            'ProductMaster': 'sp_nt_CreateProductRecord',
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
        this.fieldMappings = {
        'CompanyMaster': { label: 'com_name', value: 'com_sno' },
        'DivisionMaster': { label: 'div_name', value: 'div_sno', extra: ['com_sno'] },
        'BranchMaster': { label: 'brn_name', value: 'brn_sno', extra: ['div_sno', 'com_sno'] },
        'UomMaster': { label: 'uom_name', value: 'uom_sno' },
        'GSTStateCodeMaster': { label: 'gst_code', value: 'gst_sno' },
        'AcYearMaster': { label: 'ac_year', value: 'ac_sno' },
        'PriorityMaster': { label: 'priority_name', value: 'priority_sno' },
        'DeptMaster': { label: 'dept_name', value: 'dept_sno', extra: ['brn_sno', 'div_sno', 'com_sno'] },
        'ScreenMaster': { label: 'screen_name', value: 'screen_id' },
        'ProductMaster': { label: 'prod_name', value: 'prod_sno' },
        'CategoryMaster': { label: 'cat_name', value: 'cat_sno' },
        'SubCategoryMaster': { label: 'subcat_name', value: 'subcat_sno' },
    };

    }

    async getAllCommonMasters(masterField) {
        try {
            const storedProcedure = this.storedProcedureMap[masterField.trim()];
            
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
    async getAllCompanyByHierarchy() {
        try {
            const storedProcedure = this.storedProcedureMap['getCompanyDetailsByHierarchy']; 
            if (!storedProcedure) {
                throw new Error(`Invalid stored procedure `);
            }
            const result = await this.executeStoredProcedure(storedProcedure);
            return result;
        } catch (error) {
            throw new Error(`Error fetching hierarchical data: ${error.message}`);
        }
    }
async getRequiredMasterForOptions(masterFields) {
    try {
        if (!Array.isArray(masterFields) || masterFields.length === 0) {
            throw new Error('masterFields must be a non-empty array');
        }

        const results = {};

        // Fetch all masters in parallel
        const promises = masterFields.map(async (masterField) => {
            try {
                const storedProcedure = this.storedProcedureMap[masterField.trim()];
                
                if (!storedProcedure) {
                    console.warn(`Invalid master field: ${masterField}`);
                    return { masterField, data: [] };
                }

                const data = await this.executeStoredProcedure(storedProcedure);
                return { masterField, data };
            } catch (error) {
                console.error(`Error fetching ${masterField}:`, error.message);
                return { masterField, data: [] };
            }
        });

        const fetchedData = await Promise.all(promises);

        // Transform each master data into {label, value} format
        fetchedData.forEach(({ masterField, data }) => {
            results[masterField] = this.#transformToOptions(data, masterField);
        });

        return results;
    } catch (error) {
        throw new Error(`Error in getRequiredMasterForOptions: ${error.message}`);
    }
}
   #transformToOptions(data, masterField) {
    if (!Array.isArray(data) || data.length === 0) {
        return [];
    }

    // Define label and value field mappings for each master
 
    const mapping = this.fieldMappings[masterField];
    
    if (!mapping) {
        // Fallback: try to detect common field patterns
        const firstItem = data[0];
        const keys = Object.keys(firstItem);
        
        const labelField = keys.find(k => 
            k.toLowerCase().includes('name') || 
            k.toLowerCase().includes('description')
        ) || keys[1] || keys[0];
        
        const valueField = keys.find(k => 
            k.toLowerCase().includes('id') || 
            k.toLowerCase().includes('code')
        ) || keys[0];

        return data.map(item => ({
            label: item[labelField]?.toString() || '',
            value: item[valueField]
        }));
    }

    return data.map(item => {
        const option = {
            label: item[mapping.label]?.toString() || '',
            value: item[mapping.value]
        };
        if (mapping.extra) {
            mapping.extra.forEach(field => {
                option[field] = item[field] ?? null;
            });
        }
        return option;
    });
}

}

export default CommonMasterRepo;
