import express from "express";
import CommonMasterControllers from "../Controllers/CommonMasterControllers.js";
import { attachHierarchyScope } from "../../Middleware/hierarchyScope.js";
// import basicAuth from "../../AuthMiddleware/BasicAuth.js";

import CommonMasterServices from "../Services/CommonMasterServices.js";

const commonMasterRouter = express.Router();

// A company's bank accounts (PaymentBankMaster, sql/138) are readable AND writable only inside the caller's allowed companies.
// The other masters scope reads only; for bank accounts a write by id, or into another company, is refused here.
const scopePaymentBankWrites = async (req, res, next) => {
  if (req.params.masterField !== "PaymentBankMaster") return next();
  try {
    const allowed = new Set((req.hierarchyJson ?? []).map((h) => Number(h.com_sno)));
    const rows = Array.isArray(req.body) ? req.body : req.body ? [req.body] : [];
    if (rows.some((r) => r?.com_sno != null && r.com_sno !== "" && !allowed.has(Number(r.com_sno)))) {
      return res.status(403).json({ success: false, error: "You do not have access to that company." });
    }
    if (req.params.id) {
      const visible = await CommonMasterServices.getAllCommonMasters("PaymentBankMaster", req.hierarchyJson);
      if (!visible.some((v) => String(v.payment_bank_sno) === String(req.params.id))) {
        return res.status(403).json({ success: false, error: "You do not have access to that bank account." });
      }
    }
    next();
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
};

// IMPORTANT: Place specific routes BEFORE parameterized routes
commonMasterRouter.post("/hierarchy-data",  CommonMasterControllers.getAllMasterDataByHierarchy);
commonMasterRouter.post("/getRequiredMasterForOptions", attachHierarchyScope, CommonMasterControllers.getRequiredMasterForOptions);


// Parameterized routes (place after specific routes)
// attachHierarchyScope runs for every masterField (cheap, 60s-cached) but is
// only actually applied by the repository for the 5 org-scoped ones
// (CompanyMaster/DivisionMaster/BranchMaster/DeptMaster/WarehouseLocationMaster).
commonMasterRouter.get("/:masterField", attachHierarchyScope, CommonMasterControllers.getAllMasterData);
commonMasterRouter.get("/:masterField/:id", CommonMasterControllers.getMasterDataById);
commonMasterRouter.post("/:masterField", attachHierarchyScope, scopePaymentBankWrites, CommonMasterControllers.createMasterData);
commonMasterRouter.put("/:masterField/:id", attachHierarchyScope, scopePaymentBankWrites, CommonMasterControllers.updateMasterData);
commonMasterRouter.delete("/:masterField/:id", attachHierarchyScope, scopePaymentBankWrites, CommonMasterControllers.deleteMasterData);

export default commonMasterRouter;
