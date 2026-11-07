// resubmit.validation.js - the correction form is checked before anything is uploaded or saved.
import { describe, it, expect } from "@jest/globals";
import { parseResubmitPayload } from "../src/KycResubmit/resubmit.validation.js";

const ctx = { business_types: ["1", "2"], account_types: ["10", "11"], supplier_categories: ["PS", "CON"], business_type: "1", supplier_cat_code: "PS" };

const form = (over = {}) => ({
  note: "Corrected the PAN and the bank account",
  basic: {
    company_name: "Acme Textiles", legal_name: "ACME TEXTILES PRIVATE LIMITED", trade_name: "Acme", contact_person: "Ravi",
    email: "ravi@acme.example", mobile_number: "98765 43210", business_type: "1", supplier_cat_code: "PS", pan_no: "abcde1234f",
    is_gst_avail: "Y", gst_no: "33abcde1234f1z5", is_msme_avail: "N", pay_via_portal: "N",
  },
  addresses: [{ kyc_address_sno: 5, door_no: "1", street: "Mill Rd", area: "Peelamedu", city: "Coimbatore", state: "Tamil Nadu", state_code: "33", pincode: "641004", is_primary: "Y" }],
  banks: [{ kyc_bank_sno: 8, ac_holder_name: "Acme", ac_number: "123456789012", ac_type: "10", ifsc: "hdfc0001234", bank_name: "HDFC", bank_branch_name: "RS Puram", bank_address: "Coimbatore", is_primary: "Y" }],
  contacts: [{ kyc_contact_sno: 3, contact_name: "Ravi", contact_mobile: "9876543210", contact_email: "ravi@acme.example", is_primary: "Y" }],
  ...over,
});
const withBasic = (b) => form({ basic: { ...form().basic, ...b } });
const message = (f, c = ctx) => {
  try {
    parseResubmitPayload(f, c);
    return null;
  } catch (e) {
    expect(e.userFacing).toBe(true);
    expect(e.status).toBe(422);
    return e.message;
  }
};

describe("a good form", () => {
  it("is normalised: upper-case PAN / GST / IFSC, spaces out of the mobile, snos kept", () => {
    const p = parseResubmitPayload(form(), ctx);
    expect(p.basic).toMatchObject({ pan_no: "ABCDE1234F", gst_no: "33ABCDE1234F1Z5", mobile_number: "9876543210", is_gst_avail: "Y", pay_via_portal: "N" });
    expect(p.banks[0]).toMatchObject({ ifsc: "HDFC0001234", ac_number: "123456789012", kyc_bank_sno: 8 });
    expect(p.addresses[0]).toMatchObject({ kyc_address_sno: 5, state_code: 33, taluk: null, location_link: null });
    expect(p.contacts[0].kyc_contact_sno).toBe(3);
    expect(p.note).toBe("Corrected the PAN and the bank account");
  });

  it("lets new rows through (no sno) and drops GST / MSME values when the answer is No", () => {
    const f = withBasic({ is_gst_avail: "N", gst_no: "garbage", is_msme_avail: "N", msme_no: "garbage" });
    f.addresses.push({ door_no: "9", street: "S", area: "A", city: "C", state: "TN", pincode: "600001", is_primary: "N" });
    const p = parseResubmitPayload(f, ctx);
    expect(p.basic.gst_no).toBeNull();
    expect(p.basic.msme_no).toBeNull();
    expect(p.addresses[1].kyc_address_sno).toBeNull();
  });

  it("accepts a business type / category already on file even if the master no longer lists it", () => {
    const p = parseResubmitPayload(withBasic({ business_type: "99", supplier_cat_code: "OLD" }), { ...ctx, business_type: "99", supplier_cat_code: "OLD" });
    expect(p.basic.business_type).toBe("99");
  });

  it("does not require a category when the master has none", () => {
    expect(message(withBasic({ supplier_cat_code: "" }), { ...ctx, supplier_categories: [] })).toBeNull();
  });
});

describe("company details", () => {
  it.each([
    [{ company_name: "" }, /enter the company name/i],
    [{ company_name: "x".repeat(51) }, /company name can be at most 50/i],
    [{ contact_person: "" }, /enter the contact person/i],
    [{ email: "not-an-email" }, /email is not valid/i],
    [{ mobile_number: "12345" }, /mobile number is not valid/i],
    [{ business_type: "" }, /enter the business type/i],
    [{ business_type: "77" }, /choose a business type from the list/i],
    [{ supplier_cat_code: "" }, /choose the supplier category/i],
    [{ supplier_cat_code: "ZZ" }, /choose a supplier category from the list/i],
    [{ pan_no: "" }, /enter the PAN/i],
    [{ pan_no: "ABCDE1234" }, /PAN is not valid/i],
    [{ gst_no: "" }, /enter the GST number/i],
    [{ gst_no: "33ABCDE1234F1Y5" }, /GST number is not valid/i],
    [{ gst_no: "29AAAAA0000A1Z5" }, /must contain your PAN \(ABCDE1234F\)/i],
    [{ is_msme_avail: "Y", msme_no: "" }, /enter the MSME/i],
    [{ is_msme_avail: "Y", msme_no: "UDYAM-TN-01-0012345", msme_type: "Giant" }, /Micro, Small or Medium/i],
  ])("refuses %j", (change, pattern) => {
    expect(message(withBasic(change))).toMatch(pattern);
  });

  it("checks the portal details when paid through a portal, and refuses a web address that points elsewhere", () => {
    expect(message(withBasic({ pay_via_portal: "Y" }))).toMatch(/portal name/i);
    expect(message(withBasic({ pay_via_portal: "Y", payment_portal_name: "P", payment_portal_url: "ftp://x.com" }))).toMatch(/full web address/i);
    expect(message(withBasic({ pay_via_portal: "Y", payment_portal_name: "P", payment_portal_url: "https://good.com@evil.com" }))).toMatch(/full web address/i);
    expect(message(withBasic({ pay_via_portal: "Y", payment_portal_name: "P", payment_portal_url: "javascript:alert(1)" }))).toMatch(/full web address/i);
    const p = parseResubmitPayload({ ...withBasic({ pay_via_portal: "Y", payment_portal_name: "P", payment_portal_url: "https://pay.example.com/login" }), banks: [] }, ctx);
    expect(p.banks).toEqual([]);
  });
});

describe("addresses, banks, contacts", () => {
  it("needs at least one address with exactly one primary, and a 6-digit pincode", () => {
    expect(message(form({ addresses: [] }))).toMatch(/at least one address/i);
    expect(message(form({ addresses: [{ ...form().addresses[0], is_primary: "N" }] }))).toMatch(/exactly one address as primary/i);
    expect(message(form({ addresses: [{ ...form().addresses[0], pincode: "12345" }] }))).toMatch(/pincode is not valid/i);
    expect(message(form({ addresses: [{ ...form().addresses[0], state_code: "ABC" }] }))).toMatch(/2-digit GST state code/i);
    expect(message(form({ addresses: [{ ...form().addresses[0], location_link: "http://a.b@evil.com" }] }))).toMatch(/full web address/i);
    expect(message(form({ addresses: Array.from({ length: 11 }, (_, i) => ({ ...form().addresses[0], kyc_address_sno: i + 1, is_primary: i ? "N" : "Y" })) }))).toMatch(/at most 10 addresses/i);
  });

  it("refuses a row number that is not a positive integer (a tampered form)", () => {
    expect(message(form({ addresses: [{ ...form().addresses[0], kyc_address_sno: "5; DROP TABLE x" }] }))).toMatch(/no longer matches your KYC/i);
    expect(message(form({ contacts: [{ ...form().contacts[0], kyc_contact_sno: -1 }] }))).toMatch(/no longer matches your KYC/i);
  });

  it("checks the bank account", () => {
    expect(message(form({ banks: [] }))).toMatch(/add your bank account/i);
    expect(message(form({ banks: [{ ...form().banks[0], ac_number: "12AB" }] }))).toMatch(/6 to 18 digits/i);
    expect(message(form({ banks: [{ ...form().banks[0], ac_number: "012345678" }] }))).toMatch(/starting with 0/i);
    expect(message(form({ banks: [{ ...form().banks[0], ifsc: "HDFC1001234" }] }))).toMatch(/IFSC is not valid/i);
    expect(message(form({ banks: [{ ...form().banks[0], ac_type: "99" }] }))).toMatch(/choose the account type from the list/i);
    expect(message(form({ banks: [{ ...form().banks[0], ac_holder_name: "" }] }))).toMatch(/account holder name/i);
    expect(message(form({ banks: [{ ...form().banks[0], is_primary: "N" }] }))).toMatch(/exactly one bank account as primary/i);
  });

  it("checks the contacts", () => {
    expect(message(form({ contacts: [] }))).toMatch(/at least one contact/i);
    expect(message(form({ contacts: [{ ...form().contacts[0], contact_email: "nope" }] }))).toMatch(/email is not valid/i);
    expect(message(form({ contacts: [{ ...form().contacts[0], contact_mobile: "1" }] }))).toMatch(/mobile is not valid/i);
  });

  it("refuses an empty form and an over-long note", () => {
    expect(message(null)).toMatch(/form is empty/i);
    expect(message(form({ note: "n".repeat(501) }))).toMatch(/note can be at most 500/i);
  });
});
