import express from "express";
import PurchaseTeamController from "../controllers/PurchaseTeam.controller.js";
import RfqController from "../controllers/Rfq.controller.js";
import { cacheMiddleware } from "../../Middleware/redisCache.js";
import { upload } from "../../Utils/ImagesUpload/ImgUpload.js";
import { attachHierarchyScope } from "../../Middleware/hierarchyScope.js";

const PurchaseTeamRouter = express.Router();

// Approved PRs for purchase team
// PurchaseTeamRouter.get("/getApprovedPRs", cacheMiddleware("pt:approved_prs", 120), PurchaseTeamController.getApprovedPRs);
PurchaseTeamRouter.get("/getApprovedPRs", attachHierarchyScope, PurchaseTeamController.getApprovedPRs);
PurchaseTeamRouter.get("/getVendorDrivenApprovedPRs", PurchaseTeamController.getVendorDrivenApprovedPRs);


// Approved vendors
PurchaseTeamRouter.get("/getApprovedVendors",  PurchaseTeamController.getApprovedVendors);

// Supplier quotation
PurchaseTeamRouter.post("/createSupplierQuotation", upload.any(), PurchaseTeamController.createSupplierQuotation);
PurchaseTeamRouter.post("/updateSupplierQuotation", upload.any(), PurchaseTeamController.updateSupplierQuotation);
PurchaseTeamRouter.get("/getSupplierQuotations/:prBasicSno/:pr_no", PurchaseTeamController.getSupplierQuotations);
PurchaseTeamRouter.get("/getQuotationSupplyInfo", PurchaseTeamController.getQuotationSupplyInfo);
PurchaseTeamRouter.post("/selectQuotation", PurchaseTeamController.selectQuotation);

// Request For Quotation (sql/154): pick several suppliers -> they are mailed -> they quote in the supplier portal
// (grn-service /api/supplier/rfqs) -> the buyer takes one version of each response as the final supplier quotation
PurchaseTeamRouter.post("/createRfq", RfqController.createRfq);
PurchaseTeamRouter.get("/getRfqs/:prBasicSno/:pr_no", RfqController.getRfqs);
PurchaseTeamRouter.get("/getRfqResponses/:rfqSupplierSno", RfqController.getResponseVersions);
PurchaseTeamRouter.get("/getRfqSupplierContacts", RfqController.getSupplierContacts);
PurchaseTeamRouter.post("/requestRfqRevision", RfqController.requestRevision);
PurchaseTeamRouter.post("/resendRfqEmail", RfqController.resendEmail);
PurchaseTeamRouter.post("/closeRfq", RfqController.closeRfq);
PurchaseTeamRouter.post("/takeRfqResponse", RfqController.takeResponse);

// Create PO from selected quotation
PurchaseTeamRouter.post("/createPOFromQuotation", PurchaseTeamController.createPOFromQuotation);
PurchaseTeamRouter.post("/createVendorDrivenPO", PurchaseTeamController.createVendorDrivenPO);

// Email the frontend-generated PO PDF to the supplier
PurchaseTeamRouter.post("/sendPOEmail", upload.any(), PurchaseTeamController.sendPOEmail);

// Supplier's primary bank account (PO PDF payment block)
PurchaseTeamRouter.get("/getVendorBankDetails/:vendorSno", PurchaseTeamController.getVendorBankDetails);

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
