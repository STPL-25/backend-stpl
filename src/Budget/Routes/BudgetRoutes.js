import express from "express";
// import basicAuth from "../../Common/Middlewares/basicAuth.js";
import BudgetController from "../Controllers/BudgetController.js";
const BudgetRouter = express.Router();

BudgetRouter.post("/post_bud_dept", BudgetController.postBudgetData);
BudgetRouter.post("/get_bud_dept", BudgetController.getBudgetData);

export default BudgetRouter;
