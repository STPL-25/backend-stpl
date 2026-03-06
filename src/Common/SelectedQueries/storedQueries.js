// Fields/SelectQueries.js
export const storedProcedure = {
  //companies
  getAllCompanies: `dbo.GetActiveCompanies`,
  createCompany:`sp_CreateCompanyRecords`, 
  updateCompany:`sp_UpdateCompanyRecords`, 
  deleteCompany:`sp_DeleteCompanyRecords`, 
  //Divisions
  createDivRecords:`sp_CreateDivisionRecords`,
  getDivRecords: `sp_GetDivisionRecords`,
  //Branch
  createBranchRecords:`sp_CreateBrRecords`,
  getBranchRecords:`sp_GetBranchRecords`

};

export const sqlFunctions={
  GetEmployeeName: `dbo.GetEmployeeName`,
}


