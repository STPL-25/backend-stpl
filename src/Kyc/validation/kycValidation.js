// Server-side mirror of the "require" flags in
// nt-frontend-stpl/src/FieldDatas/KycFieldDatas.tsx. Run this BEFORE the
// is_gst_avail / is_msme_avail boolean coercion in the controller — an
// unanswered radio (undefined) must be caught as missing, not silently
// normalised into "No" first.
const BASIC_REQUIRED = [
  "is_gst_avail",
  "is_msme_avail",
  "supplier_cat_code",
  "pan_no",
  "company_name",
  "contact_name",
  "mobile_number",
  "email",
  "business_type",
];
const ADDRESS_REQUIRED = ["door_no", "street", "area", "city", "state", "pincode"];
const BANK_REQUIRED = ["ac_holder_name", "ac_number", "ac_type", "ifsc", "bank_name", "bank_branch_name", "bank_address"];
const CONTACT_REQUIRED = ["ownername", "ownermobile", "owneremail"];
const REQUIRED_DOCUMENTS = ["pan_file"];

function isBlank(value) {
  return value === undefined || value === null || (typeof value === "string" && value.trim() === "");
}

function pickPrimary(rows) {
  if (!Array.isArray(rows) || rows.length === 0) return null;
  return rows.find((row) => row?.isPrimary) ?? rows[0];
}

export function validateKycCreate(data, files = []) {
  const errors = [];

  BASIC_REQUIRED.forEach((field) => {
    if (isBlank(data?.[field])) errors.push(field);
  });

  const isGstAvail = data?.is_gst_avail === true || data?.is_gst_avail === "true";
  if (isGstAvail && isBlank(data?.gst_no)) errors.push("gst_no");

  const isMsmeAvail = data?.is_msme_avail === true || data?.is_msme_avail === "true";
  if (isMsmeAvail && isBlank(data?.msme_no)) errors.push("msme_no");

  const primaryAddress = pickPrimary(data?.addresses);
  if (!primaryAddress) {
    errors.push("address");
  } else {
    ADDRESS_REQUIRED.forEach((field) => {
      if (isBlank(primaryAddress[field])) errors.push(`address.${field}`);
    });
  }

  const primaryBank = pickPrimary(data?.bankDetails);
  if (!primaryBank) {
    errors.push("bank account");
  } else {
    BANK_REQUIRED.forEach((field) => {
      if (isBlank(primaryBank[field])) errors.push(`bank.${field}`);
    });
  }

  const primaryContact = pickPrimary(data?.contacts);
  if (!primaryContact) {
    errors.push("contact");
  } else {
    CONTACT_REQUIRED.forEach((field) => {
      if (isBlank(primaryContact[field])) errors.push(`contact.${field}`);
    });
  }

  const uploadedFieldnames = new Set((files || []).map((f) => f.fieldname));
  REQUIRED_DOCUMENTS.forEach((field) => {
    if (!uploadedFieldnames.has(field)) errors.push(`document.${field}`);
  });

  return { valid: errors.length === 0, errors };
}
