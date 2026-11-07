/**
 * The correction form (/kyc_resubmit): turns what the page sent into the payload sp_nt_KycResubmitSave takes, or throws an
 * Error whose message is written for the supplier ("Address 2: enter a 6-digit pincode."). userFacing = true on every error.
 * Formats and lengths are checked here; the procedure re-checks what keeps the KYC whole (the rows named are the KYC's own,
 * a PAN card exists, no other live KYC uses the GST number / PAN). Column sizes are the live kyc_* column sizes.
 * Mirrors grn-service/src/supplier/supplierKyc.validation.js (the logged-in supplier's "My KYC" form); the PAN is editable here
 * because a wrong PAN is one of the reasons a KYC gets rejected.
 */

const GSTIN = /^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/;
const PAN = /^[A-Z]{5}[0-9]{4}[A-Z]$/;
const IFSC = /^[A-Z]{4}0[A-Z0-9]{6}$/;
const PINCODE = /^[1-9][0-9]{5}$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MOBILE = /^\+?[0-9]{10,14}$/;
const MSME_NO = /^[A-Z0-9-]{6,20}$/;
const MSME_TYPES = ["Micro", "Small", "Medium"];
const LIMITS = { addresses: 10, banks: 5, contacts: 10 };

const text = (v) => (v === null || v === undefined ? "" : String(v).trim());
const flag = (v) => (v === true || v === "Y" || v === "y" || v === "true" ? "Y" : "N");

function fail(message) {
  const err = new Error(message.charAt(0).toUpperCase() + message.slice(1));
  err.userFacing = true;
  err.status = 422;
  throw err;
}

/** A trimmed value, or null when blank. Throws when required and blank, too long, or not matching. */
function field(where, label, value, { required = false, max, pattern, hint } = {}) {
  const v = text(value);
  if (!v) {
    if (required) fail(`${where}enter the ${label}.`);
    return null;
  }
  if (max && v.length > max) fail(`${where}the ${label} can be at most ${max} characters.`);
  if (pattern && !pattern.test(v)) fail(`${where}the ${label} is not valid${hint ? ` (${hint})` : ""}.`);
  return v;
}

/** An http(s) address with a real host name - no spaces and no "user@" part (https://good.com@bad.com points at bad.com). */
export function webAddress(where, label, value, { required = false, max = 500 } = {}) {
  const v = field(where, label, value, { required, max });
  if (!v) return null;
  let url;
  try {
    url = new URL(v);
  } catch {
    return fail(`${where}the ${label} must be a full web address starting with https:// or http://.`);
  }
  if (!/^https?:$/.test(url.protocol) || /\s/.test(v) || url.username || url.password || !url.hostname.includes(".")) {
    fail(`${where}the ${label} must be a full web address starting with https:// or http://.`);
  }
  return v;
}

const staleForm = () => fail("This form no longer matches your KYC. Reload the page and make your corrections again.");

const optionalSno = (v) => {
  if (v === null || v === undefined || v === "") return null;
  const n = Number(v);
  if (!Number.isInteger(n) || n <= 0) staleForm();
  return n;
};

const mobile = (where, label, value) => {
  const v = text(value).replace(/[\s-]/g, "");
  return field(where, label, v, { required: true, max: 15, pattern: MOBILE, hint: "10 digits, or + and the country code" });
};

function exactlyOnePrimary(rows, noun) {
  if (rows.filter((r) => r.is_primary === "Y").length !== 1) fail(`Mark exactly one ${noun} as primary.`);
}

/**
 * @param form  { note, basic, addresses, banks, contacts } as the page sends it
 * @param ctx   the choices on the form: { business_types, account_types, supplier_categories: string[] } and the KYC's
 *              current { business_type, supplier_cat_code } (a value already on file stays valid even if the master retired it)
 */
export function parseResubmitPayload(form, ctx = {}) {
  if (!form || typeof form !== "object") fail("The form is empty.");

  const note = field("", "note", form.note, { max: 500 });

  const b = form.basic ?? {};
  const w = "Company details: ";
  const basic = {
    company_name: field(w, "company name", b.company_name, { required: true, max: 50 }),
    legal_name: field(w, "legal name", b.legal_name, { max: 100 }),
    trade_name: field(w, "trade name", b.trade_name, { max: 100 }),
    contact_person: field(w, "contact person", b.contact_person, { required: true, max: 50 }),
    email: field(w, "email", b.email, { required: true, max: 50, pattern: EMAIL }),
    mobile_number: mobile(w, "mobile number", b.mobile_number),
    business_type: field(w, "business type", b.business_type, { required: true, max: 50 }),
    supplier_cat_code: field(w, "supplier category", b.supplier_cat_code, { max: 20 }),
    pan_no: field(w, "PAN", text(b.pan_no).toUpperCase(), { required: true, max: 20, pattern: PAN, hint: "10 characters, e.g. ABCDE1234F" }),
    is_gst_avail: flag(b.is_gst_avail),
    gst_no: null,
    is_msme_avail: flag(b.is_msme_avail),
    msme_no: null,
    msme_type: null,
    pay_via_portal: flag(b.pay_via_portal),
    payment_portal_name: null,
    payment_portal_url: null,
    payment_instructions: null,
  };

  const types = (ctx.business_types ?? []).map(String);
  if (types.length && !types.includes(basic.business_type) && basic.business_type !== text(ctx.business_type)) {
    fail(`${w}choose a business type from the list.`);
  }
  const categories = (ctx.supplier_categories ?? []).map(String);
  if (categories.length) {
    if (!basic.supplier_cat_code) fail(`${w}choose the supplier category.`);
    if (!categories.includes(basic.supplier_cat_code) && basic.supplier_cat_code !== text(ctx.supplier_cat_code)) {
      fail(`${w}choose a supplier category from the list.`);
    }
  }

  if (basic.is_gst_avail === "Y") {
    basic.gst_no = field(w, "GST number", text(b.gst_no).toUpperCase(), { required: true, max: 20, pattern: GSTIN, hint: "15 characters, e.g. 33ABCDE1234F1Z5" });
    if (basic.gst_no.slice(2, 12) !== basic.pan_no) fail(`${w}the GST number must contain your PAN (${basic.pan_no}) as characters 3 to 12.`);
  }
  if (basic.is_msme_avail === "Y") {
    basic.msme_no = field(w, "MSME (Udyam) number", text(b.msme_no).toUpperCase(), { required: true, max: 20, pattern: MSME_NO, hint: "e.g. UDYAM-TN-01-0012345" });
    const type = text(b.msme_type);
    if (type && !MSME_TYPES.includes(type)) fail(`${w}choose Micro, Small or Medium as the MSME type.`);
    basic.msme_type = type || null;
  }

  if (basic.pay_via_portal === "Y") {
    const p = "Payment: ";
    basic.payment_portal_name = field(p, "portal name", b.payment_portal_name, { required: true, max: 150 });
    basic.payment_portal_url = webAddress(p, "portal web address", b.payment_portal_url, { required: true });
    basic.payment_instructions = field(p, "payment instructions", b.payment_instructions, { max: 1000 });
  }

  const rawAddresses = Array.isArray(form.addresses) ? form.addresses : [];
  if (rawAddresses.length === 0) fail("Add at least one address.");
  if (rawAddresses.length > LIMITS.addresses) fail(`You can keep at most ${LIMITS.addresses} addresses.`);
  const addresses = rawAddresses.map((a, i) => {
    const where = `Address ${i + 1}: `;
    const stateCode = text(a?.state_code);
    if (stateCode && !/^[0-9]{1,2}$/.test(stateCode)) fail(`${where}the state code is the 2-digit GST state code.`);
    return {
      kyc_address_sno: optionalSno(a?.kyc_address_sno),
      door_no: field(where, "door / building", a?.door_no, { required: true, max: 300 }),
      street: field(where, "street", a?.street, { required: true, max: 200 }),
      area: field(where, "area", a?.area, { required: true, max: 200 }),
      city: field(where, "city", a?.city, { required: true, max: 200 }),
      taluk: field(where, "taluk", a?.taluk, { max: 200 }),
      state: field(where, "state", a?.state, { required: true, max: 200 }),
      state_code: stateCode ? Number(stateCode) : null,
      pincode: field(where, "pincode", a?.pincode, { required: true, max: 10, pattern: PINCODE, hint: "6 digits" }),
      location_link: webAddress(where, "map link", a?.location_link),
      is_primary: flag(a?.is_primary),
    };
  });
  exactlyOnePrimary(addresses, "address");

  let banks = [];
  if (basic.pay_via_portal === "N") {
    const rawBanks = Array.isArray(form.banks) ? form.banks : [];
    if (rawBanks.length === 0) fail("Add your bank account, or choose to be paid through your portal.");
    if (rawBanks.length > LIMITS.banks) fail(`You can keep at most ${LIMITS.banks} bank accounts.`);
    const accountTypes = (ctx.account_types ?? []).map(String);
    banks = rawBanks.map((k, i) => {
      const where = `Bank account ${i + 1}: `;
      const acNumber = text(k?.ac_number).replace(/\s/g, "");
      if (!acNumber) fail(`${where}enter the account number.`);
      if (!/^[0-9]{6,18}$/.test(acNumber)) fail(`${where}the account number must be 6 to 18 digits.`);
      // kyc_bank_info.ac_number is a number column: a leading 0 would be lost and the payment file would carry a wrong account
      if (acNumber.startsWith("0")) fail(`${where}account numbers starting with 0 cannot be saved here yet - please send it to the purchase team.`);
      const acType = field(where, "account type", k?.ac_type, { required: true, max: 50 });
      if (accountTypes.length && !accountTypes.includes(acType)) fail(`${where}choose the account type from the list.`);
      return {
        kyc_bank_sno: optionalSno(k?.kyc_bank_sno),
        ac_holder_name: field(where, "account holder name", k?.ac_holder_name, { required: true, max: 50 }),
        ac_number: acNumber,
        ac_type: acType,
        ifsc: field(where, "IFSC", text(k?.ifsc).toUpperCase(), { required: true, max: 11, pattern: IFSC, hint: "11 characters, e.g. HDFC0001234" }),
        bank_name: field(where, "bank name", k?.bank_name, { required: true, max: 50 }),
        bank_branch_name: field(where, "branch", k?.bank_branch_name, { required: true, max: 50 }),
        bank_address: field(where, "bank address", k?.bank_address, { required: true, max: 300 }),
        is_primary: flag(k?.is_primary),
      };
    });
    exactlyOnePrimary(banks, "bank account");
  }

  const rawContacts = Array.isArray(form.contacts) ? form.contacts : [];
  if (rawContacts.length === 0) fail("Add at least one contact.");
  if (rawContacts.length > LIMITS.contacts) fail(`You can keep at most ${LIMITS.contacts} contacts.`);
  const contacts = rawContacts.map((c, i) => {
    const where = `Contact ${i + 1}: `;
    return {
      kyc_contact_sno: optionalSno(c?.kyc_contact_sno),
      contact_name: field(where, "name", c?.contact_name, { required: true, max: 50 }),
      contact_position: field(where, "position", c?.contact_position, { max: 50 }),
      contact_mobile: mobile(where, "mobile", c?.contact_mobile),
      contact_email: field(where, "email", c?.contact_email, { required: true, max: 50, pattern: EMAIL }),
      is_primary: flag(c?.is_primary),
    };
  });
  exactlyOnePrimary(contacts, "contact");

  return { note, basic, addresses, banks, contacts };
}
