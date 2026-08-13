import axios from "axios";
import crypto from "crypto";
import bcrypt from "bcryptjs";
import xml2js from "xml2js";
import KYCRepo from "../repository/Kyc.repository.js";
import { sendSupplierInviteEmail } from "../../Utils/Notify/notifyClient.js";

const { stripPrefix } = xml2js.processors;
const GSTN_SERVICE_URL =
  process.env.GSTN_SERVICE_URL ||
  "http://10.0.21.2/Mywebservice/MyWebService.asmx";
const GSTN_SOAP_ACTION = "http://tempuri.org/Get_GSTN_Details";
const GSTN_SERVICE_TIMEOUT_MS =
  Number(process.env.GSTN_SERVICE_TIMEOUT_MS) || 15000;

const SUPPLIER_PORTAL_URL =
  process.env.SUPPLIER_PORTAL_URL || "http://localhost:5173/supplier";
const SALT_ROUNDS = 10;

function generateTempPassword() {
  // 10 URL-safe chars, e.g. "aZ3-kQ9pLm" — easy to read out/paste
  return crypto.randomBytes(8).toString("base64url").slice(0, 10);
}

function escapeXml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

class KYCServices {
  static kycRepository = new KYCRepo();

  static async createKYCRecord(data) {
    const { orgMappings, ...kycPayload } = data;

    if (Array.isArray(orgMappings) && orgMappings.length > 0) {
      const invalid = await this.kycRepository.validateOrgMappings(orgMappings);
      if (invalid.length > 0) {
        const error = new Error(
          `These company/division/branch/department selections don't form a real combination: ${invalid
            .map((m) => `com ${m.com_sno} / div ${m.div_sno} / branch ${m.brn_sno} / dept ${m.dept_sno}`)
            .join("; ")}`
        );
        error.statusCode = 400;
        throw error;
      }
    }

    const result = await this.kycRepository.createKYCRecord(kycPayload);
    const kycBasicInfoSno = result?.kyc_basic_info_sno;

    if (kycBasicInfoSno && Array.isArray(orgMappings) && orgMappings.length > 0) {
      await this.kycRepository.createKYCOrgMappings(kycBasicInfoSno, orgMappings, kycPayload.created_by);
    }

    return result;
  }

  static getKYCOrgMappings(kycBasicInfoSno) {
    return this.kycRepository.getKYCOrgMappings(kycBasicInfoSno);
  }

  static getAllKycRecord() {
    return this.kycRepository.getAllKYCRecords();
  }
  static getKycApproval(ecno) {
    return this.kycRepository.getKycApproval(ecno);
  }

  static getPendingApprovals(ecno) {
    return this.kycRepository.getPendingApprovals(ecno);
  }

  static async approveKyc(data) {
    const recordsets = await this.kycRepository.approveKyc(data);
    // The SP emits debug SELECTs first; its real outcome is the last
    // recordset that carries a `result` column.
    const outcome =
      [...recordsets]
        .reverse()
        .find((rs) => rs?.length && "result" in rs[0]) ??
      recordsets[recordsets.length - 1] ??
      [];
    const row = outcome[0];

    // Final-stage approval generated the supplier code — send the portal
    // invite mail (username + temp password, forced reset on first login).
    if (row?.result === "SUCCESS" && row?.supp_code) {
      row.supplier_invite = await this.sendSupplierInvite(
        data.kyc_basic_info_sno,
        data.ecno
      );
    }

    return outcome;
  }

  // Creates/resets the supplier portal login and emails the credentials.
  // Never throws: an email failure must not roll back an approval that has
  // already been committed by the stored procedure.
  static async sendSupplierInvite(kyc_basic_info_sno, created_by) {
    try {
      const contact = await this.kycRepository.getSupplierContact(kyc_basic_info_sno);
      if (!contact?.email) {
        return { emailSent: false, reason: "No email on the KYC record" };
      }

      const tempPassword = generateTempPassword();
      const password_hash = await bcrypt.hash(tempPassword, SALT_ROUNDS);

      await this.kycRepository.createSupplierLogin({
        kyc_basic_info_sno,
        login_email: contact.email,
        password_hash,
        created_by,
      });

      const mailResult = await sendSupplierInviteEmail({
        to: contact.email,
        companyName: contact.company_name || "Supplier",
        suppCode: contact.supp_code,
        tempPassword,
        portalUrl: SUPPLIER_PORTAL_URL,
      });

      return { emailSent: mailResult.sent, login_email: contact.email };
    } catch (error) {
      console.error("Supplier invite failed:", error.message);
      return { emailSent: false, reason: error.message };
    }
  }

  static fetchVendorDatas(filters = {}) {
    return this.kycRepository.fetchVendorDatas(filters);
  }

  static async getGSTNDetails(gst) {
    const xmlPayload = `<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Body>
    <Get_GSTN_Details xmlns="http://tempuri.org/">
      <GSTN>${escapeXml(gst)}</GSTN>
    </Get_GSTN_Details>
  </soap:Body>
</soap:Envelope>`;

    const response = await axios.post(GSTN_SERVICE_URL, xmlPayload, {
      headers: {
        "Content-Type": "text/xml; charset=utf-8",
        SOAPAction: GSTN_SOAP_ACTION,
      },
      responseType: "text",
      timeout: GSTN_SERVICE_TIMEOUT_MS,
    });

    const parser = new xml2js.Parser({
      explicitArray: false,
      tagNameProcessors: [stripPrefix],
      trim: true,
    });

    const parsedXml = await parser.parseStringPromise(response.data);
    const resultNode =
      parsedXml?.Envelope?.Body?.Get_GSTN_DetailsResponse
        ?.Get_GSTN_DetailsResult;

    if (!resultNode) {
      const error = new Error("No result returned from GSTN service");
      error.statusCode = 502;
      throw error;
    }

    const jsonString =
      typeof resultNode === "object" &&
      resultNode !== null &&
      "_" in resultNode
        ? resultNode._
        : resultNode;

    if (typeof jsonString !== "string") {
      const error = new Error("Invalid result returned from GSTN service");
      error.statusCode = 502;
      throw error;
    }

    try {
      return JSON.parse(jsonString);
    } catch {
      const error = new Error("Invalid JSON returned by GSTN service");
      error.statusCode = 502;
      throw error;
    }
  }
}

export default KYCServices;
