import express from "express";
import ProductStockLevelController from "../controllers/ProductStockLevel.controller.js";

const ProductStockLevelRouter = express.Router();

// Same staff-only reasoning as TermsConditions.routes.js: this lives inside
// the generic Masters screen (no dedicated dbo.screens row), so a non-staff
// session (bare {login_id, ...}, no real ecno) is blocked here explicitly.
function requireStaffOnly(req, res, next) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  if (!user?.ecno) {
    return res.status(403).json({ success: false, error: "Not available for non-staff logins." });
  }
  next();
}
ProductStockLevelRouter.use(requireStaffOnly);

ProductStockLevelRouter.get("/getProductStockLevels",     ProductStockLevelController.getAll);
ProductStockLevelRouter.get("/getApplicableStockLevel",   ProductStockLevelController.getApplicable);
ProductStockLevelRouter.post("/createProductStockLevel",  ProductStockLevelController.create);
ProductStockLevelRouter.put("/updateProductStockLevel",   ProductStockLevelController.update);
ProductStockLevelRouter.delete("/deleteProductStockLevel", ProductStockLevelController.delete);

export default ProductStockLevelRouter;
