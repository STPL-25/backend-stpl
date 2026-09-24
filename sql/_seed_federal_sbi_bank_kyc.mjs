// One-off: adds Federal Bank and State Bank of India (SBI) as Service KYC
// vendors with business_type "Bank / NBFC (Statutory Lender)" — same role as
// the existing Meridian Urban Co-operative Bank Ltd row (service_vendor_kyc_sno
// 10 / kyc_basic_info_sno 111) — via the real KYC flow:
// sp_nt_CreateServiceVendorKyc (status 'P') then sp_approve_service_vendor_kyc
// (single-stage workflow, workflow_types_id 37, approver KTM1148, org scope
// 1/1/1/1 — confirmed live). Final approval auto-provisions kyc_basic_info
// (vendor_category='SERVICE'). Then manually inserts kyc_bank_info, since
// sp_approve_service_vendor_kyc still doesn't provision it (confirmed bug,
// flagged via spawn_task task_bdd5b872 2026-09-23, not yet fixed).
//
// Company names are the real banks per user request, but contact/PAN/IFSC/
// account number are clearly-fake TEST-prefixed placeholders — no real
// onboarding details for these banks were provided, so nothing real-looking
// is recorded against them.
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

const banks = [
  {
    company_name: "Federal Bank Ltd",
    contact_person: "Bank Relationship Manager",
    email: "lending.federalbank.test@example.com",
    mobile_number: "9800000006",
    business_type: "Bank / NBFC (Statutory Lender)",
    pan_no: "TESTF1111F",
    ac_holder_name: "Federal Bank Ltd",
    ac_number: "000111000006",
    ac_type: "Current",
    ifsc: "TEST0000006",
    bank_name: "Federal Bank Ltd",
    bank_branch_name: "Corporate Lending Branch (Test)",
    bank_address: "Test Address, Test City",
    remarks: "Placeholder test KYC entry (statutory lender) - Federal Bank",
  },
  {
    company_name: "State Bank of India",
    contact_person: "Bank Relationship Manager",
    email: "lending.sbi.test@example.com",
    mobile_number: "9800000007",
    business_type: "Bank / NBFC (Statutory Lender)",
    pan_no: "TESTS2222S",
    ac_holder_name: "State Bank of India",
    ac_number: "000111000007",
    ac_type: "Current",
    ifsc: "TEST0000007",
    bank_name: "State Bank of India",
    bank_branch_name: "Corporate Lending Branch (Test)",
    bank_address: "Test Address, Test City",
    remarks: "Placeholder test KYC entry (statutory lender) - State Bank of India (SBI)",
  },
];

// NOTE: service_vendor_kyc.service_vendor_code is UNIQUE and stays NULL while
// a record is pending ('P') — only one pending row allowed system-wide at a
// time. Create-then-approve each bank immediately (not in two passes).
const created = [];
for (const b of banks) {
  const payload = {
    ...SCOPE,
    ...b,
    is_gst_avail: "N",
    is_msme_avail: "N",
    preferred_payment_mode: "BANK_TRANSFER",
    created_by: CREATED_BY,
  };
  let sno;
  try {
    const r = await execJson("sp_nt_CreateServiceVendorKyc", payload);
    console.log(`CREATED  ${b.company_name}:`, JSON.stringify(r[0]));
    sno = r[0].service_vendor_kyc_sno;
  } catch (e) {
    console.error(`CREATE FAILED  ${b.company_name}:`, e.message);
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
    console.log(`APPROVED ${b.company_name}:`, JSON.stringify(r[0]));
    created.push({ ...b, service_vendor_kyc_sno: sno, kyc_basic_info_sno: r[0].kyc_basic_info_sno });
  } catch (e) {
    console.error(`APPROVE FAILED ${b.company_name}:`, e.message);
  }
}

// Work around the known kyc_bank_info provisioning gap (approval SP never
// inserts it) so these show up in the Loan Payment "Bank details (KYC)" panel.
for (const c of created) {
  if (!c.kyc_basic_info_sno) continue;
  const req = pool.request();
  req.input("kyc_basic_info_sno", sql.Int, c.kyc_basic_info_sno);
  req.input("ac_holder_name", sql.NVarChar(100), c.ac_holder_name);
  req.input("ac_number", sql.BigInt, BigInt(c.ac_number));
  req.input("ac_type", sql.NVarChar(100), c.ac_type);
  req.input("ifsc", sql.NVarChar(100), c.ifsc);
  req.input("bank_name", sql.NVarChar(100), c.bank_name);
  req.input("bank_branch_name", sql.NVarChar(100), c.bank_branch_name);
  req.input("bank_address", sql.NVarChar(200), c.bank_address);
  const existing = await req.query(`
    SELECT kyc_address_sno FROM dbo.kyc_bank_info WHERE kyc_basic_info_sno = @kyc_basic_info_sno
  `);
  if (existing.recordset.length === 0) {
    await req.query(`
      INSERT INTO dbo.kyc_bank_info (
        kyc_basic_info_sno, ac_holder_name, ac_number, ac_type, ifsc, bank_name,
        bank_branch_name, bank_address, is_primary, is_active, status, created_date
      ) VALUES (
        @kyc_basic_info_sno, @ac_holder_name, @ac_number, @ac_type, @ifsc, @bank_name,
        @bank_branch_name, @bank_address, 'Y', 'Y', 'P', GETDATE()
      )
    `);
    console.log(`BANK ROW INSERTED  kyc_basic_info_sno ${c.kyc_basic_info_sno}: ${c.company_name}`);
  } else {
    console.log(`bank row already existed for kyc_basic_info_sno ${c.kyc_basic_info_sno}: ${c.company_name}`);
  }
}

const picker = await pool.request().execute("sp_nt_GetApprovedServiceKycVendorsForPicker");
console.log("Picker now returns:", JSON.stringify(picker.recordset, null, 2));

await pool.close();
