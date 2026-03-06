import express from "express";
import PRController from "../controllers/PR.controller.js";

const PRrouter = express.Router();

// Existing routes
PRrouter.post("/createPrRecords", PRController.createPrRecords);
PRrouter.get("/getPrRecords", PRController.getPrRecords);

// Draft routes (Redis-backed)
PRrouter.post("/saveDraft", PRController.saveDraft);
PRrouter.get("/getDrafts", PRController.getDrafts);
PRrouter.get("/getDraft/:draftId", PRController.getDraft);
PRrouter.put("/updateDraft/:draftId", PRController.updateDraft);
PRrouter.delete("/deleteDraft/:draftId", PRController.deleteDraft);
PRrouter.post("/submitDraft/:draftId", PRController.submitDraft);

export default PRrouter;
