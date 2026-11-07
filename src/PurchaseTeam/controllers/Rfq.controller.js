import RfqService from "../services/Rfq.service.js";
import { invalidateCache } from "../../Middleware/redisCache.js";

function ecnoOf(req) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  return req.user_ecno ?? user?.ecno;
}

function fail(res, error) {
  console.log(error);
  res.status(error.status ?? 500).json({ success: false, error: error.message });
}

class RfqController {
  // Pick suppliers on the Purchase screen -> RFQ saved + mailed
  static async createRfq(req, res) {
    try {
      const ecno = ecnoOf(req);
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const data = await RfqService.createRfq(req.body ?? {}, ecno);
      res.json({ success: true, data, message: "Request for quotation created" });
    } catch (error) {
      fail(res, error);
    }
  }

  static async getRfqs(req, res) {
    try {
      const { prBasicSno, pr_no } = req.params;
      if (!prBasicSno) return res.status(400).json({ success: false, error: "pr_basic_sno required" });
      const data = await RfqService.getRfqs(Number(prBasicSno), pr_no ? atob(pr_no) : null);
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error);
    }
  }

  static async getResponseVersions(req, res) {
    try {
      const rfqSupplierSno = Number(req.params.rfqSupplierSno);
      if (!rfqSupplierSno) return res.status(400).json({ success: false, error: "rfq_supplier_sno required" });
      const data = await RfqService.getResponseVersions(rfqSupplierSno);
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error);
    }
  }

  static async getSupplierContacts(req, res) {
    try {
      const data = await RfqService.getSupplierContacts();
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error);
    }
  }

  static async requestRevision(req, res) {
    try {
      const ecno = ecnoOf(req);
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const data = await RfqService.requestRevision(req.body ?? {}, ecno);
      res.json({ success: true, data, message: "Revision requested" });
    } catch (error) {
      fail(res, error);
    }
  }

  static async resendEmail(req, res) {
    try {
      const ecno = ecnoOf(req);
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const rfqSupplierSno = Number(req.body?.rfq_supplier_sno);
      if (!rfqSupplierSno) return res.status(400).json({ success: false, error: "rfq_supplier_sno required" });
      const data = await RfqService.resendEmail(rfqSupplierSno, ecno);
      res.json({ success: true, data });
    } catch (error) {
      fail(res, error);
    }
  }

  static async closeRfq(req, res) {
    try {
      const ecno = ecnoOf(req);
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      const data = await RfqService.closeRfq(req.body ?? {}, ecno);
      res.json({ success: true, data, message: "RFQ cancelled" });
    } catch (error) {
      fail(res, error);
    }
  }

  // "Take as final quotation": creates the normal supplier quotation from one submitted version
  static async takeResponse(req, res) {
    try {
      const ecno = ecnoOf(req);
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      if (!req.body?.rfq_response_sno) return res.status(400).json({ success: false, error: "rfq_response_sno required" });
      const data = await RfqService.takeResponse(req.body, ecno);
      const prSno = req.body.pr_basic_sno;
      if (prSno) await invalidateCache(req.redisClient, `pt:quotations:${prSno}`);
      await invalidateCache(req.redisClient, "pt:approved_prs");
      res.json({ success: true, data, message: "Quotation taken from the supplier's response" });
    } catch (error) {
      fail(res, error);
    }
  }
}

export default RfqController;
