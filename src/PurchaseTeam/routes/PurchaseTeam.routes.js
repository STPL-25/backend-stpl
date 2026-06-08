import express from "express";
import PurchaseTeamController from "../controllers/PurchaseTeam.controller.js";
import { cacheMiddleware } from "../../Middleware/redisCache.js";
import { upload } from "../../Utils/ImagesUpload/ImgUpload.js";

const PurchaseTeamRouter = express.Router();

// Approved PRs for purchase team
// PurchaseTeamRouter.get("/getApprovedPRs", cacheMiddleware("pt:approved_prs", 120), PurchaseTeamController.getApprovedPRs);
PurchaseTeamRouter.get("/getApprovedPRs",  PurchaseTeamController.getApprovedPRs);


// Approved vendors
PurchaseTeamRouter.get("/getApprovedVendors", cacheMiddleware("pt:approved_vendors", 300), PurchaseTeamController.getApprovedVendors);

// Supplier quotation
PurchaseTeamRouter.post("/createSupplierQuotation", upload.any(), PurchaseTeamController.createSupplierQuotation);
PurchaseTeamRouter.get("/getSupplierQuotations/:prBasicSno/:pr_no", PurchaseTeamController.getSupplierQuotations);
PurchaseTeamRouter.post("/selectQuotation", PurchaseTeamController.selectQuotation);

// Create PO from selected quotation
PurchaseTeamRouter.post("/createPOFromQuotation", PurchaseTeamController.createPOFromQuotation);

// Update item quantity
PurchaseTeamRouter.post("/updateItemQuantity", PurchaseTeamController.updateItemQuantity);

// PO Confirmation (Step 1 — billing org, required date, item qty split)
PurchaseTeamRouter.post("/savePOConfirmation", PurchaseTeamController.savePOConfirmation);
PurchaseTeamRouter.get("/getPOConfirmation/:prBasicSno", cacheMiddleware((req) => `pt:po_confirm:${req.params.prBasicSno}`, 120), PurchaseTeamController.getPOConfirmation);

// Split groups
PurchaseTeamRouter.post("/saveSplitGroup", PurchaseTeamController.saveSplitGroup);
// Not cached: split groups must reflect a fresh save immediately (no stale cache).
PurchaseTeamRouter.get("/getSplitGroups/:prBasicSno", PurchaseTeamController.getSplitGroups);
PurchaseTeamRouter.put("/updateSplitGroupOrg", PurchaseTeamController.updateSplitGroupOrg);

// Quotation drafts (Redis)
PurchaseTeamRouter.post("/saveQuotationDraft", PurchaseTeamController.saveQuotationDraft);
PurchaseTeamRouter.get("/getQuotationDrafts", PurchaseTeamController.getQuotationDrafts);
PurchaseTeamRouter.delete("/deleteQuotationDraft/:draftId", PurchaseTeamController.deleteQuotationDraft);

export default PurchaseTeamRouter;
