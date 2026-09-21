import express from "express";
import CommonMasterControllers from "../Controllers/CommonMasterControllers.js";
import { attachHierarchyScope } from "../../Middleware/hierarchyScope.js";
// import basicAuth from "../../AuthMiddleware/BasicAuth.js";

const commonMasterRouter = express.Router();

// IMPORTANT: Place specific routes BEFORE parameterized routes
commonMasterRouter.post("/hierarchy-data",  CommonMasterControllers.getAllMasterDataByHierarchy);
commonMasterRouter.post("/getRequiredMasterForOptions", attachHierarchyScope, CommonMasterControllers.getRequiredMasterForOptions);


// Parameterized routes (place after specific routes)
// attachHierarchyScope runs for every masterField (cheap, 60s-cached) but is
// only actually applied by the repository for the 5 org-scoped ones
// (CompanyMaster/DivisionMaster/BranchMaster/DeptMaster/WarehouseLocationMaster).
commonMasterRouter.get("/:masterField", attachHierarchyScope, CommonMasterControllers.getAllMasterData);
commonMasterRouter.get("/:masterField/:id", CommonMasterControllers.getMasterDataById);
commonMasterRouter.post("/:masterField",  CommonMasterControllers.createMasterData);
commonMasterRouter.put("/:masterField/:id", CommonMasterControllers.updateMasterData);
commonMasterRouter.delete("/:masterField/:id", CommonMasterControllers.deleteMasterData);

export default commonMasterRouter;
