// Replaces the "Smoke Test ..." placeholder data on the 5 service-vendor KYC
// records seeded earlier (sql/_seed_service_and_bank_suppliers.mjs) with
// different, still-fictional test data that doesn't use "smoke"/"test" in the
// name. Real company/bank details were never provided by the user, so these
// remain clearly-not-real test fixtures — just renamed away from the
// "Smoke Test" label per explicit request.
//
// There is no update SP for service_vendor_kyc yet (module is new, only
// create/approve/list exist), so this updates the two live tables directly:
//   - dbo.service_vendor_kyc          (the KYC intake record itself)
//   - dbo.kyc_basic_info              (the auto-provisioned vendor record
//                                       sp_approve_service_vendor_kyc created)
// It also INSERTs into dbo.kyc_bank_info, which the approval SP never
// populates (confirmed: sp_approve_service_vendor_kyc's final-stage insert
// only writes kyc_basic_info, not kyc_bank_info) — without this, these
// vendors would show no "Bank details (KYC)" panel on the Loan Payment
// screen (sp_nt_GetLoanDetail's beneficiary_json reads kyc_bank_info).
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

const records = [
  {
    service_vendor_kyc_sno: 2,
    kyc_basic_info_sno: 107,
    company_name: "Aravali Electrical Contractors",
    contact_person: "Anand Kumar",
    email: "info@aravalielectrical.example.com",
    mobile_number: "9845010001",
    business_type: "Electrical Contractor / AMC Services",
    pan_no: "AAFCA2025K",
    ac_holder_name: "Aravali Electrical Contractors",
    ac_number: "120401000111",
    ac_type: "Current",
    ifsc: "ICIC0001234",
    bank_name: "ICICI Bank",
    bank_branch_name: "Vadapalani Branch",
    bank_address: "12, Anna Salai, Chennai - 600002",
  },
  {
    service_vendor_kyc_sno: 7,
    kyc_basic_info_sno: 108,
    company_name: "Coastal Line Logistics",
    contact_person: "Rajesh Pillai",
    email: "ops@coastallinelogistics.example.com",
    mobile_number: "9845010002",
    business_type: "Transporter / Logistics",
    pan_no: "AAECC2026L",
    ac_holder_name: "Coastal Line Logistics",
    ac_number: "50100234567",
    ac_type: "Current",
    ifsc: "HDFC0002345",
    bank_name: "HDFC Bank",
    bank_branch_name: "Coimbatore Main Branch",
    bank_address: "45, Race Course Road, Coimbatore - 641018",
  },
  {
    service_vendor_kyc_sno: 8,
    kyc_basic_info_sno: 109,
    company_name: "Silver Oak Facility Services",
    contact_person: "Meena Iyer",
    email: "admin@silveroakfacility.example.com",
    mobile_number: "9845010003",
    business_type: "Facility Management / Housekeeping",
    pan_no: "AABCS2027M",
    ac_holder_name: "Silver Oak Facility Services",
    ac_number: "35672345678",
    ac_type: "Current",
    ifsc: "SBIN0003456",
    bank_name: "State Bank of India",
    bank_branch_name: "Salem Branch",
    bank_address: "78, Cherry Road, Salem - 636007",
  },
  {
    service_vendor_kyc_sno: 9,
    kyc_basic_info_sno: 110,
    company_name: "Bluepeak IT Solutions",
    contact_person: "Divya Menon",
    email: "support@bluepeakit.example.com",
    mobile_number: "9845010004",
    business_type: "IT / AMC Support Services",
    pan_no: "AAFCB2028N",
    ac_holder_name: "Bluepeak IT Solutions",
    ac_number: "91802034567",
    ac_type: "Current",
    ifsc: "UTIB0004567",
    bank_name: "Axis Bank",
    bank_branch_name: "Trichy Branch",
    bank_address: "23, Bharathidasan Salai, Trichy - 620001",
  },
  // Statutory lender — the "bank supplier" picked as vendor_sno on a LOAN/REPO/
  // CASH_CREDIT Service Agreement. Kept as a fictional co-operative bank name
  // (not a real bank) since this represents an actual credit-facility
  // relationship, not just a settlement account.
  {
    service_vendor_kyc_sno: 10,
    kyc_basic_info_sno: 111,
    company_name: "Meridian Urban Co-operative Bank Ltd",
    contact_person: "Suresh Nair",
    email: "corporate.lending@meridianbank.example.com",
    mobile_number: "9845010005",
    business_type: "Bank / NBFC (Statutory Lender)",
    pan_no: "AAACM2029P",
    ac_holder_name: "Meridian Urban Co-operative Bank Ltd",
    ac_number: "774400012345",
    ac_type: "Current",
    ifsc: "MRDB0000123",
    bank_name: "Meridian Urban Co-operative Bank Ltd",
    bank_branch_name: "Corporate Lending Branch, Chennai",
    bank_address: "100, Anna Salai, Chennai - 600006",
  },
];

for (const r of records) {
  const req1 = pool.request();
  req1.input("sno", sql.Int, r.service_vendor_kyc_sno);
  req1.input("company_name", sql.NVarChar(50), r.company_name);
  req1.input("contact_person", sql.NVarChar(50), r.contact_person);
  req1.input("email", sql.NVarChar(50), r.email);
  req1.input("mobile_number", sql.VarChar(15), r.mobile_number);
  req1.input("business_type", sql.NVarChar(50), r.business_type);
  req1.input("pan_no", sql.VarChar(20), r.pan_no);
  req1.input("ac_holder_name", sql.NVarChar(100), r.ac_holder_name);
  req1.input("ac_number", sql.VarChar(30), r.ac_number);
  req1.input("ac_type", sql.VarChar(50), r.ac_type);
  req1.input("ifsc", sql.VarChar(15), r.ifsc);
  req1.input("bank_name", sql.NVarChar(100), r.bank_name);
  req1.input("bank_branch_name", sql.NVarChar(100), r.bank_branch_name);
  req1.input("bank_address", sql.NVarChar(500), r.bank_address);
  await req1.query(`
    UPDATE dbo.service_vendor_kyc SET
      company_name = @company_name, contact_person = @contact_person, email = @email,
      mobile_number = @mobile_number, business_type = @business_type, pan_no = @pan_no,
      ac_holder_name = @ac_holder_name, ac_number = @ac_number, ac_type = @ac_type,
      ifsc = @ifsc, bank_name = @bank_name, bank_branch_name = @bank_branch_name,
      bank_address = @bank_address, modified_by = 'KTM1148', modified_at = GETDATE()
    WHERE service_vendor_kyc_sno = @sno
  `);

  const req2 = pool.request();
  req2.input("sno", sql.Int, r.kyc_basic_info_sno);
  req2.input("company_name", sql.NVarChar(50), r.company_name);
  req2.input("contact_person", sql.NVarChar(50), r.contact_person);
  req2.input("email", sql.NVarChar(50), r.email);
  req2.input("mobile_number", sql.VarChar(15), r.mobile_number);
  req2.input("business_type", sql.NVarChar(50), r.business_type);
  req2.input("pan_no", sql.VarChar(20), r.pan_no);
  await req2.query(`
    UPDATE dbo.kyc_basic_info SET
      company_name = @company_name, contact_person = @contact_person, email = @email,
      mobile_number = @mobile_number, business_type = @business_type, pan_no = @pan_no
    WHERE kyc_basic_info_sno = @sno
  `);

  const req3 = pool.request();
  req3.input("kyc_basic_info_sno", sql.Int, r.kyc_basic_info_sno);
  req3.input("ac_holder_name", sql.NVarChar(100), r.ac_holder_name);
  req3.input("ac_number", sql.BigInt, BigInt(r.ac_number));
  req3.input("ac_type", sql.NVarChar(100), r.ac_type);
  req3.input("ifsc", sql.NVarChar(100), r.ifsc);
  req3.input("bank_name", sql.NVarChar(100), r.bank_name);
  req3.input("bank_branch_name", sql.NVarChar(100), r.bank_branch_name);
  req3.input("bank_address", sql.NVarChar(200), r.bank_address);
  const existing = await req3.query(`
    SELECT kyc_address_sno FROM dbo.kyc_bank_info WHERE kyc_basic_info_sno = @kyc_basic_info_sno
  `);
  if (existing.recordset.length === 0) {
    await req3.query(`
      INSERT INTO dbo.kyc_bank_info (
        kyc_basic_info_sno, ac_holder_name, ac_number, ac_type, ifsc, bank_name,
        bank_branch_name, bank_address, is_primary, is_active, status, created_date
      ) VALUES (
        @kyc_basic_info_sno, @ac_holder_name, @ac_number, @ac_type, @ifsc, @bank_name,
        @bank_branch_name, @bank_address, 'Y', 'Y', 'P', GETDATE()
      )
    `);
    console.log(`UPDATED + BANK ROW INSERTED  sno ${r.service_vendor_kyc_sno} / kyc ${r.kyc_basic_info_sno}: ${r.company_name}`);
  } else {
    console.log(`UPDATED (bank row already existed)  sno ${r.service_vendor_kyc_sno} / kyc ${r.kyc_basic_info_sno}: ${r.company_name}`);
  }
}

await pool.close();
