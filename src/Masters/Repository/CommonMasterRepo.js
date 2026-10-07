
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
            'UomClassMaster': 'sp_nt_GetUomClassRecords',
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
            "WorkflowMaster": "sp_nt_GetWorkflowMaster",
            "SupplierCatagoryMaster": "usp_GetSupplierCategoryRecords",
            "BusinessDetailsMatster": "sp_Get_Business_Details",
            "TransportMaster": "sp_nt_GetTransportRecords",
            "BankAccountTypeMaster": "sp_nt_GetBankAccountTypeRecords",
            "PaymentTermsMaster": "sp_nt_GetPaymentTermsRecords",
            "WarehouseLocationMaster": "sp_nt_GetWarehouseLocationRecords",
            "DesignationMaster": "sp_nt_GetDesignationRecords",
            "VendorMaster": "sp_nt_GetApprovedVendorsForServicePicker",
            // Restricted to vendor_category='SERVICE' — only Service Vendor
            // KYC-approved vendors, used by Service Agreement's supplier
            // pickers (VendorMaster stays unrestricted for its other
            // consumers: Payment, VendorBill, Vendor-Driven PR).
            "ServiceKycVendorMaster": "sp_nt_GetApprovedServiceKycVendorsForPicker",
            "PaymentModeMaster": "sp_nt_GetPaymentModeRecords",
            "ServiceTypeMaster": "sp_nt_GetServiceTypeRecords",
            "ServiceMaster": "sp_nt_GetServiceRecords",
            "RecurrenceCadenceMaster": "sp_nt_GetRecurrenceCadenceRecords"
        };

        this.createProcedureMap = {
            'CompanyMaster': 'sp_nt_CreateCompanyRecords',
            'DivisionMaster': 'sp_nt_CreateDivRecords',
            'BranchMaster': 'sp_nt_CreateBranchRecords',
            'UomMaster': 'sp_nt_CreateUomRecords',
            'UomClassMaster': 'sp_nt_CreateUomClassRecords',
            'GSTStateCodeMaster': 'sp_nt_CreateGstStateRecords',
            'AcYearMaster': 'sp_nt_CreateAcYearRecords',
            'PriorityMaster': 'sp_nt_CreatePriorityRecords',
            'DeptMaster': 'sp_nt_CreateDeptRecords',
             'HierarchyMaster': 'sp_GetHierarchicalData',
            'ScreenMaster': 'sp_nt_CreateScreenRecords',
            'ScreenPermission': 'sp_nt_CreatePermissionRecords',
            'ProductMaster': 'sp_nt_CreateProductRecord',
            'ProductCategoryMaster': 'sp_nt_CreateCategoryRecords',
            'ProductSubCategoryMaster': 'sp_nt_CreateSubCategoryRecords',
            "WorkflowMaster": "sp_nt_CreateWorkflowMaster",
            "TransportMaster": "sp_nt_CreateTransportRecords",
            "BankAccountTypeMaster": "sp_nt_CreateBankAccountTypeRecords",
            "PaymentTermsMaster": "sp_nt_CreatePaymentTermsRecords",
            "WarehouseLocationMaster": "sp_nt_CreateWarehouseLocationRecords",
            "DesignationMaster": "sp_nt_CreateDesignationRecords",
            "SupplierCatagoryMaster": "sp_nt_CreateSupplierCategoryRecords",
            "PaymentModeMaster": "sp_nt_CreatePaymentModeRecords",
            "ServiceTypeMaster": "sp_nt_CreateServiceTypeRecords",
            "ServiceMaster": "sp_nt_CreateServiceRecords",
            "RecurrenceCadenceMaster": "sp_nt_CreateRecurrenceCadenceRecords"
        };

        // lowercase keys: updateCommonMaster/deleteCommonMaster look up with
        // masterField.toLowerCase() — see backend-stpl/sql/100_masters_full_crud.sql
        // for the procedures themselves (one new pair per master; Transport's
        // pair already existed and is unchanged).
        this.updateProcedureMap = {
            'companymaster': 'sp_nt_UpdateCompanyRecords',
            'divisionmaster': 'sp_nt_UpdateDivRecords',
            'branchmaster': 'sp_nt_UpdateBranchRecords',
            'deptmaster': 'sp_nt_UpdateDeptRecords',
            'uommaster': 'sp_nt_UpdateUomRecords',
            'uomclassmaster': 'sp_nt_UpdateUomClassRecords',
            'gststatecodemaster': 'sp_nt_UpdateGstStateRecords',
            'prioritymaster': 'sp_nt_UpdatePriorityRecords',
            'screenmaster': 'sp_nt_UpdateScreenRecords',
            'screenpermission': 'sp_nt_UpdatePermissionRecords',
            'workflowmaster': 'sp_nt_UpdateWorkflowMaster',
            'productcategorymaster': 'sp_nt_UpdateCategoryRecords',
            'productsubcategorymaster': 'sp_nt_UpdateSubCategoryRecords',
            'productmaster': 'sp_nt_UpdateProductRecord',
            'transportmaster': 'sp_nt_UpdateTransportRecords',
            'bankaccounttypemaster': 'sp_nt_UpdateBankAccountTypeRecords',
            'paymenttermsmaster': 'sp_nt_UpdatePaymentTermsRecords',
            'warehouselocationmaster': 'sp_nt_UpdateWarehouseLocationRecords',
            'designationmaster': 'sp_nt_UpdateDesignationRecords',
            'suppliercatagorymaster': 'sp_nt_UpdateSupplierCategoryRecords',
            'paymentmodemaster': 'sp_nt_UpdatePaymentModeRecords',
            'servicetypemaster': 'sp_nt_UpdateServiceTypeRecords',
            'servicemaster': 'sp_nt_UpdateServiceRecords',
            'recurrencecadencemaster': 'sp_nt_UpdateRecurrenceCadenceRecords',
        };

        this.deleteProcedureMap = {
            'companymaster': 'sp_nt_DeleteCompanyRecords',
            'divisionmaster': 'sp_nt_DeleteDivRecords',
            'branchmaster': 'sp_nt_DeleteBranchRecords',
            'deptmaster': 'sp_nt_DeleteDeptRecords',
            'uommaster': 'sp_nt_DeleteUomRecords',
            'uomclassmaster': 'sp_nt_DeleteUomClassRecords',
            'gststatecodemaster': 'sp_nt_DeleteGstStateRecords',
            'prioritymaster': 'sp_nt_DeletePriorityRecords',
            'screenmaster': 'sp_nt_DeleteScreenRecords',
            'screenpermission': 'sp_nt_DeletePermissionRecords',
            'workflowmaster': 'sp_nt_DeleteWorkflowMaster',
            'productcategorymaster': 'sp_nt_DeleteCategoryRecords',
            'productsubcategorymaster': 'sp_nt_DeleteSubCategoryRecords',
            'productmaster': 'sp_nt_DeleteProductRecord',
            'transportmaster': 'sp_nt_DeleteTransportRecords',
            'bankaccounttypemaster': 'sp_nt_DeleteBankAccountTypeRecords',
            'paymenttermsmaster': 'sp_nt_DeletePaymentTermsRecords',
            'warehouselocationmaster': 'sp_nt_DeleteWarehouseLocationRecords',
            'designationmaster': 'sp_nt_DeleteDesignationRecords',
            'suppliercatagorymaster': 'sp_nt_DeleteSupplierCategoryRecords',
            'paymentmodemaster': 'sp_nt_DeletePaymentModeRecords',
            'servicetypemaster': 'sp_nt_DeleteServiceTypeRecords',
            'servicemaster': 'sp_nt_DeleteServiceRecords',
            'recurrencecadencemaster': 'sp_nt_DeleteRecurrenceCadenceRecords',
        };
        this.fieldMappings = {
        'CompanyMaster': { label: 'com_name', value: 'com_sno' },
        'DivisionMaster': { label: 'div_name', value: 'div_sno', extra: ['com_sno'] },
        'BranchMaster': { label: 'brn_name', value: 'brn_sno', extra: ['div_sno', 'com_sno'] },
        // extra: needed so the Product form can tell, per selected UOM, whether
        // it's a non-base unit with no fixed conversion (e.g. Box, Tin) — that's
        // when prod_uom_con_factor must be captured on the product itself.
        // uom_class (MASS/VOLUME/LENGTH/AREA/QUANTITY) lets it further offer only
        // same-class units when picking what that factor is denominated in.
        'UomMaster': { label: 'uom_name', value: 'uom_sno', extra: ['uom_base_uom_flag', 'uom_con_factor', 'uom_class'] },
        // value = uom_class_code (not the sno) — uom_master.uom_class stores the code string.
        'UomClassMaster': { label: 'uom_class_name', value: 'uom_class_code', extra: ['uom_class_sno'] },
        'GSTStateCodeMaster': { label: 'gst_code', value: 'gst_sno' },
        'AcYearMaster': { label: 'ac_year', value: 'ac_sno' },
        'PriorityMaster': { label: 'priority_name', value: 'priority_sno' },
        'DeptMaster': { label: 'dept_name', value: 'dept_sno', extra: ['brn_sno', 'div_sno', 'com_sno'] },
        'ScreenMaster': { label: 'screen_name', value: 'screen_id' },
        'ProductMaster': { label: 'prod_name', value: 'prod_sno', extra: ['prod_code', 'uom_sno', 'uom_name', 'prod_uom_con_uom_sno'] },
        'CategoryMaster': { label: 'cat_name', value: 'cat_sno' },
        'SubCategoryMaster': { label: 'subcat_name', value: 'subcat_sno' },
        // Lets the Product form (and anywhere else ProductSubCategoryMaster
        // options are consumed) see each subcategory's Regular/Non-Regular
        // flag without a second lookup — was previously undefined here and
        // fell through to the generic name/id heuristic below.
        'ProductSubCategoryMaster': { label: 'subcat_name', value: 'subcat_sno', extra: ['subcat_stock_type'] },
        'SupplierCatagoryMaster': { label: 'supp_cat_name', value: 'supp_cat_code' },
        'PaymentModeMaster': { label: 'payment_mode_name', value: 'payment_mode_code' },
        'TransportMaster': { label: 'transport_name', value: 'transport_sno' },
        // value = account_type_name (not the sno) — KYC's ac_type column stores free text,
        // no ac_type_sno FK exists, so the option value must be the text itself.
        'BankAccountTypeMaster': { label: 'account_type_name', value: 'bank_account_type_sno', extra: ['bank_account_type_sno', 'account_type_code'] },
        // value = payment_terms_name (not the sno) — supplier_quotation_info.payment_terms stores the text.
        'PaymentTermsMaster': { label: 'payment_terms_name', value: 'payment_terms_name', extra: ['payment_terms_sno', 'payment_terms_code'] },
        'WarehouseLocationMaster': { label: 'location_name', value: 'location_sno', extra: ['location_code', 'com_snos', 'div_snos', 'brn_snos'] },
        'DesignationMaster': { label: 'designation_name', value: 'designation_sno', extra: ['designation_code'] },
        'VendorMaster': { label: 'company_name', value: 'kyc_basic_info_sno', extra: ['supp_code', 'email', 'mobile_number'] },
        'ServiceKycVendorMaster': { label: 'company_name', value: 'kyc_basic_info_sno', extra: ['supp_code', 'email', 'mobile_number'] },
        'ServiceTypeMaster': { label: 'service_type_name', value: 'service_type_sno', extra: ['service_type_code'] },
        'ServiceMaster': { label: 'service_name', value: 'service_sno', extra: ['service_type_sno', 'service_type_code', 'default_uom_sno'] },
        'RecurrenceCadenceMaster': { label: 'cadence_name', value: 'recurrence_cadence_sno', extra: ['cadence_code', 'interval_unit', 'interval_value'] },
    };

    }

    // Only these masterFields carry a company/division/branch identity on
    // their own rows — every other masterField (UomMaster, CategoryMaster,
    // ProductMaster, WorkflowMaster, ...) is global reference data with no
    // org concept, so it keeps calling its SP with zero parameters exactly
    // as before. See backend-stpl/sql/79_masters_hierarchy_scope.sql.
    static ORG_SCOPED_MASTER_FIELDS = new Set([
        'CompanyMaster', 'DivisionMaster', 'BranchMaster', 'DeptMaster', 'WarehouseLocationMaster',
    ]);

    async getAllCommonMasters(masterField, hierarchyJson) {
        try {
            const field = masterField.trim();
            const storedProcedure = this.storedProcedureMap[field];

            if (!storedProcedure) {
                throw new Error(`Invalid master field: ${masterField}`);
            }

            const parameters = CommonMasterRepo.ORG_SCOPED_MASTER_FIELDS.has(field)
                ? { hierarchy: hierarchyJson ?? [] }
                : undefined;
            const result = await this.executeStoredProcedure(storedProcedure, parameters);
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
            console.log(result)
            return result;
        } catch (error) {
            console.error(`Error creating ${masterField}:`, error);
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

    async executeStoredProcedure(procedureName, parameters) {
        try {
            const request = mssqlPool.request();
            if (parameters !== undefined) {
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
async getRequiredMasterForOptions(masterFields, hierarchyJson) {
    try {
        if (!Array.isArray(masterFields) || masterFields.length === 0) {
            throw new Error('masterFields must be a non-empty array');
        }

        const results = {};

        // Fetch all masters in parallel
        const promises = masterFields.map(async (masterField) => {
            try {
                const field = masterField.trim();
                const storedProcedure = this.storedProcedureMap[field];

                if (!storedProcedure) {
                    console.warn(`Invalid master field: ${masterField}`);
                    return { masterField, data: [] };
                }

                // Same org-scoping as the generic GET /:masterField dispatch
                // (getAllCommonMasters) — a Company/Division/Branch/Dept/
                // WarehouseLocation dropdown must not offer options outside
                // the caller's own allowed hierarchy.
                const parameters = CommonMasterRepo.ORG_SCOPED_MASTER_FIELDS.has(field)
                    ? { hierarchy: hierarchyJson ?? [] }
                    : undefined;
                const data = await this.executeStoredProcedure(storedProcedure, parameters);
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
                // node-mssql merges same-named columns from joined tables
                // (e.g. product_master.uom_sno + uom_master.uom_sno) into an array.
                const v = Array.isArray(item[field]) ? item[field][0] : item[field];
                option[field] = v ?? null;
            });
        }
        return option;
    });
}

}

export default CommonMasterRepo;
