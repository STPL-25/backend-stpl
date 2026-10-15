import WorkFlowApprovalService from "../services/WorkFlowApproval.service.js";
import { invalidateCache, invalidateCacheByPattern } from "../../Middleware/redisCache.js";
import { runApproverChangeNoticeSweep } from "../../ServiceAgreement/jobs/AgreementPoJob.js";

class WorkFlowApprovalController {
  // POST /saveFullWorkflow — creates all 3 tables in one SP call
  static async saveFullWorkflow(req, res) {
    try {
      const result = await WorkFlowApprovalService.saveFullWorkflow(req.body);
      console.log(result)
      await invalidateCache(req.redisClient, "wf:workflows");
      await invalidateCacheByPattern(req.redisClient, "wf:by_entity:*");
      res.status(201).json({ success: true, message: "Workflow saved successfully", data: result });
    } catch (error) {
      console.log(error)
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // GET /getWorkflows
  static async getWorkflows(req, res) {
    try {
      const data = await WorkFlowApprovalService.getWorkflows();
      console.log(data)
      res.json({ success: true, data });
    } catch (error) {
      console.log(error)
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // GET /getEntityTypes — every registerable entity_type (including ones
  // with no workflow configured yet), so Approval Workflow Manager's
  // "Entity Type" field can offer a brand-new type, not just ones already
  // in use.
  static async getEntityTypes(req, res) {
    try {
      const data = await WorkFlowApprovalService.getEntityTypes();
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // GET /getConditionFields?entity_type=PurchaseRequisition — which values a stage condition can test
  // for that kind of workflow (label, number|list, option source, unit). Empty = no conditions yet.
  static async getConditionFields(req, res) {
    try {
      const entityType = String(req.query.entity_type ?? "").trim();
      if (!entityType) return res.status(400).json({ success: false, error: "entity_type is required" });
      const data = await WorkFlowApprovalService.getConditionFields(entityType);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // GET /getApprovalRoutes — the routing matrix (request variant -> approval type) with the
  // approval types each row may choose from.
  static async getApprovalRoutes(req, res) {
    try {
      const rows = await WorkFlowApprovalService.getApprovalRoutes();
      const data = rows.map((r) => {
        let eligible = [];
        try { eligible = r.eligible_entities ? JSON.parse(r.eligible_entities) : []; } catch { /* leave empty */ }
        return { ...r, eligible_entities: eligible };
      });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // POST /saveApprovalRoute {module_code, variant_code, entity_code, force?}
  static async saveApprovalRoute(req, res) {
    try {
      const { module_code, variant_code, entity_code, force } = req.body ?? {};
      if (!module_code || !variant_code || !entity_code) {
        return res.status(400).json({ success: false, error: "module_code, variant_code and entity_code are required" });
      }
      const rows = await WorkFlowApprovalService.saveApprovalRoute({
        module_code, variant_code, entity_code, force: force === true, modified_by: req.user_ecno ?? null,
      });
      res.json({ success: true, data: rows?.[0] ?? null });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // POST /saveApprovalModule {module_label, variant_label?, variants?: [{variant_label}]} — a new kind of request
  static async saveApprovalModule(req, res) {
    try {
      const { module_label, variant_label, variants } = req.body ?? {};
      if (!String(module_label ?? "").trim()) return res.status(400).json({ success: false, error: "module_label is required" });
      const rows = await WorkFlowApprovalService.saveApprovalModule({
        module_label, variant_label, variants: Array.isArray(variants) ? variants : [], created_by: req.user_ecno ?? null,
      });
      res.status(201).json({ success: true, data: rows?.[0] ?? null });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // POST /saveApprovalVariant {module_code, variant_label} — another variant of an existing request kind
  static async saveApprovalVariant(req, res) {
    try {
      const { module_code, variant_label } = req.body ?? {};
      if (!module_code || !String(variant_label ?? "").trim()) {
        return res.status(400).json({ success: false, error: "module_code and variant_label are required" });
      }
      const rows = await WorkFlowApprovalService.saveApprovalVariant({ module_code, variant_label, created_by: req.user_ecno ?? null });
      res.status(201).json({ success: true, data: rows?.[0] ?? null });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // POST /createApprovalVariantEntity {module_code, variant_code} — a dedicated approval type for one variant
  static async createApprovalVariantEntity(req, res) {
    try {
      const { module_code, variant_code } = req.body ?? {};
      if (!module_code || !variant_code) {
        return res.status(400).json({ success: false, error: "module_code and variant_code are required" });
      }
      const rows = await WorkFlowApprovalService.createApprovalVariantEntity({
        module_code, variant_code, created_by: req.user_ecno ?? null,
      });
      res.status(201).json({ success: true, data: rows?.[0] ?? null });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // GET /getWorkflowByEntity/:entityType
  static async getWorkflowByEntity(req, res) {
    try {
      const data = await WorkFlowApprovalService.getWorkflowByEntity(req.params.entityType);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // PUT /updateWorkflow
  static async updateWorkflow(req, res) {
    try {
      const result = await WorkFlowApprovalService.updateWorkflow(req.body);
      await invalidateCache(req.redisClient, "wf:workflows");
      await invalidateCacheByPattern(req.redisClient, "wf:by_entity:*");
      res.json({ success: true, message: "Workflow updated", data: result });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // DELETE /deleteWorkflow — soft delete, cascades to its types and stages
  static async deleteWorkflow(req, res) {
    try {
      const result = await WorkFlowApprovalService.deleteWorkflow(req.body);
      await invalidateCache(req.redisClient, "wf:workflows");
      await invalidateCacheByPattern(req.redisClient, "wf:by_entity:*");
      await invalidateCacheByPattern(req.redisClient, "wf:types:*");
      res.json({ success: true, message: "Workflow deleted", data: result });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // GET /getWorkflowTypes/:workflowId
  static async getWorkflowTypes(req, res) {
    try {
      let raw = req.params.workflowId;
      try {
        const parsed = JSON.parse(raw);
        if (parsed && parsed.workflow_id !== undefined) raw = parsed.workflow_id;
      } catch { /* not JSON, use as-is */ }

      const workflowId = parseInt(raw, 10);
      if (isNaN(workflowId)) return res.status(400).json({ success: false, error: "Invalid workflow_id" });

      const data = await WorkFlowApprovalService.getWorkflowTypes(workflowId);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // POST /saveWorkflowType
  static async saveWorkflowType(req, res) {
    try {
      const result = await WorkFlowApprovalService.saveWorkflowType(req.body);
      await invalidateCache(req.redisClient, "wf:workflows", `wf:types:${req.body.workflow_id}`);
      res.status(201).json({ success: true, message: "Workflow type saved", data: result });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // PUT /updateWorkflowType
  static async updateWorkflowType(req, res) {
    try {
      const result = await WorkFlowApprovalService.updateWorkflowType(req.body);
      await invalidateCache(req.redisClient, "wf:workflows", `wf:types:${req.body.workflow_id}`);
      res.json({ success: true, message: "Workflow type updated", data: result });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // DELETE /deleteWorkflowType — soft delete of a type and its stages
  static async deleteWorkflowType(req, res) {
    try {
      const result = await WorkFlowApprovalService.deleteWorkflowType(req.body);
      await invalidateCache(req.redisClient, "wf:workflows", `wf:types:${req.body.workflow_id}`);
      await invalidateCache(req.redisClient, `wf:stages:${req.body.workflow_types_id}`);
      res.json({ success: true, message: "Workflow type deleted", data: result });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // GET /getWorkflowStages/:workflowTypesId
  static async getWorkflowStages(req, res) {
    try {
      const data = await WorkFlowApprovalService.getWorkflowStages(req.params.workflowTypesId);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // POST /saveWorkflowStage
  static async saveWorkflowStage(req, res) {
    try {
      const result = await WorkFlowApprovalService.saveWorkflowStage(req.body);
      await invalidateCache(req.redisClient, `wf:stages:${req.body.workflow_types_id}`);
      res.status(201).json({ success: true, message: "Workflow stage saved", data: result });
      // real time: tell the replaced / replacing approvers now instead of waiting for the next sweep
      runApproverChangeNoticeSweep(req.io).catch((err) => console.error("Approver-change sweep failed:", err.message));
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // PUT /updateWorkflowStage
  static async updateWorkflowStage(req, res) {
    try {
      const result = await WorkFlowApprovalService.updateWorkflowStage(req.body);
      await invalidateCache(req.redisClient, `wf:stages:${req.body.workflow_types_id}`);
      res.json({ success: true, message: "Workflow stage updated", data: result });
      // real time: tell the replaced / replacing approvers now instead of waiting for the next sweep
      runApproverChangeNoticeSweep(req.io).catch((err) => console.error("Approver-change sweep failed:", err.message));
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // DELETE /deleteWorkflowStage — soft delete by stage_id or for a whole type
  static async deleteWorkflowStage(req, res) {
    try {
      const result = await WorkFlowApprovalService.deleteWorkflowStage(req.body);
      await invalidateCache(req.redisClient, `wf:stages:${req.body.workflow_types_id}`);
      res.json({ success: true, message: "Workflow stage deleted", data: result });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }
}

export default WorkFlowApprovalController;
