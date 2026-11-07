import express from "express";
import OrgDashboardController from "../controllers/OrgDashboard.controller.js";
import { attachHierarchyScope } from "../../Middleware/hierarchyScope.js";

const OrgDashboardRouter = express.Router();

// Mounted behind verifyJWT in index.js. The real-time side needs no route of its own: the dashboard refetches whenever the
// existing "admin:permissions:updated" / "permissions:updated" / "master:updated" socket events fire.
OrgDashboardRouter.get("/overview", OrgDashboardController.getOverview);
// Business numbers for the "Business overview" tab - scoped to the caller's own org access (see the controller).
OrgDashboardRouter.get("/business", attachHierarchyScope, OrgDashboardController.getBusinessOverview);

export default OrgDashboardRouter;
