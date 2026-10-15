import mssql from "mssql";
import { initializeDatabase } from "../Dbconnections/Dbconnections.js";

let mssqlPool = await initializeDatabase();

class KycVerificationRepo {
  async save({ verifyType, identifier, referenceId, isValid, response, certificateUrl, summary = {} }) {
    const request = mssqlPool.request();
    request.input("verify_type", mssql.VarChar(10), verifyType);
    request.input("identifier", mssql.NVarChar(60), identifier);
    request.input("reference_id", mssql.NVarChar(50), referenceId == null ? null : String(referenceId));
    request.input("is_valid", mssql.Bit, isValid ? 1 : 0);
    request.input("response_json", mssql.NVarChar(mssql.MAX), JSON.stringify(response));
    request.input("certificate_url", mssql.NVarChar(500), certificateUrl || null);
    const text = (key, len) => request.input(key, mssql.NVarChar(len), summary[key] == null || summary[key] === "" ? null : String(summary[key]).slice(0, len));
    text("pan_status", 20);
    text("gst_status", 30);
    text("gst_taxpayer_type", 50);
    text("gst_last_update_date", 20);
    text("msme_type", 30);
    text("major_activity", 100);
    text("udyam_registered_date", 20);
    request.input("nature_of_business_activities", mssql.NVarChar(mssql.MAX),
      summary.nature_of_business_activities == null ? null : JSON.stringify(summary.nature_of_business_activities));
    await request.execute("sp_kyc_verification_save");
  }

  // Latest stored successful lookup for this identifier (is_valid = 1), or null.
  // Lets callers skip a paid Cashfree call when the answer is already on file.
  async findValid(verifyType, identifier) {
    const request = mssqlPool.request();
    request.input("verify_type", mssql.VarChar(10), verifyType);
    request.input("identifier", mssql.NVarChar(60), identifier);
    const r = await request.execute("sp_kyc_verification_find_valid");
    const row = r.recordset[0];
    if (!row) return null;
    try {
      return { response: JSON.parse(row.response_json), certificateUrl: row.certificate_url || "", gstStatus: row.gst_status };
    } catch {
      return null;
    }
  }

  // Attach the lookups the server itself made (never client-supplied JSON) to the
  // KYC that was just created, matching on the identifiers that were submitted.
  async linkToKyc(kycBasicInfoSno, identifiers) {
    for (const { verifyType, identifier } of identifiers.filter((p) => p.identifier)) {
      const request = mssqlPool.request();
      request.input("sno", mssql.Int, kycBasicInfoSno);
      request.input("verify_type", mssql.VarChar(10), verifyType);
      request.input("identifier", mssql.NVarChar(60), identifier);
      await request.execute("sp_kyc_verification_link_to_kyc");
    }
  }

  // Copy PAN status + MSME type onto the KYC row from the lookups just linked.
  async syncBasicInfo(kycBasicInfoSno) {
    const request = mssqlPool.request();
    request.input("sno", mssql.Int, kycBasicInfoSno);
    await request.execute("sp_kyc_verification_sync_basic_info");
  }

  // Live (approved or pending) KYCs only — a rejected one may re-register.
  async findLiveKyc(column, value) {
    const request = mssqlPool.request();
    request.input("column", mssql.VarChar(10), column);
    request.input("value", mssql.VarChar(20), value);
    const r = await request.execute("sp_kyc_verification_find_live_kyc");
    return r.recordset[0] || null;
  }

  async latestCertificateUrl(udyamNo) {
    const request = mssqlPool.request();
    request.input("identifier", mssql.NVarChar(60), udyamNo);
    const r = await request.execute("sp_kyc_verification_latest_certificate_url");
    return r.recordset[0]?.certificate_url || "";
  }

  async getByKyc(kycBasicInfoSno) {
    const request = mssqlPool.request();
    request.input("sno", mssql.Int, kycBasicInfoSno);
    const r = await request.execute("sp_kyc_verification_get_by_kyc");
    return r.recordset;
  }
}

export default new KycVerificationRepo();
