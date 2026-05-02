import express from "express";
import StorePOController from "../controllers/StorePO.controller.js";
import { cacheMiddleware } from "../../Middleware/redisCache.js";

const StorePOrouter = express.Router();

// DB-persisted POs
StorePOrouter.post("/createStorePO", StorePOController.createStorePO);
StorePOrouter.get("/getStorePOs", cacheMiddleware("storepo:list", 120), StorePOController.getStorePOs);

// Draft operations (Redis-backed, per-user)
StorePOrouter.post("/savePODraft", StorePOController.savePODraft);
StorePOrouter.get("/getPODrafts", StorePOController.getPODrafts);
StorePOrouter.get("/getPODraft/:draftId", StorePOController.getPODraft);
StorePOrouter.put("/updatePODraft/:draftId", StorePOController.updatePODraft);
StorePOrouter.delete("/deletePODraft/:draftId", StorePOController.deletePODraft);
StorePOrouter.post("/submitPODraft/:draftId", StorePOController.submitPODraft);

export default StorePOrouter;
