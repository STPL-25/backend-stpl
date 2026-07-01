import express from "express";
import POController from "../controllers/PO.controller.js";
import { cacheMiddleware } from "../../Middleware/redisCache.js";

const POrouter = express.Router();

POrouter.get("/getPoRecords",  POController.getPoRecords);
POrouter.post("/approvePo", POController.approvePo);

export default POrouter;
