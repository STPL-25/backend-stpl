import express from "express";
import GRNController from "../controllers/GRN.controller.js";

const GRNRouter = express.Router();

// DB operations
GRNRouter.get("/getPendingPOs",          GRNController.getPendingPOs);
GRNRouter.get("/getGRNsByPO/:po_basic_sno", GRNController.getGRNsByPO);
GRNRouter.post("/createGRN",             GRNController.createGRN);
GRNRouter.get("/getAllGRNs",             GRNController.getAllGRNs);

// Draft operations (Redis-backed, per-user)
GRNRouter.post("/saveGRNDraft",              GRNController.saveGRNDraft);
GRNRouter.get("/getGRNDrafts",               GRNController.getGRNDrafts);
GRNRouter.get("/getGRNDraft/:draftId",       GRNController.getGRNDraft);
GRNRouter.put("/updateGRNDraft/:draftId",    GRNController.updateGRNDraft);
GRNRouter.delete("/deleteGRNDraft/:draftId", GRNController.deleteGRNDraft);
GRNRouter.post("/submitGRNDraft/:draftId",   GRNController.submitGRNDraft);

export default GRNRouter;
