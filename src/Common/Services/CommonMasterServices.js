import { initializeDatabase } from "../../Dbconnections/Dbconnections.js";
let mssqlPool = await initializeDatabase();

class CommonMasterServices {
    
    static extractValue(field) {
        if (field && typeof field === 'object' && field.hasOwnProperty('value')) {
            return field.value;
        }
        return field;
    }
   static async getBasicDetailsEmployee(masterField = {}) {
    // Select only the fields you need: ename and ecno
    let query = 'SELECT ename, ecno FROM vw_verified_employees WHERE 1=1';
    let params = [];
    
    if (masterField.ecno && masterField.ecno.length > 0) {
        query += ` AND ecno = @ecno`;
        params.push({ name: 'ecno', value: this.extractValue(masterField.ecno) });
    }
    
    const request = mssqlPool.request();
    
    // Add parameters to request
    params.forEach(param => {
        request.input(param.name, param.value);
    });

    const result = await request.query(query);
    
    // Return the result directly since we're selecting specific fields
    return result.recordset.map(row => ({
        ename: row.ename,
        ecno: row.ecno
    }));
}
    // Get all basic details with optional filters
    static async getBasicDetailsByFields(masterField = {}) {
        try {
            let query = 'SELECT * FROM vw_company_basic_details WHERE 1=1';
            let params = [];
            let paramIndex = 1;

            // Dynamic where clause building with value extraction
            if (masterField.com_sno) {
                query += ` AND com_sno = @param${paramIndex}`;
                params.push({ 
                    name: `param${paramIndex}`, 
                    value: CommonMasterServices.extractValue(masterField.com_sno) 
                });
                paramIndex++;
            }
            if (masterField.div_sno) {
                query += ` AND div_sno = @param${paramIndex}`;
                params.push({ 
                    name: `param${paramIndex}`, 
                    value: CommonMasterServices.extractValue(masterField.div_sno) 
                });
                paramIndex++;
            }
            if (masterField.brn_sno) {
                query += ` AND brn_sno = @param${paramIndex}`;
                params.push({ 
                    name: `param${paramIndex}`, 
                    value: CommonMasterServices.extractValue(masterField.brn_sno) 
                });
                paramIndex++;
            }
            if (masterField.dept_sno) {
                query += ` AND dept_sno = @param${paramIndex}`;
                params.push({ 
                    name: `param${paramIndex}`, 
                    value: CommonMasterServices.extractValue(masterField.dept_sno) 
                });
                paramIndex++;
            }

            // Text-based searches
            if (masterField.com_name) {
                query += ` AND com_name LIKE @param${paramIndex}`;
                params.push({ 
                    name: `param${paramIndex}`, 
                    value: `%${CommonMasterServices.extractValue(masterField.com_name)}%` 
                });
                paramIndex++;
            }
            if (masterField.div_name) {
                query += ` AND div_name LIKE @param${paramIndex}`;
                params.push({ 
                    name: `param${paramIndex}`, 
                    value: `%${CommonMasterServices.extractValue(masterField.div_name)}%` 
                });
                paramIndex++;
            }
            if (masterField.brn_name) {
                query += ` AND brn_name LIKE @param${paramIndex}`;
                params.push({ 
                    name: `param${paramIndex}`, 
                    value: `%${CommonMasterServices.extractValue(masterField.brn_name)}%` 
                });
                paramIndex++;
            }
            if (masterField.dept_name) {
                query += ` AND dept_name LIKE @param${paramIndex}`;
                params.push({ 
                    name: `param${paramIndex}`, 
                    value: `%${CommonMasterServices.extractValue(masterField.dept_name)}%` 
                });
                paramIndex++;
            }
            if (masterField.div_type) {
                query += ` AND div_type LIKE @param${paramIndex}`;
                params.push({ 
                    name: `param${paramIndex}`, 
                    value: `%${CommonMasterServices.extractValue(masterField.div_type)}%` 
                });
                paramIndex++;
            }

            // Add ordering
            query += ' ORDER BY com_name, div_name, brn_name, dept_name';

            // Add limit if specified (SQL Server uses TOP)
            if (masterField.limit) {
                const limitValue = parseInt(CommonMasterServices.extractValue(masterField.limit));
                query = query.replace('SELECT *', `SELECT TOP ${limitValue} *`);
            }


            // Execute query using SQL Server syntax
            const request = mssqlPool.request();
            
            // Add parameters to request with validation
            params.forEach(param => {
                request.input(param.name, param.value);
            });

            const result = await request.query(query);
            
            // Transform data to structured format
            return CommonMasterServices.transformToStructuredData(result.recordset);
            
        } catch (error) {
            console.error('Database Error:', error);
            throw new Error(`Database error: ${error.message}`);
        }
    }

    // Helper method to transform data into structured format
    static transformToStructuredData(rows) {
        if (!rows || rows.length === 0) {
            return {
                companies: [],
                divisions: [],
                branches: [],
                departments: [],
               
            };
        }

        // Extract unique companies
        const companiesMap = new Map();
        rows.forEach(row => {
            if (row.com_sno && row.com_name && !companiesMap.has(row.com_sno)) {
                companiesMap.set(row.com_sno, {
                    value: row.com_sno,
                    label: row.com_name,
                });
            }
        });

        // Extract unique divisions
        const divisionsMap = new Map();
        rows.forEach(row => {
            if (row.div_sno && row.div_name && !divisionsMap.has(row.div_sno)) {
                divisionsMap.set(row.div_sno, {
                    value: row.div_sno,
                    label: row.div_name,
                });
            }
        });

        // Extract unique branches
        const branchesMap = new Map();
        rows.forEach(row => {
            if (row.brn_sno && row.brn_name && !branchesMap.has(row.brn_sno)) {
                branchesMap.set(row.brn_sno, {
                    value: row.brn_sno,
                    label: row.brn_name,
                });
            }
        });

        // Extract unique departments
        const departmentsMap = new Map();
        rows.forEach(row => {
            if (row.dept_sno && row.dept_name && !departmentsMap.has(row.dept_sno)) {
                departmentsMap.set(row.dept_sno, {
                    value: row.dept_sno,
                    label: row.dept_name,
                });
            }
        });

        return {
            companies: Array.from(companiesMap.values()),
            divisions: Array.from(divisionsMap.values()),
            branches: Array.from(branchesMap.values()),
            departments: Array.from(departmentsMap.values()),
        };
    }

    // Get distinct companies
    static async getCompanies(searchTerm = null) {
        try {
            let query = `
                SELECT DISTINCT com_sno, com_name, com_prefix 
                FROM vw_company_basic_details 
                WHERE 1=1
            `;
            let params = [];

            if (searchTerm) {
                const searchValue = CommonMasterServices.extractValue(searchTerm);
                query += ' AND com_name LIKE @searchTerm';
                params.push({ name: 'searchTerm', value: `%${searchValue}%` });
            }

            query += ' ORDER BY com_name';

            const request = mssqlPool.request();
            params.forEach(param => {
                request.input(param.name, param.value);
            });

            const result = await request.query(query);
            
            return result.recordset.length > 0 ? result.recordset.map(row => ({
                value: row.com_sno,
                label: row.com_name,
            })) : [];
        } catch (error) {
            console.error('Database Error:', error);
            throw new Error(`Database error: ${error.message}`);
        }
    }

    // Get divisions by company
    static async getDivisionsByCompany(companyId, searchTerm = null) {
        try {
            let query = `
                SELECT DISTINCT div_sno, div_name, div_prefix, div_type 
                FROM vw_company_basic_details 
                WHERE com_sno = @companyId AND div_sno IS NOT NULL
            `;
            let params = [{ name: 'companyId', value: CommonMasterServices.extractValue(companyId) }];

            if (searchTerm) {
                const searchValue = CommonMasterServices.extractValue(searchTerm);
                query += ' AND div_name LIKE @searchTerm';
                params.push({ name: 'searchTerm', value: `%${searchValue}%` });
            }

            query += ' ORDER BY div_name';

            const request = mssqlPool.request();
            params.forEach(param => {
                request.input(param.name, param.value);
            });

            const result = await request.query(query);
            
            return result.recordset.length > 0 ? result.recordset.map(row => ({
                value: row.div_sno,
                label: row.div_name,
              
                companyId: CommonMasterServices.extractValue(companyId)
            })) : [];
        } catch (error) {
            console.error('Database Error:', error);
            throw new Error(`Database error: ${error.message}`);
        }
    }

    // Get branches by company and division
    static async getBranchesByCompanyDivision(companyId, divisionId, searchTerm = null) {
        try {
            let query = `
                SELECT DISTINCT brn_sno, brn_name, brn_prefix 
                FROM vw_company_basic_details 
                WHERE com_sno = @companyId AND div_sno = @divisionId AND brn_sno IS NOT NULL
            `;
            let params = [
                { name: 'companyId', value: CommonMasterServices.extractValue(companyId) },
                { name: 'divisionId', value: CommonMasterServices.extractValue(divisionId) }
            ];

            if (searchTerm) {
                const searchValue = CommonMasterServices.extractValue(searchTerm);
                query += ' AND brn_name LIKE @searchTerm';
                params.push({ name: 'searchTerm', value: `%${searchValue}%` });
            }

            query += ' ORDER BY brn_name';

            const request = mssqlPool.request();
            params.forEach(param => {
                request.input(param.name, param.value);
            });

            const result = await request.query(query);
            
            return result.recordset.length > 0 ? result.recordset.map(row => ({
                value: row.brn_sno,
                label: row.brn_name,
                companyId: CommonMasterServices.extractValue(companyId),
                divisionId: CommonMasterServices.extractValue(divisionId)
            })) : [];
        } catch (error) {
            console.error('Database Error:', error);
            throw new Error(`Database error: ${error.message}`);
        }
    }

    static async getDepartmentsByHierarchy(companyId, divisionId, branchId, searchTerm = null) {
        try {
            let query = `
                SELECT DISTINCT dept_sno, dept_name, dept_code 
                FROM vw_company_basic_details 
                WHERE com_sno = @companyId AND div_sno = @divisionId AND brn_sno = @branchId AND dept_sno IS NOT NULL
            `;
            let params = [
                { name: 'companyId', value: CommonMasterServices.extractValue(companyId) },
                { name: 'divisionId', value: CommonMasterServices.extractValue(divisionId) },
                { name: 'branchId', value: CommonMasterServices.extractValue(branchId) }
            ];

            if (searchTerm) {
                const searchValue = CommonMasterServices.extractValue(searchTerm);
                query += ' AND dept_name LIKE @searchTerm';
                params.push({ name: 'searchTerm', value: `%${searchValue}%` });
            }

            query += ' ORDER BY dept_name';

            const request = mssqlPool.request();
            params.forEach(param => {
                request.input(param.name, param.value);
            });

            const result = await request.query(query);
            
            return result.recordset.length > 0 ? result.recordset.map(row => ({
                value: row.dept_sno,
                label: row.dept_name,
               
                companyId: CommonMasterServices.extractValue(companyId),
                divisionId: CommonMasterServices.extractValue(divisionId),
                branchId: CommonMasterServices.extractValue(branchId)
            })) : [];
        } catch (error) {
            console.error('Database Error:', error);
            throw new Error(`Database error: ${error.message}`);
        }
    }
}

export default CommonMasterServices;
