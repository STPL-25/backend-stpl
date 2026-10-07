import axios from "axios";
import { nanoid } from "nanoid";
import { cashfreePost } from "./cashfree.client.js";
import repo from "./KycVerification.repository.js";
import { ftpUploader } from "../Utils/ImagesUpload/ImgUpload.js";

const CERT_DIR = "NON_TRADE_DATAS/KYC_DATAS";

export const PATTERNS = {
  pan: /^[A-Z]{5}[0-9]{4}[A-Z]$/,
  gstin: /^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/,
  udyam: /^UDYAM-[A-Z]{2}-[0-9]{2}-[0-9]{7}$/,
  ifsc: /^[A-Z]{4}0[A-Z0-9]{6}$/,
  account: /^[0-9]{6,20}$/,
};

function badRequest(message) {
  const err = new Error(message);
  err.statusCode = 400;
  return err;
}

// A storage failure must not break the lookup the user is waiting on; log it.
async function safeSave(row) {
  try {
    await repo.save(row);
  } catch (e) {
    console.error(`[kyc-verification] could not store ${row.verifyType} response:`, e.message);
  }
}

class KycVerificationService {
  async verifyPan(panRaw) {
    const pan = String(panRaw ?? "").trim().toUpperCase();
    if (!PATTERNS.pan.test(pan)) throw badRequest("Enter a valid 10-character PAN");
    const res = await cashfreePost("/pan", { pan });
    await safeSave({ verifyType: "PAN", identifier: pan, referenceId: res.reference_id, isValid: res.valid === true, response: res, summary: { pan_status: res.valid === true ? "ACTIVE" : "INACTIVE" } });
    return res;
  }

  // Returns Cashfree's payload untouched plus the legacy field names
  // (LegalName, TradeName, TxpType, Status, DtReg, pradr.addr) the KYC forms
  // already parse, so the old SOAP GST lookup is replaced without changing
  // how the screens read it.
  async verifyGstin(gstRaw) {
    const gstin = String(gstRaw ?? "").trim().toUpperCase();
    if (!PATTERNS.gstin.test(gstin)) throw badRequest("Enter a valid 15-character GSTIN");
    const res = await cashfreePost("/gstin", { GSTIN: gstin });
    await safeSave({ verifyType: "GSTIN", identifier: gstin, referenceId: res.reference_id, isValid: res.valid === true, response: res,
      summary: {
        gst_status: res.gst_in_status,
        gst_taxpayer_type: res.taxpayer_type,
        gst_last_update_date: res.last_update_date,
        nature_of_business_activities: res.nature_of_business_activities,
      } });

    const a = res.principal_place_split_address || {};
    return {
      ...res,
      LegalName: res.legal_name_of_business || "",
      TradeName: res.trade_name_of_business || "",
      TxpType: res.taxpayer_type || "",
      Status: res.gst_in_status || "",
      BlkStatus: "",
      DtReg: res.date_of_registration || "",
      pradr: {
        addr: {
          flno: a.flat_number || "",
          bno: a.building_number || "",
          bnm: a.building_name || "",
          st: a.street || "",
          loc: a.location || "",
          dst: a.district || a.city || "",
          stcd: gstin.slice(0, 2),
          pncd: a.pincode || "",
          state: a.state || "",
        },
      },
    };
  }

  async verifyUdyam(udyamRaw) {
    const udyam = String(udyamRaw ?? "").trim().toUpperCase();
    if (!PATTERNS.udyam.test(udyam)) throw badRequest("Enter a valid Udyam number, e.g. UDYAM-TN-03-0107610");
    const res = await cashfreePost("/udyam", { verification_id: nanoid(20).replace(/[^A-Za-z0-9]/g, "x"), udyam });

    // The certificate link Cashfree returns is a pre-signed S3 URL that expires
    // in 24h — copy the PDF to our FTP now so it can be shown later.
    let certificateUrl = "";
    if (res.udyam_certificate_url) {
      try {
        const file = await axios.get(res.udyam_certificate_url, { responseType: "arraybuffer", timeout: 30000 });
        const filename = `msme_certificate_${udyam}_${nanoid(8)}.pdf`;
        const up = await ftpUploader.uploadFile(Buffer.from(file.data), filename, CERT_DIR);
        if (up.success) certificateUrl = `${process.env.SERVER_URL}/dwl/${CERT_DIR}/${filename}`;
        else console.error("[kyc-verification] MSME certificate FTP upload failed:", up.message);
      } catch (e) {
        console.error("[kyc-verification] MSME certificate download failed:", e.message);
      }
    }

    // The signed link is temporary and embeds credentials — don't store or return it.
    const { udyam_certificate_url: _signed, ...stored } = res;
    await safeSave({ verifyType: "UDYAM", identifier: udyam, referenceId: res.reference_id, isValid: res.status === "SUCCESS", response: stored, certificateUrl,
      summary: { msme_type: res.enterprise_type, major_activity: res.major_activity, udyam_registered_date: res.date_of_udyam_registration } });
    return { ...stored, msme_certificate_url: certificateUrl };
  }

  // IFSC -> bank / branch / address via Cashfree IFSC Verification v2.
  async verifyIfsc(ifscRaw) {
    const ifsc = String(ifscRaw ?? "").trim().toUpperCase();
    if (!PATTERNS.ifsc.test(ifsc)) throw badRequest("Enter a valid IFSC code");
    const res = await cashfreePost("/ifsc", { verification_id: nanoid(20).replace(/[^A-Za-z0-9]/g, "x"), ifsc });
    const valid = String(res.status ?? "").toUpperCase() === "VALID" || Boolean(res.bank);
    await safeSave({ verifyType: "IFSC", identifier: ifsc, referenceId: res.reference_id, isValid: valid, response: res });
    return { ...res, valid };
  }

  async verifyBank(accountRaw, ifscRaw, nameRaw) {
    const account = String(accountRaw ?? "").trim();
    const ifsc = String(ifscRaw ?? "").trim().toUpperCase();
    if (!PATTERNS.account.test(account)) throw badRequest("Enter a valid bank account number");
    if (!PATTERNS.ifsc.test(ifsc)) throw badRequest("Enter a valid IFSC code");
    const body = { bank_account: account, ifsc };
    const name = String(nameRaw ?? "").trim();
    if (name) body.name = name;
    const res = await cashfreePost("/bank-account/sync", body);
    await safeSave({ verifyType: "BANK", identifier: account, referenceId: res.reference_id, isValid: res.account_status === "VALID", response: { ...res, ifsc_requested: ifsc } });
    return res;
  }

  // GST is unique when the supplier has one; PAN is unique only when they have
  // no GST (a PAN legitimately appears under several state GSTINs).
  async checkDuplicate({ gst_no, pan_no, is_gst_avail }) {
    const gst = String(gst_no ?? "").trim().toUpperCase();
    const pan = String(pan_no ?? "").trim().toUpperCase();
    const hasGst = is_gst_avail === true || is_gst_avail === "true";
    if (hasGst && PATTERNS.gstin.test(gst)) {
      const hit = await repo.findLiveKyc("gst_no", gst);
      if (hit) return { exists: true, field: "gst_no", message: "User already exists with this GST number", status: hit.status };
    } else if (!hasGst && PATTERNS.pan.test(pan)) {
      const hit = await repo.findLiveKyc("pan_no", pan);
      if (hit) return { exists: true, field: "pan_no", message: "User already exists with this PAN number", status: hit.status };
    }
    return { exists: false };
  }

  async linkToKyc(kycBasicInfoSno, kycData) {
    const banks = Array.isArray(kycData.bankDetails) ? kycData.bankDetails : [];
    await repo.linkToKyc(kycBasicInfoSno, [
      { verifyType: "PAN", identifier: String(kycData.pan_no ?? "").trim().toUpperCase() },
      { verifyType: "GSTIN", identifier: String(kycData.gst_no ?? "").trim().toUpperCase() },
      { verifyType: "UDYAM", identifier: String(kycData.msme_no ?? "").trim().toUpperCase() },
      ...banks.map((b) => ({ verifyType: "BANK", identifier: String(b.ac_number ?? "").trim() })),
      ...banks.map((b) => ({ verifyType: "IFSC", identifier: String(b.ifsc ?? "").trim().toUpperCase() })),
    ]);
    await repo.syncBasicInfo(kycBasicInfoSno);
  }

  latestCertificateUrl(udyamNo) {
    return repo.latestCertificateUrl(String(udyamNo ?? "").trim().toUpperCase());
  }

  getByKyc(kycBasicInfoSno) {
    return repo.getByKyc(kycBasicInfoSno);
  }
}

export default new KycVerificationService();
