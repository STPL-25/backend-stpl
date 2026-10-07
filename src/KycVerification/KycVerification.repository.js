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
    await request.query(`
      INSERT INTO dbo.kyc_verification_response
        (verify_type, identifier, reference_id, is_valid, response_json, certificate_url,
         pan_status, gst_status, gst_taxpayer_type, gst_last_update_date, nature_of_business_activities,
         msme_type, major_activity, udyam_registered_date)
      VALUES (@verify_type, @identifier, @reference_id, @is_valid, @response_json, @certificate_url,
         @pan_status, @gst_status, @gst_taxpayer_type, @gst_last_update_date, @nature_of_business_activities,
         @msme_type, @major_activity, @udyam_registered_date)`);
  }

  // Attach the lookups the server itself made (never client-supplied JSON) to the
  // KYC that was just created, matching on the identifiers that were submitted.
  async linkToKyc(kycBasicInfoSno, identifiers) {
    for (const { verifyType, identifier } of identifiers.filter((p) => p.identifier)) {
      const request = mssqlPool.request();
      request.input("sno", mssql.Int, kycBasicInfoSno);
      request.input("verify_type", mssql.VarChar(10), verifyType);
      request.input("identifier", mssql.NVarChar(60), identifier);
      await request.query(`
        UPDATE dbo.kyc_verification_response
           SET kyc_basic_info_sno = @sno
         WHERE kyc_basic_info_sno IS NULL AND verify_type = @verify_type AND identifier = @identifier`);
    }
  }

  // Copy PAN status + MSME type onto the KYC row from the lookups just linked.
  async syncBasicInfo(kycBasicInfoSno) {
    const request = mssqlPool.request();
    request.input("sno", mssql.Int, kycBasicInfoSno);
    await request.query(`
      UPDATE k SET
        pan_status = ISNULL((SELECT TOP 1 r.pan_status FROM dbo.kyc_verification_response r
                      WHERE r.kyc_basic_info_sno = k.kyc_basic_info_sno AND r.verify_type = 'PAN' AND r.pan_status IS NOT NULL ORDER BY r.id DESC), k.pan_status),
        msme_type  = ISNULL((SELECT TOP 1 r.msme_type FROM dbo.kyc_verification_response r
                      WHERE r.kyc_basic_info_sno = k.kyc_basic_info_sno AND r.verify_type = 'UDYAM' AND r.msme_type IS NOT NULL ORDER BY r.id DESC), k.msme_type)
      FROM dbo.kyc_basic_info k WHERE k.kyc_basic_info_sno = @sno`);
  }

  // Live (approved or pending) KYCs only — a rejected one may re-register.
  async findLiveKyc(column, value) {
    const request = mssqlPool.request();
    request.input("value", mssql.VarChar(20), value);
    const r = await request.query(`
      SELECT TOP 1 kyc_basic_info_sno, status FROM dbo.kyc_basic_info
       WHERE ${column} = @value AND is_active = 'Y' AND status IN ('A', 'P')
       ORDER BY kyc_basic_info_sno DESC`);
    return r.recordset[0] || null;
  }

  async latestCertificateUrl(udyamNo) {
    const request = mssqlPool.request();
    request.input("identifier", mssql.NVarChar(60), udyamNo);
    const r = await request.query(`
      SELECT TOP 1 certificate_url FROM dbo.kyc_verification_response
       WHERE verify_type = 'UDYAM' AND identifier = @identifier AND certificate_url IS NOT NULL
       ORDER BY id DESC`);
    return r.recordset[0]?.certificate_url || "";
  }

  async getByKyc(kycBasicInfoSno) {
    const request = mssqlPool.request();
    request.input("sno", mssql.Int, kycBasicInfoSno);
    const r = await request.query(`
      SELECT verify_type, identifier, reference_id, is_valid, response_json, certificate_url, created_at,
             pan_status, gst_status, gst_taxpayer_type, gst_last_update_date, nature_of_business_activities,
             msme_type, major_activity, udyam_registered_date
        FROM dbo.kyc_verification_response WHERE kyc_basic_info_sno = @sno ORDER BY id`);
    return r.recordset;
  }
}

export default new KycVerificationRepo();
