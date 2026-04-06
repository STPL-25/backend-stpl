import express from "express";
import PRController from "../controllers/PR.controller.js";

const PRrouter = express.Router();

// Existing routes
PRrouter.post("/createPrRecords", PRController.createPrRecords);
PRrouter.get("/getPrRecords", PRController.getPrRecords);
PRrouter.post("/approvePr", PRController.approvePr);

// Draft routes (Redis-backed, per-user)
PRrouter.post("/saveDraft", PRController.saveDraft);
PRrouter.get("/getDrafts", PRController.getDrafts);
PRrouter.get("/getDraft/:draftId", PRController.getDraft);
PRrouter.put("/updateDraft/:draftId", PRController.updateDraft);
PRrouter.delete("/deleteDraft/:draftId", PRController.deleteDraft);
PRrouter.post("/submitDraft/:draftId", PRController.submitDraft);

// Dept-scoped shared draft routes (Redis-backed, dept-level visibility)
PRrouter.post("/saveDeptDraft", PRController.saveDeptDraft);
PRrouter.get("/getDeptDrafts", PRController.getDeptDrafts);
PRrouter.put("/updateDeptDraft/:draftId", PRController.updateDeptDraft);
PRrouter.delete("/deleteDeptDraft/:draftId", PRController.deleteDeptDraft);
PRrouter.post("/submitDeptDraft/:draftId", PRController.submitDeptDraft);
PRrouter.post("/submitAllDeptDrafts", PRController.submitAllDeptDrafts);

export default PRrouter;
