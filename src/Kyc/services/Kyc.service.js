import axios from "axios";
import xml2js from "xml2js";
import KYCRepo from "../repository/Kyc.repository.js";

const { stripPrefix } = xml2js.processors;
const GSTN_SERVICE_URL =
  process.env.GSTN_SERVICE_URL ||
  "http://10.0.21.2/Mywebservice/MyWebService.asmx";
const GSTN_SOAP_ACTION = "http://tempuri.org/Get_GSTN_Details";
const GSTN_SERVICE_TIMEOUT_MS =
  Number(process.env.GSTN_SERVICE_TIMEOUT_MS) || 15000;

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
    return this.kycRepository.createKYCRecord(data);
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

  static approveKyc(data) {
    return this.kycRepository.approveKyc(data);
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
