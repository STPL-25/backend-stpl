import express from "express";
import CommonMasterControllers from "../Controllers/CommonMasterControllers.js";
// import basicAuth from "../../AuthMiddleware/BasicAuth.js";

const commonMasterRouter = express.Router();

// IMPORTANT: Place specific routes BEFORE parameterized routes
commonMasterRouter.post("/hierarchy-data",  CommonMasterControllers.getAllMasterDataByHierarchy);
commonMasterRouter.post("/getRequiredMasterForOptions", CommonMasterControllers.getRequiredMasterForOptions);


// Parameterized routes (place after specific routes)
commonMasterRouter.get("/:masterField",  CommonMasterControllers.getAllMasterData);
commonMasterRouter.get("/:masterField/:id", CommonMasterControllers.getMasterDataById);
commonMasterRouter.post("/:masterField",  CommonMasterControllers.createMasterData);
commonMasterRouter.put("/:masterField/:id", CommonMasterControllers.updateMasterData);
commonMasterRouter.delete("/:masterField/:id", CommonMasterControllers.deleteMasterData);

export default commonMasterRouter;
