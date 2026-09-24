// One-off: submits 4 regular service-vendor KYC suppliers + 1 bank/lender
// supplier (for Statutory loan/repo/CC Service Agreements) through the real
// KYC flow — sp_nt_CreateServiceVendorKyc (status 'P') then
// sp_approve_service_vendor_kyc (single-stage workflow, approver KTM1148,
// workflow_types_id 37, org scope 1/1/1/1 — confirmed live via
// sql/_check_service_kyc_scope.mjs against Non_trade_Dev). Final approval
// auto-provisions kyc_basic_info (vendor_category='SERVICE'), same path the
// existing "Smoke Test Electricals" row (service_vendor_kyc_sno 1) took.
//
// All data below is placeholder/test data — no real company, PAN, GSTIN or
// bank account information. Names are prefixed "Smoke Test" to match the
// existing verified row and make that obvious in the DB.
import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv();

const config = {
  user: process.env.DB_USER,
  password: process.env.DB_USER_PASSWORD,
  server: process.env.SERVER,
  database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433,
  options: { trustServerCertificate: true, enableArithAbort: true },
  connectionTimeout: 15000,
  requestTimeout: 30000,
  pool: { max: 2, min: 0, idleTimeoutMillis: 5000 },
};

console.log("DB target:", process.env.SERVER, process.env.DATABASE);
const pool = await new sql.ConnectionPool(config).connect();

async function execJson(proc, payload) {
  const request = pool.request();
  request.input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify(payload));
  const result = await request.execute(proc);
  return result.recordset;
}

const SCOPE = { com_sno: 1, div_sno: 1, brn_sno: 1, dept_sno: 1 };
const CREATED_BY = "KTM1148";
const APPROVER = "KTM1148";
const APPROVAL_STAGES = [
  {
    approver_ecno: "KTM1148",
    stage: "KYC Approval",
    required_approvals: "1",
    is_mandatory: "Y",
    escalation_hours: "24",
    approver_condition: "",
    next_approver_ecno: "",
    can_forward: "Y",
    can_backward: "N",
    can_edit_data: "N",
  },
];

const suppliers = [
  // "Smoke Test AMC Services" already created + approved (service_vendor_kyc_sno 2,
  // kyc_basic_info_sno 107) in the first run of this script, before the
  // create-then-approve-immediately fix — left out of this pass to avoid a duplicate.
  {
    company_name: "Smoke Test Transport Co",
    contact_person: "Suresh Babu",
    email: "transport.smoketest@example.com",
    mobile_number: "9800000002",
    business_type: "Transporter / Logistics",
    pan_no: "BBBBT2222B",
    ac_holder_name: "Smoke Test Transport Co",
    ac_number: "000111000002",
    ac_type: "Current",
    ifsc: "TEST0000002",
    bank_name: "Smoke Test Bank Ltd",
    bank_branch_name: "Test Branch 2",
    bank_address: "2nd Cross, Test Layout, Test City",
  },
  {
    company_name: "Smoke Test Facility Management",
    contact_person: "Lakshmi Narayanan",
    email: "facility.smoketest@example.com",
    mobile_number: "9800000003",
    business_type: "Facility Management / Housekeeping",
    pan_no: "CCCCT3333C",
    ac_holder_name: "Smoke Test Facility Management",
    ac_number: "000111000003",
    ac_type: "Current",
    ifsc: "TEST0000003",
    bank_name: "Smoke Test Bank Ltd",
    bank_branch_name: "Test Branch 3",
    bank_address: "3rd Cross, Test Layout, Test City",
  },
  {
    company_name: "Smoke Test IT Support Services",
    contact_person: "Priya Raghavan",
    email: "itsupport.smoketest@example.com",
    mobile_number: "9800000004",
    business_type: "IT / AMC Support Services",
    pan_no: "DDDDT4444D",
    ac_holder_name: "Smoke Test IT Support Services",
    ac_number: "000111000004",
    ac_type: "Current",
    ifsc: "TEST0000004",
    bank_name: "Smoke Test Bank Ltd",
    bank_branch_name: "Test Branch 4",
    bank_address: "4th Cross, Test Layout, Test City",
  },
  // Bank/lender supplier — used as the vendor_sno counterparty on a
  // Statutory (loan/repo/cash-credit) Service Agreement.
  {
    company_name: "Smoke Test Bank Ltd - Lending Division",
    contact_person: "Bank Relationship Manager",
    email: "lending.smoketest@example.com",
    mobile_number: "9800000005",
    business_type: "Bank / NBFC (Statutory Lender)",
    pan_no: "EEEET5555E",
    ac_holder_name: "Smoke Test Bank Ltd - Lending Division",
    ac_number: "000111000005",
    ac_type: "Current",
    ifsc: "TEST0000005",
    bank_name: "Smoke Test Bank Ltd",
    bank_branch_name: "Corporate Lending Branch",
    bank_address: "5th Cross, Test Layout, Test City",
  },
];

// NOTE: service_vendor_kyc.service_vendor_code is UNIQUE and stays NULL
// while a record is pending ('P') — SQL Server's UNIQUE constraint allows
// only ONE NULL per column, so only one record can be pending system-wide
// at a time. Create-then-approve each supplier immediately (not in two
// separate passes) to avoid a second pending NULL colliding with the first.
for (const s of suppliers) {
  const payload = {
    ...SCOPE,
    ...s,
    is_gst_avail: "N",
    is_msme_avail: "N",
    preferred_payment_mode: "BANK_TRANSFER",
    remarks: "Seeded test supplier (4 service suppliers + 1 statutory bank supplier request)",
    created_by: CREATED_BY,
  };
  let sno;
  try {
    const r = await execJson("sp_nt_CreateServiceVendorKyc", payload);
    console.log(`CREATED  ${s.company_name}:`, JSON.stringify(r[0]));
    sno = r[0].service_vendor_kyc_sno;
  } catch (e) {
    console.error(`CREATE FAILED  ${s.company_name}:`, e.message);
    continue;
  }
  try {
    const r = await execJson("sp_approve_service_vendor_kyc", {
      service_vendor_kyc_sno: sno,
      approved_by: APPROVER,
      comments: "Approved via seed script",
      approval_stages: APPROVAL_STAGES,
      action: "approve",
    });
    console.log(`APPROVED ${s.company_name}:`, JSON.stringify(r[0]));
  } catch (e) {
    console.error(`APPROVE FAILED ${s.company_name}:`, e.message);
  }
}

await pool.close();
