import express from "express";
import POController from "../controllers/PO.controller.js";
import { cacheMiddleware } from "../../Middleware/redisCache.js";
import { attachHierarchyScope } from "../../Middleware/hierarchyScope.js";

const POrouter = express.Router();

POrouter.get("/getPoRecords", attachHierarchyScope, POController.getPoRecords);
POrouter.post("/approvePo", POController.approvePo);

export default POrouter;
