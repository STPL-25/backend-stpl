import express from "express";
import TermsConditionsController from "../controllers/TermsConditions.controller.js";

const TermsConditionsRouter = express.Router();

// Terms & Conditions Master lives inside the generic Masters screen (no
// dedicated dbo.screens row to gate it — see sql/38_terms_conditions_screen_removed.sql),
// so unlike most modules here it needs its own staff-only check: a non-staff
// session's req.user is a bare {login_id, ...} object with no real ecno
// (see NonStaffUser.controller.js's login()), while a staff session's is an
// array of SQL rows with ecno present.
function requireStaffOnly(req, res, next) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  if (!user?.ecno) {
    return res.status(403).json({ success: false, error: "Not available for non-staff logins." });
  }
  next();
}
TermsConditionsRouter.use(requireStaffOnly);

TermsConditionsRouter.get("/getTermsConditions",           TermsConditionsController.getAll);
TermsConditionsRouter.get("/getDefaultTermsConditions",    TermsConditionsController.getDefault);
TermsConditionsRouter.post("/createTermsConditions",       TermsConditionsController.create);
TermsConditionsRouter.put("/updateTermsConditions",        TermsConditionsController.update);
TermsConditionsRouter.delete("/deleteTermsConditions",     TermsConditionsController.delete);

export default TermsConditionsRouter;
