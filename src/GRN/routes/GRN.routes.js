import express from "express";
import GRNController from "../controllers/GRN.controller.js";
import { cacheMiddleware } from "../../Middleware/redisCache.js";

const GRNRouter = express.Router();

// DB operations
GRNRouter.get("/getPendingPOs",          cacheMiddleware("grn:pending_pos", 120), GRNController.getPendingPOs);
GRNRouter.get("/getGRNsByPO/:po_basic_sno", cacheMiddleware((req) => `grn:by_po:${req.params.po_basic_sno}`, 120), GRNController.getGRNsByPO);
GRNRouter.post("/createGRN",             GRNController.createGRN);
GRNRouter.get("/getAllGRNs",             cacheMiddleware("grn:all", 120), GRNController.getAllGRNs);

// Draft operations (Redis-backed, per-user)
GRNRouter.post("/saveGRNDraft",              GRNController.saveGRNDraft);
GRNRouter.get("/getGRNDrafts",               GRNController.getGRNDrafts);
GRNRouter.get("/getGRNDraft/:draftId",       GRNController.getGRNDraft);
GRNRouter.put("/updateGRNDraft/:draftId",    GRNController.updateGRNDraft);
GRNRouter.delete("/deleteGRNDraft/:draftId", GRNController.deleteGRNDraft);
GRNRouter.post("/submitGRNDraft/:draftId",   GRNController.submitGRNDraft);

export default GRNRouter;
