import express from "express";
import CommonMasterControllers from "../Controllers/CommonMasterControllers.js";
import { attachHierarchyScope } from "../../Middleware/hierarchyScope.js";
// import basicAuth from "../../AuthMiddleware/BasicAuth.js";

import CommonMasterServices from "../Services/CommonMasterServices.js";

const commonMasterRouter = express.Router();

// PaymentBankMaster rows are readable AND writable only inside the caller's allowed company/division/branch scope.
// The other masters scope reads only; for bank accounts a write by id, or into another org scope, is refused here.
const scopePaymentBankWrites = async (req, res, next) => {
  if (req.params.masterField !== "PaymentBankMaster") return next();
  try {
    const hierarchy = req.hierarchyJson ?? [];
    const isAllowed = (row) => hierarchy.some((h) =>
      Number(h.com_sno) === Number(row?.com_sno)
      && (h.div_sno == null || Number(h.div_sno) === Number(row?.div_sno))
      && (h.brn_sno == null || Number(h.brn_sno) === Number(row?.brn_sno)));
    const rows = Array.isArray(req.body) ? req.body : req.body ? [req.body] : [];
    let current = null;
    if (req.params.id) {
      const visible = await CommonMasterServices.getAllCommonMasters("PaymentBankMaster", req.hierarchyJson);
      current = visible.find((v) => String(v.payment_bank_sno) === String(req.params.id));
      if (!current) {
        return res.status(403).json({ success: false, error: "You do not have access to that bank account." });
      }
    }
    if (rows.some((r) => {
      const target = current ? { ...current, ...r } : r;
      return target?.com_sno != null && target.com_sno !== "" && !isAllowed(target);
    })) {
      return res.status(403).json({ success: false, error: "You do not have access to that company, division and branch." });
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
