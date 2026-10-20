-- ============================================================
-- 131_account_head_master.sql   (Non_trade_Dev ONLY)
--
-- Account Head MASTER (replaces the old Account Heads screen), seeded from TrialBal.xlsx
-- (Space Textiles Pvt Ltd - TCS Coimbatore trial balance = the Tally ledger hierarchy):
--   * acct_account_head now carries the hierarchy: parent, full path, group/ledger, GST rate, interstate, RCM.
--     The 11 system heads (GRNI, Supplier Payable, ...) keep working through system_key.
--   * 347 ledgers/groups from the trial balance are loaded (source 'TB'); only LEDGERS (not groups) can be assigned.
--   * Every product can carry an account head (product_master.account_head_sno), set on the Product master.
--     GRN journals use: product's head -> else the sub-category's head -> else Suspense.
--   * Generic master pipeline: AccountHeadMaster (list / create / update / soft delete) + AccountLedgerMaster (picker for products).
-- Re-runnable (the seed only inserts what is missing, it never overwrites edits).
-- ============================================================

IF COL_LENGTH('dbo.acct_account_head', 'parent_head_sno') IS NULL ALTER TABLE dbo.acct_account_head ADD parent_head_sno INT NULL;
IF COL_LENGTH('dbo.acct_account_head', 'head_path')       IS NULL ALTER TABLE dbo.acct_account_head ADD head_path NVARCHAR(600) NULL;
IF COL_LENGTH('dbo.acct_account_head', 'is_group')        IS NULL ALTER TABLE dbo.acct_account_head ADD is_group CHAR(1) NOT NULL CONSTRAINT DF_acct_head_is_group DEFAULT 'N';
IF COL_LENGTH('dbo.acct_account_head', 'gst_rate')        IS NULL ALTER TABLE dbo.acct_account_head ADD gst_rate DECIMAL(5,2) NULL;
IF COL_LENGTH('dbo.acct_account_head', 'is_interstate')   IS NULL ALTER TABLE dbo.acct_account_head ADD is_interstate BIT NOT NULL CONSTRAINT DF_acct_head_interstate DEFAULT 0;
IF COL_LENGTH('dbo.acct_account_head', 'is_rcm')          IS NULL ALTER TABLE dbo.acct_account_head ADD is_rcm BIT NOT NULL CONSTRAINT DF_acct_head_rcm DEFAULT 0;
IF COL_LENGTH('dbo.acct_account_head', 'source')          IS NULL ALTER TABLE dbo.acct_account_head ADD source VARCHAR(10) NOT NULL CONSTRAINT DF_acct_head_source DEFAULT 'MANUAL';
IF COL_LENGTH('dbo.acct_account_head', 'tb_row')          IS NULL ALTER TABLE dbo.acct_account_head ADD tb_row INT NULL;
IF COL_LENGTH('dbo.acct_account_head', 'modified_by')     IS NULL ALTER TABLE dbo.acct_account_head ADD modified_by VARCHAR(30) NULL;
IF COL_LENGTH('dbo.acct_account_head', 'modified_at')     IS NULL ALTER TABLE dbo.acct_account_head ADD modified_at DATETIME NULL;
GO
UPDATE dbo.acct_account_head SET source = 'SYSTEM' WHERE system_key IS NOT NULL AND source <> 'SYSTEM';
UPDATE dbo.acct_account_head SET head_path = head_name WHERE head_path IS NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_acct_head_parent')
    ALTER TABLE dbo.acct_account_head ADD CONSTRAINT FK_acct_head_parent FOREIGN KEY (parent_head_sno) REFERENCES dbo.acct_account_head (head_sno);
GO

-- ── seed from the trial balance ─────────────────────────────────────────────
DECLARE @j NVARCHAR(MAX) = N'[{"code":"TB0009","name":"III. Current Liabilities","type":"LIABILITY","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities","tb_row":9},{"code":"TB0010","name":"Statutory Dues Payable","type":"LIABILITY","parent_code":"TB0009","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable","tb_row":10},{"code":"TB0011","name":"ESI & EPF Payable","type":"LIABILITY","parent_code":"TB0010","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > ESI & EPF Payable","tb_row":11},{"code":"TB0012","name":"EPF Payable","type":"LIABILITY","parent_code":"TB0011","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > ESI & EPF Payable > EPF Payable","tb_row":12},{"code":"TB0013","name":"EPF Staff Collection","type":"LIABILITY","parent_code":"TB0012","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > ESI & EPF Payable > EPF Payable > EPF Staff Collection","tb_row":13},{"code":"TB0014","name":"ESI Payable","type":"LIABILITY","parent_code":"TB0011","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > ESI & EPF Payable > ESI Payable","tb_row":14},{"code":"TB0015","name":"ESI Staff Collection","type":"LIABILITY","parent_code":"TB0014","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > ESI & EPF Payable > ESI Payable > ESI Staff Collection","tb_row":15},{"code":"TB0016","name":"GST Payable","type":"LIABILITY","parent_code":"TB0010","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable","tb_row":16},{"code":"TB0017","name":"GST Payable","type":"LIABILITY","parent_code":"TB0016","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > GST Payable","tb_row":17},{"code":"TB0018","name":"Input Carryover - CGST","type":"LIABILITY","parent_code":"TB0017","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > GST Payable > Input Carryover - CGST","tb_row":18},{"code":"TB0019","name":"Input Carryover - IGST","type":"LIABILITY","parent_code":"TB0017","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > GST Payable > Input Carryover - IGST","tb_row":19},{"code":"TB0020","name":"Input Carryover - SGST","type":"LIABILITY","parent_code":"TB0017","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > GST Payable > Input Carryover - SGST","tb_row":20},{"code":"TB0021","name":"Input CGST @ 1.50%","type":"LIABILITY","parent_code":"TB0017","is_group":"N","gst_rate":1.5,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > GST Payable > Input CGST @ 1.50%","tb_row":21},{"code":"TB0022","name":"Input CGST @ 2.50 %","type":"LIABILITY","parent_code":"TB0017","is_group":"N","gst_rate":2.5,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > GST Payable > Input CGST @ 2.50 %","tb_row":22},{"code":"TB0023","name":"Input CGST @ 6%","type":"LIABILITY","parent_code":"TB0017","is_group":"N","gst_rate":6.0,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > GST Payable > Input CGST @ 6%","tb_row":23},{"code":"TB0024","name":"Input CGST @ 9%","type":"LIABILITY","parent_code":"TB0017","is_group":"N","gst_rate":9.0,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > GST Payable > Input CGST @ 9%","tb_row":24},{"code":"TB0025","name":"Input IGST @ 12%","type":"LIABILITY","parent_code":"TB0017","is_group":"N","gst_rate":12.0,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > GST Payable > Input IGST @ 12%","tb_row":25},{"code":"TB0026","name":"Input IGST @ 18%","type":"LIABILITY","parent_code":"TB0017","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > GST Payable > Input IGST @ 18%","tb_row":26},{"code":"TB0027","name":"Input IGST @ 3%","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":3.0,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Input IGST @ 3%","tb_row":27},{"code":"TB0028","name":"Input IGST @ 5%","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Input IGST @ 5%","tb_row":28},{"code":"TB0029","name":"Input SGST @ 1.50%","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":1.5,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Input SGST @ 1.50%","tb_row":29},{"code":"TB0030","name":"Input SGST @ 2.50 %","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":2.5,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Input SGST @ 2.50 %","tb_row":30},{"code":"TB0031","name":"Input SGST @ 6%","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":6.0,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Input SGST @ 6%","tb_row":31},{"code":"TB0032","name":"Input SGST @ 9%","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":9.0,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Input SGST @ 9%","tb_row":32},{"code":"TB0033","name":"Output CGST @ 1.5% (Output CGST @ 1.50%)","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":1.5,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Output CGST @ 1.5% (Output CGST @ 1.50%)","tb_row":33},{"code":"TB0034","name":"Output CGST @ 2.5% (Output CGST @ 2.50%)","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":2.5,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Output CGST @ 2.5% (Output CGST @ 2.50%)","tb_row":34},{"code":"TB0035","name":"Output CGST @ 2.5% - RCM","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":2.5,"interstate":0,"rcm":1,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Output CGST @ 2.5% - RCM","tb_row":35},{"code":"TB0036","name":"Output CGST @ 9%","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":9.0,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Output CGST @ 9%","tb_row":36},{"code":"TB0037","name":"Output CGST @ 9% - RCM","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":9.0,"interstate":0,"rcm":1,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Output CGST @ 9% - RCM","tb_row":37},{"code":"TB0038","name":"Output IGST @ 5%","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Output IGST @ 5%","tb_row":38},{"code":"TB0039","name":"Output IGST @ 5% RCM","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":1,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Output IGST @ 5% RCM","tb_row":39},{"code":"TB0040","name":"Output SGST @ 1.5% (Output SGST @ 1.50%)","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":1.5,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Output SGST @ 1.5% (Output SGST @ 1.50%)","tb_row":40},{"code":"TB0041","name":"Output SGST @ 2.5% (Output SGST @ 2.50%)","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":2.5,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Output SGST @ 2.5% (Output SGST @ 2.50%)","tb_row":41},{"code":"TB0042","name":"Output SGST @ 2.5% - RCM","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":2.5,"interstate":0,"rcm":1,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Output SGST @ 2.5% - RCM","tb_row":42},{"code":"TB0043","name":"Output SGST @ 9%","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":9.0,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Output SGST @ 9%","tb_row":43},{"code":"TB0044","name":"Output SGST @ 9% - RCM","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":9.0,"interstate":0,"rcm":1,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Output SGST @ 9% - RCM","tb_row":44},{"code":"TB0045","name":"Reversal ITC - CGST","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Reversal ITC - CGST","tb_row":45},{"code":"TB0046","name":"Reversal ITC - IGST","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Reversal ITC - IGST","tb_row":46},{"code":"TB0047","name":"Reversal ITC - SGST","type":"LIABILITY","parent_code":"TB0016","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > GST Payable > Reversal ITC - SGST","tb_row":47},{"code":"TB0048","name":"TDS Payable","type":"LIABILITY","parent_code":"TB0010","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > TDS Payable","tb_row":48},{"code":"TB0049","name":"TDS @ 0.10% on Purchases (U/s 194Q) (1031)","type":"LIABILITY","parent_code":"TB0048","is_group":"N","gst_rate":0.1,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > TDS Payable > TDS @ 0.10% on Purchases (U/s 194Q) (1031)","tb_row":49},{"code":"TB0050","name":"TDS @ 1% on Contract Payments (U/s 194C) (1023)","type":"LIABILITY","parent_code":"TB0048","is_group":"N","gst_rate":1.0,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > TDS Payable > TDS @ 1% on Contract Payments (U/s 194C) (1023)","tb_row":50},{"code":"TB0051","name":"TDS @ 10% on Professional Fees (U/s. 194Jb) (1027)","type":"LIABILITY","parent_code":"TB0048","is_group":"N","gst_rate":10.0,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > TDS Payable > TDS @ 10% on Professional Fees (U/s. 194Jb) (1027)","tb_row":51},{"code":"TB0052","name":"TDS @ 10% on Rent (U/s 194Ib) (1009)","type":"LIABILITY","parent_code":"TB0048","is_group":"N","gst_rate":10.0,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > TDS Payable > TDS @ 10% on Rent (U/s 194Ib) (1009)","tb_row":52},{"code":"TB0053","name":"TDS @ 2% on Contract Payments (U/s 194C) (1024)","type":"LIABILITY","parent_code":"TB0048","is_group":"N","gst_rate":2.0,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > TDS Payable > TDS @ 2% on Contract Payments (U/s 194C) (1024)","tb_row":53},{"code":"TB0054","name":"TDS @ 2% on Technical Payments (U/s 194J(A) (1026)","type":"LIABILITY","parent_code":"TB0048","is_group":"N","gst_rate":2.0,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > TDS Payable > TDS @ 2% on Technical Payments (U/s 194J(A) (1026)","tb_row":54},{"code":"TB0055","name":"TDS on Director Remuneration (U/s 192B) (1002)","type":"LIABILITY","parent_code":"TB0048","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Statutory Dues Payable > TDS Payable > TDS on Director Remuneration (U/s 192B) (1002)","tb_row":55},{"code":"TB0056","name":"Provisions for Employee Benefits","type":"LIABILITY","parent_code":"TB0009","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Provisions for Employee Benefits","tb_row":56},{"code":"TB0057","name":"Bonus Payable","type":"LIABILITY","parent_code":"TB0056","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"III. Current Liabilities > Provisions for Employee Benefits > Bonus Payable","tb_row":57},{"code":"TB0058","name":"I. Fixed Assets","type":"ASSET","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets","tb_row":58},{"code":"TB0059","name":"Buildings","type":"ASSET","parent_code":"TB0058","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Buildings","tb_row":59},{"code":"TB0060","name":"Office Equipments","type":"ASSET","parent_code":"TB0058","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Office Equipments","tb_row":60},{"code":"TB0061","name":"AC Chiller","type":"ASSET","parent_code":"TB0060","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Office Equipments > AC Chiller","tb_row":61},{"code":"TB0062","name":"Canteen Equipments","type":"ASSET","parent_code":"TB0061","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Office Equipments > AC Chiller > Canteen Equipments","tb_row":62},{"code":"TB0063","name":"Canteen Equipments @18%","type":"ASSET","parent_code":"TB0061","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Office Equipments > AC Chiller > Canteen Equipments @18%","tb_row":63},{"code":"TB0064","name":"Car Lift","type":"ASSET","parent_code":"TB0058","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Car Lift","tb_row":64},{"code":"TB0065","name":"CCTV Equipment","type":"ASSET","parent_code":"TB0064","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Car Lift > CCTV Equipment","tb_row":65},{"code":"TB0066","name":"CCTV Equipment @ 18%","type":"ASSET","parent_code":"TB0065","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Car Lift > CCTV Equipment > CCTV Equipment @ 18%","tb_row":66},{"code":"TB0067","name":"CCTV Equipment @ 28%","type":"ASSET","parent_code":"TB0065","is_group":"N","gst_rate":28.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Car Lift > CCTV Equipment > CCTV Equipment @ 28%","tb_row":67},{"code":"TB0068","name":"Cellphone 18%","type":"ASSET","parent_code":"TB0064","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Car Lift > Cellphone 18%","tb_row":68},{"code":"TB0069","name":"Lift","type":"ASSET","parent_code":"TB0058","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift","tb_row":69},{"code":"TB0070","name":"Mobile Purchase","type":"ASSET","parent_code":"TB0069","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Mobile Purchase","tb_row":70},{"code":"TB0071","name":"Mobile Purchase @ 18%","type":"ASSET","parent_code":"TB0070","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Mobile Purchase > Mobile Purchase @ 18%","tb_row":71},{"code":"TB0072","name":"Mobile Purchase @ 18% Interstate","type":"ASSET","parent_code":"TB0070","is_group":"N","gst_rate":18.0,"interstate":1,"rcm":0,"path":"I. Fixed Assets > Lift > Mobile Purchase > Mobile Purchase @ 18% Interstate","tb_row":72},{"code":"TB0073","name":"Office Equipment @ 18%","type":"ASSET","parent_code":"TB0070","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Mobile Purchase > Office Equipment @ 18%","tb_row":73},{"code":"TB0074","name":"Office Equipment @ 28%","type":"ASSET","parent_code":"TB0070","is_group":"N","gst_rate":28.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Mobile Purchase > Office Equipment @ 28%","tb_row":74},{"code":"TB0075","name":"Office Equipments - Regroup","type":"ASSET","parent_code":"TB0070","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Mobile Purchase > Office Equipments - Regroup","tb_row":75},{"code":"TB0076","name":"Shop Equipment","type":"ASSET","parent_code":"TB0069","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Shop Equipment","tb_row":76},{"code":"TB0077","name":"Shop Equipment @ 18%","type":"ASSET","parent_code":"TB0076","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Shop Equipment > Shop Equipment @ 18%","tb_row":77},{"code":"TB0078","name":"Shop Equipment @ 18% Interstate","type":"ASSET","parent_code":"TB0076","is_group":"N","gst_rate":18.0,"interstate":1,"rcm":0,"path":"I. Fixed Assets > Lift > Shop Equipment > Shop Equipment @ 18% Interstate","tb_row":78},{"code":"TB0079","name":"Computers","type":"ASSET","parent_code":"TB0069","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Computers","tb_row":79},{"code":"TB0080","name":"Intangible Assets","type":"ASSET","parent_code":"TB0079","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Computers > Intangible Assets","tb_row":80},{"code":"TB0081","name":"Computer Software","type":"ASSET","parent_code":"TB0080","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Computers > Intangible Assets > Computer Software","tb_row":81},{"code":"TB0082","name":"Computer & IT Accessories","type":"ASSET","parent_code":"TB0080","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Computers > Intangible Assets > Computer & IT Accessories","tb_row":82},{"code":"TB0083","name":"Computer & IT Accessories @ 18%","type":"ASSET","parent_code":"TB0080","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Computers > Intangible Assets > Computer & IT Accessories @ 18%","tb_row":83},{"code":"TB0084","name":"Computer - Regroup","type":"ASSET","parent_code":"TB0079","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Computers > Computer - Regroup","tb_row":84},{"code":"TB0085","name":"Electrical Fittings","type":"ASSET","parent_code":"TB0069","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Electrical Fittings","tb_row":85},{"code":"TB0086","name":"A/c Fitting @18%","type":"ASSET","parent_code":"TB0085","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Electrical Fittings > A/c Fitting @18%","tb_row":86},{"code":"TB0087","name":"A/c Fitting @28%","type":"ASSET","parent_code":"TB0085","is_group":"N","gst_rate":28.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Electrical Fittings > A/c Fitting @28%","tb_row":87},{"code":"TB0088","name":"Electrical Fitting @ 18%","type":"ASSET","parent_code":"TB0085","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Electrical Fittings > Electrical Fitting @ 18%","tb_row":88},{"code":"TB0089","name":"Electrical Fitting @ 28%","type":"ASSET","parent_code":"TB0085","is_group":"N","gst_rate":28.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Electrical Fittings > Electrical Fitting @ 28%","tb_row":89},{"code":"TB0090","name":"Electrical Fitting @ 5%","type":"ASSET","parent_code":"TB0085","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Electrical Fittings > Electrical Fitting @ 5%","tb_row":90},{"code":"TB0091","name":"Electrical Fitting (New)","type":"ASSET","parent_code":"TB0085","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Electrical Fittings > Electrical Fitting (New)","tb_row":91},{"code":"TB0092","name":"Electrical Fitting - Regroup","type":"ASSET","parent_code":"TB0085","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Electrical Fittings > Electrical Fitting - Regroup","tb_row":92},{"code":"TB0093","name":"Electrical Fittings @ 12%","type":"ASSET","parent_code":"TB0085","is_group":"N","gst_rate":12.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Electrical Fittings > Electrical Fittings @ 12%","tb_row":93},{"code":"TB0094","name":"Generater","type":"ASSET","parent_code":"TB0085","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Electrical Fittings > Generater","tb_row":94},{"code":"TB0095","name":"Transformer @ 18%","type":"ASSET","parent_code":"TB0085","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Lift > Electrical Fittings > Transformer @ 18%","tb_row":95},{"code":"TB0096","name":"Land","type":"ASSET","parent_code":"TB0058","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land","tb_row":96},{"code":"TB0097","name":"Land A/c","type":"ASSET","parent_code":"TB0096","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Land A/c","tb_row":97},{"code":"TB0098","name":"Land (Gandhipuram)","type":"ASSET","parent_code":"TB0097","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Land A/c > Land (Gandhipuram)","tb_row":98},{"code":"TB0099","name":"Furniture and Fixtures","type":"ASSET","parent_code":"TB0096","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Furniture and Fixtures","tb_row":99},{"code":"TB0100","name":"Electrical Fitting @ 12% Interstate","type":"ASSET","parent_code":"TB0099","is_group":"N","gst_rate":12.0,"interstate":1,"rcm":0,"path":"I. Fixed Assets > Land > Furniture and Fixtures > Electrical Fitting @ 12% Interstate","tb_row":100},{"code":"TB0101","name":"Electrical Fitting @ 18% Interstate","type":"ASSET","parent_code":"TB0099","is_group":"N","gst_rate":18.0,"interstate":1,"rcm":0,"path":"I. Fixed Assets > Land > Furniture and Fixtures > Electrical Fitting @ 18% Interstate","tb_row":101},{"code":"TB0102","name":"Furniture & Fitting","type":"ASSET","parent_code":"TB0099","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Furniture and Fixtures > Furniture & Fitting","tb_row":102},{"code":"TB0103","name":"Furniture Fitting (New)","type":"ASSET","parent_code":"TB0102","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Furniture and Fixtures > Furniture & Fitting > Furniture Fitting (New)","tb_row":103},{"code":"TB0104","name":"Furniture & Fitting - Regroup","type":"ASSET","parent_code":"TB0102","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Furniture and Fixtures > Furniture & Fitting > Furniture & Fitting - Regroup","tb_row":104},{"code":"TB0105","name":"Furniture & Fittings @ 12% Interstate","type":"ASSET","parent_code":"TB0102","is_group":"N","gst_rate":12.0,"interstate":1,"rcm":0,"path":"I. Fixed Assets > Land > Furniture and Fixtures > Furniture & Fitting > Furniture & Fittings @ 12% Interstate","tb_row":105},{"code":"TB0106","name":"Furniture & Fittings @ 18%","type":"ASSET","parent_code":"TB0102","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Furniture and Fixtures > Furniture & Fitting > Furniture & Fittings @ 18%","tb_row":106},{"code":"TB0107","name":"Furniture & Fittings @ 18% Interstate","type":"ASSET","parent_code":"TB0102","is_group":"N","gst_rate":18.0,"interstate":1,"rcm":0,"path":"I. Fixed Assets > Land > Furniture and Fixtures > Furniture & Fitting > Furniture & Fittings @ 18% Interstate","tb_row":107},{"code":"TB0108","name":"Depreciation Reserve","type":"ASSET","parent_code":"TB0096","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Depreciation Reserve","tb_row":108},{"code":"TB0109","name":"Depreciation Reserve - Buildings","type":"ASSET","parent_code":"TB0108","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Depreciation Reserve > Depreciation Reserve - Buildings","tb_row":109},{"code":"TB0110","name":"Depreciation Reserve - Computers","type":"ASSET","parent_code":"TB0108","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Depreciation Reserve > Depreciation Reserve - Computers","tb_row":110},{"code":"TB0111","name":"Depreciation Reserve - Electrical Fittings","type":"ASSET","parent_code":"TB0108","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Depreciation Reserve > Depreciation Reserve - Electrical Fittings","tb_row":111},{"code":"TB0112","name":"Depreciation Reserve - Furniture and Fixtures","type":"ASSET","parent_code":"TB0108","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Depreciation Reserve > Depreciation Reserve - Furniture and Fixtures","tb_row":112},{"code":"TB0113","name":"Depreciation Reserve - Office Equipments","type":"ASSET","parent_code":"TB0108","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Depreciation Reserve > Depreciation Reserve - Office Equipments","tb_row":113},{"code":"TB0114","name":"Depreciation Reserve - Plant and Machinery","type":"ASSET","parent_code":"TB0108","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Depreciation Reserve > Depreciation Reserve - Plant and Machinery","tb_row":114},{"code":"TB0115","name":"Depreciation Reserve - Solar Power Plant","type":"ASSET","parent_code":"TB0108","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Depreciation Reserve > Depreciation Reserve - Solar Power Plant","tb_row":115},{"code":"TB0116","name":"Depreciation Reserve - Vehicles","type":"ASSET","parent_code":"TB0108","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Depreciation Reserve > Depreciation Reserve - Vehicles","tb_row":116},{"code":"TB0117","name":"Plant and Machinery","type":"ASSET","parent_code":"TB0096","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Plant and Machinery","tb_row":117},{"code":"TB0118","name":"LIFT","type":"ASSET","parent_code":"TB0096","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > LIFT","tb_row":118},{"code":"TB0119","name":"Escalator @ 18%","type":"ASSET","parent_code":"TB0118","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > LIFT > Escalator @ 18%","tb_row":119},{"code":"TB0120","name":"Five Level Puzzle Parking","type":"ASSET","parent_code":"TB0118","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > LIFT > Five Level Puzzle Parking","tb_row":120},{"code":"TB0121","name":"Lift @ 18%","type":"ASSET","parent_code":"TB0118","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > LIFT > Lift @ 18%","tb_row":121},{"code":"TB0122","name":"Puzzle Parking @ 18%","type":"ASSET","parent_code":"TB0118","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > LIFT > Puzzle Parking @ 18%","tb_row":122},{"code":"TB0123","name":"Two Level - Stackers Car Parking","type":"ASSET","parent_code":"TB0118","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > LIFT > Two Level - Stackers Car Parking","tb_row":123},{"code":"TB0124","name":"Solar Power Plant","type":"ASSET","parent_code":"TB0096","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Solar Power Plant","tb_row":124},{"code":"TB0125","name":"Solar Power Unit","type":"ASSET","parent_code":"TB0124","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Solar Power Plant > Solar Power Unit","tb_row":125},{"code":"TB0126","name":"Vehicles","type":"ASSET","parent_code":"TB0096","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles","tb_row":126},{"code":"TB0127","name":"Four Wheeler","type":"ASSET","parent_code":"TB0126","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Four Wheeler","tb_row":127},{"code":"TB0128","name":"Maruti Suzuki Ertiga TN66AT4951","type":"ASSET","parent_code":"TB0127","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Four Wheeler > Maruti Suzuki Ertiga TN66AT4951","tb_row":128},{"code":"TB0129","name":"Maruti Suzuki Ertiga TN66AT4951","type":"ASSET","parent_code":"TB0128","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Four Wheeler > Maruti Suzuki Ertiga TN66AT4951 > Maruti Suzuki Ertiga TN66AT4951","tb_row":129},{"code":"TB0130","name":"Maruti Suzuki Ertiga TN66AT4951 @ 18%","type":"ASSET","parent_code":"TB0128","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Four Wheeler > Maruti Suzuki Ertiga TN66AT4951 > Maruti Suzuki Ertiga TN66AT4951 @ 18%","tb_row":130},{"code":"TB0131","name":"Maruti Suzuki Ertiga TN66AT4951 @ 28%","type":"ASSET","parent_code":"TB0128","is_group":"N","gst_rate":28.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Four Wheeler > Maruti Suzuki Ertiga TN66AT4951 > Maruti Suzuki Ertiga TN66AT4951 @ 28%","tb_row":131},{"code":"TB0132","name":"Maruti Suzuki Ertiga TN66AT4951 @ 28% + Cess","type":"ASSET","parent_code":"TB0128","is_group":"N","gst_rate":28.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Four Wheeler > Maruti Suzuki Ertiga TN66AT4951 > Maruti Suzuki Ertiga TN66AT4951 @ 28% + Cess","tb_row":132},{"code":"TB0133","name":"Tata Sumo","type":"ASSET","parent_code":"TB0127","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Four Wheeler > Tata Sumo","tb_row":133},{"code":"TB0134","name":"TN37 DA3888 (Volvo)","type":"ASSET","parent_code":"TB0133","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Four Wheeler > Tata Sumo > TN37 DA3888 (Volvo)","tb_row":134},{"code":"TB0135","name":"TN66AK8764-MARUTI EECO BSVI 5STR AC(O)","type":"ASSET","parent_code":"TB0134","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Four Wheeler > Tata Sumo > TN37 DA3888 (Volvo) > TN66AK8764-MARUTI EECO BSVI 5STR AC(O)","tb_row":135},{"code":"TB0136","name":"TN66 T8047 Mahindra Bolero Maxi","type":"ASSET","parent_code":"TB0133","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Four Wheeler > Tata Sumo > TN66 T8047 Mahindra Bolero Maxi","tb_row":136},{"code":"TB0137","name":"TN 66 Z 3299 (SKODA)","type":"ASSET","parent_code":"TB0133","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Four Wheeler > Tata Sumo > TN 66 Z 3299 (SKODA)","tb_row":137},{"code":"TB0138","name":"Two Wheeler","type":"ASSET","parent_code":"TB0126","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Two Wheeler","tb_row":138},{"code":"TB0139","name":"Splendor Xtec 2.0 (TN66 AV9904)","type":"ASSET","parent_code":"TB0138","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Two Wheeler > Splendor Xtec 2.0 (TN66 AV9904)","tb_row":139},{"code":"TB0140","name":"Splendor xtec 2.0 (TN66 AV9904)","type":"ASSET","parent_code":"TB0139","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Two Wheeler > Splendor Xtec 2.0 (TN66 AV9904) > Splendor xtec 2.0 (TN66 AV9904)","tb_row":140},{"code":"TB0141","name":"Splendor xtec 2.0 (TN66 AV9904) @ 18%","type":"ASSET","parent_code":"TB0139","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Two Wheeler > Splendor Xtec 2.0 (TN66 AV9904) > Splendor xtec 2.0 (TN66 AV9904) @ 18%","tb_row":141},{"code":"TB0142","name":"TVS XL 100 (TN66 AU7558)","type":"ASSET","parent_code":"TB0138","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Two Wheeler > TVS XL 100 (TN66 AU7558)","tb_row":142},{"code":"TB0143","name":"TVS XL 100 HD (TN66 AU7558) @ 28%","type":"ASSET","parent_code":"TB0142","is_group":"N","gst_rate":28.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Two Wheeler > TVS XL 100 (TN66 AU7558) > TVS XL 100 HD (TN66 AU7558) @ 28%","tb_row":143},{"code":"TB0144","name":"TVS XL 100 (TN66 AU7558) @ 18%","type":"ASSET","parent_code":"TB0142","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Two Wheeler > TVS XL 100 (TN66 AU7558) > TVS XL 100 (TN66 AU7558) @ 18%","tb_row":144},{"code":"TB0145","name":"Eroyce-Battery Two Wheeler-RS180","type":"ASSET","parent_code":"TB0138","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Two Wheeler > Eroyce-Battery Two Wheeler-RS180","tb_row":145},{"code":"TB0146","name":"TN66AP5171 (Hero HF Deluxe)","type":"ASSET","parent_code":"TB0138","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Two Wheeler > TN66AP5171 (Hero HF Deluxe)","tb_row":146},{"code":"TB0147","name":"TVS XL 100 TN66AP 5161","type":"ASSET","parent_code":"TB0138","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Two Wheeler > TVS XL 100 TN66AP 5161","tb_row":147},{"code":"TB0148","name":"TVS XL TN66 T6945","type":"ASSET","parent_code":"TB0138","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Two Wheeler > TVS XL TN66 T6945","tb_row":148},{"code":"TB0149","name":"TVS XL TN66 T6964","type":"ASSET","parent_code":"TB0138","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Two Wheeler > TVS XL TN66 T6964","tb_row":149},{"code":"TB0150","name":"Two Wheeler","type":"ASSET","parent_code":"TB0126","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"I. Fixed Assets > Land > Vehicles > Two Wheeler","tb_row":150},{"code":"TB0151","name":"II. Current Assets","type":"ASSET","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"II. Current Assets","tb_row":151},{"code":"TB0152","name":"Opening Stock","type":"ASSET","parent_code":"TB0151","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"II. Current Assets > Opening Stock","tb_row":152},{"code":"TB0153","name":"Stock - Textiles","type":"ASSET","parent_code":"TB0152","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"II. Current Assets > Opening Stock > Stock - Textiles","tb_row":153},{"code":"TB0154","name":"Security Deposits (Asset)","type":"ASSET","parent_code":"TB0151","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"II. Current Assets > Security Deposits (Asset)","tb_row":154},{"code":"TB0155","name":"AKV Foundations","type":"ASSET","parent_code":"TB0154","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"II. Current Assets > Security Deposits (Asset) > AKV Foundations","tb_row":155},{"code":"TB0156","name":"AKV Foundations (Security Deposit)","type":"ASSET","parent_code":"TB0155","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"II. Current Assets > Security Deposits (Asset) > AKV Foundations > AKV Foundations (Security Deposit)","tb_row":156},{"code":"TB0157","name":"Deposit - Airport","type":"ASSET","parent_code":"TB0154","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"II. Current Assets > Security Deposits (Asset) > Deposit - Airport","tb_row":157},{"code":"TB0158","name":"Deposit - Corporation Water","type":"ASSET","parent_code":"TB0157","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"II. Current Assets > Security Deposits (Asset) > Deposit - Airport > Deposit - Corporation Water","tb_row":158},{"code":"TB0159","name":"Deposit - Gas Cylinder","type":"ASSET","parent_code":"TB0157","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"II. Current Assets > Security Deposits (Asset) > Deposit - Airport > Deposit - Gas Cylinder","tb_row":159},{"code":"TB0160","name":"EB Deposit","type":"ASSET","parent_code":"TB0154","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"II. Current Assets > Security Deposits (Asset) > EB Deposit","tb_row":160},{"code":"TB0161","name":"EB Deposit - MCD","type":"ASSET","parent_code":"TB0154","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"II. Current Assets > Security Deposits (Asset) > EB Deposit - MCD","tb_row":161},{"code":"TB0162","name":"Raymond Lifestyle Limited - Dealer Deposit","type":"ASSET","parent_code":"TB0161","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"II. Current Assets > Security Deposits (Asset) > EB Deposit - MCD > Raymond Lifestyle Limited - Dealer Deposit","tb_row":162},{"code":"TB0163","name":"Short Term Loans & Advances (Asset)","type":"ASSET","parent_code":"TB0151","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"II. Current Assets > Short Term Loans & Advances (Asset)","tb_row":163},{"code":"TB0164","name":"Customer Pendings","type":"ASSET","parent_code":"TB0163","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"II. Current Assets > Short Term Loans & Advances (Asset) > Customer Pendings","tb_row":164},{"code":"TB0165","name":"Sundry Drs. Cheque","type":"ASSET","parent_code":"TB0164","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"II. Current Assets > Short Term Loans & Advances (Asset) > Customer Pendings > Sundry Drs. Cheque","tb_row":165},{"code":"TB0166","name":"Advances Recoverable in Cash Or Kind","type":"ASSET","parent_code":"TB0164","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"II. Current Assets > Short Term Loans & Advances (Asset) > Customer Pendings > Advances Recoverable in Cash Or Kind","tb_row":166},{"code":"TB0167","name":"Rent Advance","type":"ASSET","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance","tb_row":167},{"code":"TB0168","name":"Rent Advance - Dr.S.Radhakrishnan","type":"ASSET","parent_code":"TB0167","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Rent Advance - Dr.S.Radhakrishnan","tb_row":168},{"code":"TB0169","name":"Rent Advance - Elite Dwellers LLP","type":"ASSET","parent_code":"TB0167","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Rent Advance - Elite Dwellers LLP","tb_row":169},{"code":"TB0170","name":"Rent Advance - Kalpana Ethiraj","type":"ASSET","parent_code":"TB0167","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Rent Advance - Kalpana Ethiraj","tb_row":170},{"code":"TB0171","name":"Rent Advance - Kongu Township LLP","type":"ASSET","parent_code":"TB0167","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Rent Advance - Kongu Township LLP","tb_row":171},{"code":"TB0172","name":"Rent Advance - Leema Rose.M","type":"ASSET","parent_code":"TB0167","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Rent Advance - Leema Rose.M","tb_row":172},{"code":"TB0173","name":"Rent Advance - P Jaya (Ladies Hostel)","type":"ASSET","parent_code":"TB0167","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Rent Advance - P Jaya (Ladies Hostel)","tb_row":173},{"code":"TB0174","name":"Rent Advance - Ramani Appartment - S.Venkatesh","type":"ASSET","parent_code":"TB0167","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Rent Advance - Ramani Appartment - S.Venkatesh","tb_row":174},{"code":"TB0175","name":"Rent Advance-R.M. SUBRAMANIAM","type":"ASSET","parent_code":"TB0167","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Rent Advance-R.M. SUBRAMANIAM","tb_row":175},{"code":"TB0176","name":"Rent Advance - SM.Gobinath (Kanchipuram)","type":"ASSET","parent_code":"TB0167","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Rent Advance - SM.Gobinath (Kanchipuram)","tb_row":176},{"code":"TB0177","name":"Interest on MCD Deposit Receivable","type":"ASSET","parent_code":"TB0167","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Interest on MCD Deposit Receivable","tb_row":177},{"code":"TB0178","name":"Staff Advance","type":"ASSET","parent_code":"TB0167","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Staff Advance","tb_row":178},{"code":"TB0179","name":"Travelling Advance","type":"ASSET","parent_code":"TB0178","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Staff Advance > Travelling Advance","tb_row":179},{"code":"TB0180","name":"Other Loans & Advances","type":"ASSET","parent_code":"TB0167","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Other Loans & Advances","tb_row":180},{"code":"TB0181","name":"HDFC Bank Petty Cash Card - 4661 3006 0221 7016-New","type":"ASSET","parent_code":"TB0180","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Other Loans & Advances > HDFC Bank Petty Cash Card - 4661 3006 0221 7016-New","tb_row":181},{"code":"TB0182","name":"HDFC Bank Petty Cash Card - 4661 3006 0221 7149","type":"ASSET","parent_code":"TB0180","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Other Loans & Advances > HDFC Bank Petty Cash Card - 4661 3006 0221 7149","tb_row":182},{"code":"TB0183","name":"Prepaid Expenses","type":"ASSET","parent_code":"TB0180","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Other Loans & Advances > Prepaid Expenses","tb_row":183},{"code":"TB0184","name":"Tax Credit Available","type":"ASSET","parent_code":"TB0180","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Other Loans & Advances > Tax Credit Available","tb_row":184},{"code":"TB0185","name":"Test Purchase (Sales Promotion)","type":"ASSET","parent_code":"TB0180","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent Advance > Other Loans & Advances > Test Purchase (Sales Promotion)","tb_row":185},{"code":"TB0186","name":"Direct Expenses (Expenses (Direct))","type":"EXPENSE","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Direct Expenses (Expenses (Direct))","tb_row":186},{"code":"TB0187","name":"STAFF WELFARE EXP (OTHERS)","type":"EXPENSE","parent_code":"TB0186","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Direct Expenses (Expenses (Direct)) > STAFF WELFARE EXP (OTHERS)","tb_row":187},{"code":"TB0188","name":"20. Other Income","type":"INCOME","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"20. Other Income","tb_row":188},{"code":"TB0189","name":"Profit/Loss on Sale of Assets","type":"INCOME","parent_code":"TB0188","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"20. Other Income > Profit/Loss on Sale of Assets","tb_row":189},{"code":"TB0190","name":"Rent Receipt @ 18%","type":"INCOME","parent_code":"TB0188","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"20. Other Income > Rent Receipt @ 18%","tb_row":190},{"code":"TB0191","name":"Packing Expenses","type":"EXPENSE","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Packing Expenses","tb_row":191},{"code":"TB0192","name":"Packing Expenses","type":"EXPENSE","parent_code":"TB0191","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Packing Expenses > Packing Expenses","tb_row":192},{"code":"TB0193","name":"Packing Expenses @ 18%","type":"EXPENSE","parent_code":"TB0192","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Packing Expenses > Packing Expenses > Packing Expenses @ 18%","tb_row":193},{"code":"TB0194","name":"Packing Expenses @ 18% Interstate","type":"EXPENSE","parent_code":"TB0192","is_group":"N","gst_rate":18.0,"interstate":1,"rcm":0,"path":"Packing Expenses > Packing Expenses > Packing Expenses @ 18% Interstate","tb_row":194},{"code":"TB0195","name":"Packing Expenses @ 3% Interstate","type":"EXPENSE","parent_code":"TB0192","is_group":"N","gst_rate":3.0,"interstate":1,"rcm":0,"path":"Packing Expenses > Packing Expenses > Packing Expenses @ 3% Interstate","tb_row":195},{"code":"TB0196","name":"Packing Expenses @ 5%","type":"EXPENSE","parent_code":"TB0192","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"Packing Expenses > Packing Expenses > Packing Expenses @ 5%","tb_row":196},{"code":"TB0197","name":"Packing Expenses @ 5% Interstate","type":"EXPENSE","parent_code":"TB0192","is_group":"N","gst_rate":5.0,"interstate":1,"rcm":0,"path":"Packing Expenses > Packing Expenses > Packing Expenses @ 5% Interstate","tb_row":197},{"code":"TB0198","name":"Printing and Stationery","type":"EXPENSE","parent_code":"TB0191","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Packing Expenses > Printing and Stationery","tb_row":198},{"code":"TB0199","name":"Printing & Stationery @18% Interstate","type":"EXPENSE","parent_code":"TB0198","is_group":"N","gst_rate":18.0,"interstate":1,"rcm":0,"path":"Packing Expenses > Printing and Stationery > Printing & Stationery @18% Interstate","tb_row":199},{"code":"TB0200","name":"Printing & Stationery (Office)","type":"EXPENSE","parent_code":"TB0198","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Packing Expenses > Printing and Stationery > Printing & Stationery (Office)","tb_row":200},{"code":"TB0201","name":"Printing & Stationery (Office) @ 18%","type":"EXPENSE","parent_code":"TB0198","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Packing Expenses > Printing and Stationery > Printing & Stationery (Office) @ 18%","tb_row":201},{"code":"TB0202","name":"Printing & Stationery (Office) @ 5%","type":"EXPENSE","parent_code":"TB0198","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"Packing Expenses > Printing and Stationery > Printing & Stationery (Office) @ 5%","tb_row":202},{"code":"TB0203","name":"Advertisement and Sales promotion expenses","type":"EXPENSE","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Advertisement and Sales promotion expenses","tb_row":203},{"code":"TB0204","name":"Advertisement Expenses","type":"EXPENSE","parent_code":"TB0203","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Advertisement and Sales promotion expenses > Advertisement Expenses","tb_row":204},{"code":"TB0205","name":"Advertisement Expenses","type":"EXPENSE","parent_code":"TB0204","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Advertisement and Sales promotion expenses > Advertisement Expenses > Advertisement Expenses","tb_row":205},{"code":"TB0206","name":"Advertisement Expenses @ 18%","type":"EXPENSE","parent_code":"TB0204","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Advertisement and Sales promotion expenses > Advertisement Expenses > Advertisement Expenses @ 18%","tb_row":206},{"code":"TB0207","name":"Advertisement Expenses @ 18% Interstate","type":"EXPENSE","parent_code":"TB0204","is_group":"N","gst_rate":18.0,"interstate":1,"rcm":0,"path":"Advertisement and Sales promotion expenses > Advertisement Expenses > Advertisement Expenses @ 18% Interstate","tb_row":207},{"code":"TB0208","name":"Advertisement Expenses @ 5%","type":"EXPENSE","parent_code":"TB0204","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"Advertisement and Sales promotion expenses > Advertisement Expenses > Advertisement Expenses @ 5%","tb_row":208},{"code":"TB0209","name":"Sales Promotion Expenses","type":"EXPENSE","parent_code":"TB0203","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Advertisement and Sales promotion expenses > Sales Promotion Expenses","tb_row":209},{"code":"TB0210","name":"Sales Promotion Expenses","type":"EXPENSE","parent_code":"TB0209","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Advertisement and Sales promotion expenses > Sales Promotion Expenses > Sales Promotion Expenses","tb_row":210},{"code":"TB0211","name":"Sales Promotion Expenses @ 18%","type":"EXPENSE","parent_code":"TB0209","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Advertisement and Sales promotion expenses > Sales Promotion Expenses > Sales Promotion Expenses @ 18%","tb_row":211},{"code":"TB0212","name":"Sales Promotion Expenses @ 5%","type":"EXPENSE","parent_code":"TB0209","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"Advertisement and Sales promotion expenses > Sales Promotion Expenses > Sales Promotion Expenses @ 5%","tb_row":212},{"code":"TB0213","name":"Customer Service Expenses","type":"EXPENSE","parent_code":"TB0203","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Advertisement and Sales promotion expenses > Customer Service Expenses","tb_row":213},{"code":"TB0214","name":"Customer Service Expenses","type":"EXPENSE","parent_code":"TB0213","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Advertisement and Sales promotion expenses > Customer Service Expenses > Customer Service Expenses","tb_row":214},{"code":"TB0215","name":"Customer Service Expenses @ 18%( Interstate)","type":"EXPENSE","parent_code":"TB0214","is_group":"N","gst_rate":18.0,"interstate":1,"rcm":0,"path":"Advertisement and Sales promotion expenses > Customer Service Expenses > Customer Service Expenses > Customer Service Expenses @ 18%( Interstate)","tb_row":215},{"code":"TB0216","name":"Customer Service Expenses @ 5%","type":"EXPENSE","parent_code":"TB0213","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"Advertisement and Sales promotion expenses > Customer Service Expenses > Customer Service Expenses @ 5%","tb_row":216},{"code":"TB0217","name":"Customers Service Expenses @ 5% Interstate","type":"EXPENSE","parent_code":"TB0213","is_group":"N","gst_rate":5.0,"interstate":1,"rcm":0,"path":"Advertisement and Sales promotion expenses > Customer Service Expenses > Customers Service Expenses @ 5% Interstate","tb_row":217},{"code":"TB0218","name":"Bank Charges","type":"EXPENSE","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Bank Charges","tb_row":218},{"code":"TB0219","name":"Amex Card Charges @ 18%","type":"EXPENSE","parent_code":"TB0218","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Bank Charges > Amex Card Charges @ 18%","tb_row":219},{"code":"TB0220","name":"Amex Charges","type":"EXPENSE","parent_code":"TB0218","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Bank Charges > Amex Charges","tb_row":220},{"code":"TB0221","name":"Bank Charges","type":"EXPENSE","parent_code":"TB0218","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Bank Charges > Bank Charges","tb_row":221},{"code":"TB0222","name":"Credit Card Charges","type":"EXPENSE","parent_code":"TB0218","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Bank Charges > Credit Card Charges","tb_row":222},{"code":"TB0223","name":"Credit Card Charges @ 18%","type":"EXPENSE","parent_code":"TB0222","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Bank Charges > Credit Card Charges > Credit Card Charges @ 18%","tb_row":223},{"code":"TB0224","name":"Paytm Card Charges @ 18%","type":"EXPENSE","parent_code":"TB0222","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Bank Charges > Credit Card Charges > Paytm Card Charges @ 18%","tb_row":224},{"code":"TB0225","name":"Paytm Charges","type":"EXPENSE","parent_code":"TB0218","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Bank Charges > Paytm Charges","tb_row":225},{"code":"TB0226","name":"UPI Charges","type":"EXPENSE","parent_code":"TB0218","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Bank Charges > UPI Charges","tb_row":226},{"code":"TB0227","name":"UPI Charges @ 18% Interstate","type":"EXPENSE","parent_code":"TB0226","is_group":"N","gst_rate":18.0,"interstate":1,"rcm":0,"path":"Bank Charges > UPI Charges > UPI Charges @ 18% Interstate","tb_row":227},{"code":"TB0228","name":"Communication Costs","type":"EXPENSE","parent_code":"TB0218","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Bank Charges > Communication Costs","tb_row":228},{"code":"TB0229","name":"Telephone Charges","type":"EXPENSE","parent_code":"TB0228","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Bank Charges > Communication Costs > Telephone Charges","tb_row":229},{"code":"TB0230","name":"Telephone Charges - Landline @ 18%","type":"EXPENSE","parent_code":"TB0229","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Bank Charges > Communication Costs > Telephone Charges > Telephone Charges - Landline @ 18%","tb_row":230},{"code":"TB0231","name":"Telephone Charges - Mobile @ 18%","type":"EXPENSE","parent_code":"TB0229","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Bank Charges > Communication Costs > Telephone Charges > Telephone Charges - Mobile @ 18%","tb_row":231},{"code":"TB0232","name":"Directors Remuneration","type":"EXPENSE","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Directors Remuneration","tb_row":232},{"code":"TB0233","name":"Directors Remuneration (Smt. V.Meenakshi)","type":"EXPENSE","parent_code":"TB0232","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Directors Remuneration > Directors Remuneration (Smt. V.Meenakshi)","tb_row":233},{"code":"TB0234","name":"Directors Remuneration (Sri K.V Sir)","type":"EXPENSE","parent_code":"TB0232","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Directors Remuneration > Directors Remuneration (Sri K.V Sir)","tb_row":234},{"code":"TB0235","name":"Directors Remuneration (Sri Vikram Sir)","type":"EXPENSE","parent_code":"TB0232","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Directors Remuneration > Directors Remuneration (Sri Vikram Sir)","tb_row":235},{"code":"TB0236","name":"Power and fuel","type":"EXPENSE","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Power and fuel","tb_row":236},{"code":"TB0237","name":"Electricity Charges","type":"EXPENSE","parent_code":"TB0236","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Power and fuel > Electricity Charges","tb_row":237},{"code":"TB0238","name":"Electricity Charges Paid","type":"EXPENSE","parent_code":"TB0237","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Power and fuel > Electricity Charges > Electricity Charges Paid","tb_row":238},{"code":"TB0239","name":"Wheeling Charges Recoveries","type":"EXPENSE","parent_code":"TB0237","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Power and fuel > Electricity Charges > Wheeling Charges Recoveries","tb_row":239},{"code":"TB0240","name":"Electricity Charges - Interdivision","type":"EXPENSE","parent_code":"TB0237","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Power and fuel > Electricity Charges > Electricity Charges - Interdivision","tb_row":240},{"code":"TB0241","name":"Electricity Charges - Solar","type":"EXPENSE","parent_code":"TB0240","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Power and fuel > Electricity Charges > Electricity Charges - Interdivision > Electricity Charges - Solar","tb_row":241},{"code":"TB0242","name":"Electricity Charges Wind Mill SC404","type":"EXPENSE","parent_code":"TB0240","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Power and fuel > Electricity Charges > Electricity Charges - Interdivision > Electricity Charges Wind Mill SC404","tb_row":242},{"code":"TB0243","name":"Genset Diesel Expenses","type":"EXPENSE","parent_code":"TB0237","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Power and fuel > Electricity Charges > Genset Diesel Expenses","tb_row":243},{"code":"TB0244","name":"Rates and Taxes","type":"EXPENSE","parent_code":"TB0236","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Power and fuel > Rates and Taxes","tb_row":244},{"code":"TB0245","name":"ITC Reversal - Ineligible","type":"EXPENSE","parent_code":"TB0244","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Power and fuel > Rates and Taxes > ITC Reversal - Ineligible","tb_row":245},{"code":"TB0246","name":"Property & Corporation Tax","type":"EXPENSE","parent_code":"TB0244","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Power and fuel > Rates and Taxes > Property & Corporation Tax","tb_row":246},{"code":"TB0247","name":"Water Tax","type":"EXPENSE","parent_code":"TB0244","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Power and fuel > Rates and Taxes > Water Tax","tb_row":247},{"code":"TB0248","name":"Rent","type":"EXPENSE","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent","tb_row":248},{"code":"TB0249","name":"Car Parking Rent","type":"EXPENSE","parent_code":"TB0248","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent > Car Parking Rent","tb_row":249},{"code":"TB0250","name":"Rent","type":"EXPENSE","parent_code":"TB0248","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent > Rent","tb_row":250},{"code":"TB0251","name":"Rent @ 18%","type":"EXPENSE","parent_code":"TB0250","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Rent > Rent > Rent @ 18%","tb_row":251},{"code":"TB0252","name":"Rent Paid for Vehicle Parking","type":"EXPENSE","parent_code":"TB0250","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Rent > Rent > Rent Paid for Vehicle Parking","tb_row":252},{"code":"TB0253","name":"Repairs and Maintenance","type":"EXPENSE","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Repairs and Maintenance","tb_row":253},{"code":"TB0254","name":"Repairs and Maintenance - Building","type":"EXPENSE","parent_code":"TB0253","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Building","tb_row":254},{"code":"TB0255","name":"Building Maintenance","type":"EXPENSE","parent_code":"TB0254","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Building > Building Maintenance","tb_row":255},{"code":"TB0256","name":"Building Maintenance @ 18%","type":"EXPENSE","parent_code":"TB0254","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Building > Building Maintenance @ 18%","tb_row":256},{"code":"TB0257","name":"Building Maintenance @ 18% Interstate","type":"EXPENSE","parent_code":"TB0254","is_group":"N","gst_rate":18.0,"interstate":1,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Building > Building Maintenance @ 18% Interstate","tb_row":257},{"code":"TB0258","name":"Building Maintenance @ 18% Interstate( No ITC)","type":"EXPENSE","parent_code":"TB0254","is_group":"N","gst_rate":18.0,"interstate":1,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Building > Building Maintenance @ 18% Interstate( No ITC)","tb_row":258},{"code":"TB0259","name":"Repairs and Maintenance - Others","type":"EXPENSE","parent_code":"TB0253","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Others","tb_row":259},{"code":"TB0260","name":"Electrical Maintenance","type":"EXPENSE","parent_code":"TB0259","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Others > Electrical Maintenance","tb_row":260},{"code":"TB0261","name":"Electrical Maintenance","type":"EXPENSE","parent_code":"TB0260","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Others > Electrical Maintenance > Electrical Maintenance","tb_row":261},{"code":"TB0262","name":"Electrical Maintenance @ 18%","type":"EXPENSE","parent_code":"TB0261","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Others > Electrical Maintenance > Electrical Maintenance > Electrical Maintenance @ 18%","tb_row":262},{"code":"TB0263","name":"Electrical Maintenance @ 18% Interstate","type":"EXPENSE","parent_code":"TB0261","is_group":"N","gst_rate":18.0,"interstate":1,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Others > Electrical Maintenance > Electrical Maintenance > Electrical Maintenance @ 18% Interstate","tb_row":263},{"code":"TB0264","name":"Electrical Maintenance @ 5%","type":"EXPENSE","parent_code":"TB0260","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Others > Electrical Maintenance > Electrical Maintenance @ 5%","tb_row":264},{"code":"TB0265","name":"Furniture & Fittings Maintenance @ 18%","type":"EXPENSE","parent_code":"TB0260","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Others > Electrical Maintenance > Furniture & Fittings Maintenance @ 18%","tb_row":265},{"code":"TB0266","name":"Repairs & Maintenance - Computers","type":"EXPENSE","parent_code":"TB0259","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Others > Repairs & Maintenance - Computers","tb_row":266},{"code":"TB0267","name":"Repairs & Maintenance - Computers @ 18%","type":"EXPENSE","parent_code":"TB0266","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Others > Repairs & Maintenance - Computers > Repairs & Maintenance - Computers @ 18%","tb_row":267},{"code":"TB0268","name":"Repairs & Maintenance - Computers @ 18% Interstate","type":"EXPENSE","parent_code":"TB0266","is_group":"N","gst_rate":18.0,"interstate":1,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Others > Repairs & Maintenance - Computers > Repairs & Maintenance - Computers @ 18% Interstate","tb_row":268},{"code":"TB0269","name":"Repairs & Maintenance - Vehicles","type":"EXPENSE","parent_code":"TB0259","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Others > Repairs & Maintenance - Vehicles","tb_row":269},{"code":"TB0270","name":"Vehicle Maintenance @ 18%","type":"EXPENSE","parent_code":"TB0259","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Others > Vehicle Maintenance @ 18%","tb_row":270},{"code":"TB0271","name":"Vehicle Maintenance @ 5%","type":"EXPENSE","parent_code":"TB0259","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Others > Vehicle Maintenance @ 5%","tb_row":271},{"code":"TB0272","name":"Repairs and Maintenance - Plant and Machinery","type":"EXPENSE","parent_code":"TB0253","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Plant and Machinery","tb_row":272},{"code":"TB0273","name":"A/c & Other Maintenance","type":"EXPENSE","parent_code":"TB0272","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Plant and Machinery > A/c & Other Maintenance","tb_row":273},{"code":"TB0274","name":"A/c & Other Maintenance @ 18%","type":"EXPENSE","parent_code":"TB0272","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Plant and Machinery > A/c & Other Maintenance @ 18%","tb_row":274},{"code":"TB0275","name":"Generator Maintenance @ 18%","type":"EXPENSE","parent_code":"TB0272","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Plant and Machinery > Generator Maintenance @ 18%","tb_row":275},{"code":"TB0276","name":"Lift Maintanance @ 18%","type":"EXPENSE","parent_code":"TB0272","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Repairs and Maintenance - Plant and Machinery > Lift Maintanance @ 18%","tb_row":276},{"code":"TB0277","name":"Lift Maintenance","type":"EXPENSE","parent_code":"TB0253","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Repairs and Maintenance > Lift Maintenance","tb_row":277},{"code":"TB0278","name":"Subscription & Membership","type":"EXPENSE","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Subscription & Membership","tb_row":278},{"code":"TB0279","name":"News Paper,Books & Periodicals","type":"EXPENSE","parent_code":"TB0278","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Subscription & Membership > News Paper,Books & Periodicals","tb_row":279},{"code":"TB0280","name":"Travelling and Conveyance","type":"EXPENSE","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"Travelling and Conveyance","tb_row":280},{"code":"TB0281","name":"Transport Charges 5% @Interstate","type":"EXPENSE","parent_code":"TB0280","is_group":"N","gst_rate":null,"interstate":1,"rcm":0,"path":"Travelling and Conveyance > Transport Charges 5% @Interstate","tb_row":281},{"code":"TB0282","name":"Travelling Expenses - Branch Visit","type":"EXPENSE","parent_code":"TB0280","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Travelling and Conveyance > Travelling Expenses - Branch Visit","tb_row":282},{"code":"TB0283","name":"Travelling Expenses - Branch Visit @ 5%","type":"EXPENSE","parent_code":"TB0280","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"Travelling and Conveyance > Travelling Expenses - Branch Visit @ 5%","tb_row":283},{"code":"TB0284","name":"Travelling Expenses - RCM","type":"EXPENSE","parent_code":"TB0280","is_group":"N","gst_rate":null,"interstate":0,"rcm":1,"path":"Travelling and Conveyance > Travelling Expenses - RCM","tb_row":284},{"code":"TB0285","name":"Travelling & Other Related Expenses","type":"EXPENSE","parent_code":"TB0280","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Travelling and Conveyance > Travelling & Other Related Expenses","tb_row":285},{"code":"TB0286","name":"Vehicle Petrol & Diesel Expense","type":"EXPENSE","parent_code":"TB0280","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Travelling and Conveyance > Vehicle Petrol & Diesel Expense","tb_row":286},{"code":"TB0287","name":"CSR Expenses","type":"EXPENSE","parent_code":"TB0280","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"Travelling and Conveyance > CSR Expenses","tb_row":287},{"code":"TB0288","name":"Royalty Charges @ 18%","type":"EXPENSE","parent_code":"TB0280","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"Travelling and Conveyance > Royalty Charges @ 18%","tb_row":288},{"code":"TB0289","name":"23. Employee Benefits Expenses","type":"EXPENSE","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses","tb_row":289},{"code":"TB0290","name":"Salaries, Wages and Bonus","type":"EXPENSE","parent_code":"TB0289","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Salaries, Wages and Bonus","tb_row":290},{"code":"TB0291","name":"Basic Pay and DA","type":"EXPENSE","parent_code":"TB0290","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Salaries, Wages and Bonus > Basic Pay and DA","tb_row":291},{"code":"TB0292","name":"Conveyance Allowance","type":"EXPENSE","parent_code":"TB0291","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Salaries, Wages and Bonus > Basic Pay and DA > Conveyance Allowance","tb_row":292},{"code":"TB0293","name":"HRA","type":"EXPENSE","parent_code":"TB0289","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > HRA","tb_row":293},{"code":"TB0294","name":"National Holidays & Festival Holidays","type":"EXPENSE","parent_code":"TB0293","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > HRA > National Holidays & Festival Holidays","tb_row":294},{"code":"TB0295","name":"Sales Commission","type":"EXPENSE","parent_code":"TB0293","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > HRA > Sales Commission","tb_row":295},{"code":"TB0296","name":"Washing Allowance","type":"EXPENSE","parent_code":"TB0293","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > HRA > Washing Allowance","tb_row":296},{"code":"TB0297","name":"Contribution to Provident and Other Funds","type":"EXPENSE","parent_code":"TB0289","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Contribution to Provident and Other Funds","tb_row":297},{"code":"TB0298","name":"EPF Contribution (Employer)","type":"EXPENSE","parent_code":"TB0297","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Contribution to Provident and Other Funds > EPF Contribution (Employer)","tb_row":298},{"code":"TB0299","name":"ESI Contribution (Employer)","type":"EXPENSE","parent_code":"TB0297","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Contribution to Provident and Other Funds > ESI Contribution (Employer)","tb_row":299},{"code":"TB0300","name":"Staff Welfare Expenses","type":"EXPENSE","parent_code":"TB0289","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Staff Welfare Expenses","tb_row":300},{"code":"TB0301","name":"Canteen Expenses","type":"EXPENSE","parent_code":"TB0300","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Staff Welfare Expenses > Canteen Expenses","tb_row":301},{"code":"TB0302","name":"Canteen Expenses @ 18%","type":"EXPENSE","parent_code":"TB0301","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Staff Welfare Expenses > Canteen Expenses > Canteen Expenses @ 18%","tb_row":302},{"code":"TB0303","name":"Canteen Expenses @ 5%","type":"EXPENSE","parent_code":"TB0301","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Staff Welfare Expenses > Canteen Expenses > Canteen Expenses @ 5%","tb_row":303},{"code":"TB0304","name":"Canteen Expenses - Exempted","type":"EXPENSE","parent_code":"TB0301","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Staff Welfare Expenses > Canteen Expenses > Canteen Expenses - Exempted","tb_row":304},{"code":"TB0305","name":"Gift Coupon","type":"EXPENSE","parent_code":"TB0300","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Staff Welfare Expenses > Gift Coupon","tb_row":305},{"code":"TB0306","name":"Staff Uniform Expenses","type":"EXPENSE","parent_code":"TB0305","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Staff Welfare Expenses > Gift Coupon > Staff Uniform Expenses","tb_row":306},{"code":"TB0307","name":"Staff Uniform Expenses @ 18%","type":"EXPENSE","parent_code":"TB0305","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Staff Welfare Expenses > Gift Coupon > Staff Uniform Expenses @ 18%","tb_row":307},{"code":"TB0308","name":"Staff Uniform Expenses @ 5%","type":"EXPENSE","parent_code":"TB0305","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Staff Welfare Expenses > Gift Coupon > Staff Uniform Expenses @ 5%","tb_row":308},{"code":"TB0309","name":"Staff Welfare Expenses","type":"EXPENSE","parent_code":"TB0305","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Staff Welfare Expenses > Gift Coupon > Staff Welfare Expenses","tb_row":309},{"code":"TB0310","name":"Staff Welfare Expenses @ 18%","type":"EXPENSE","parent_code":"TB0305","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Staff Welfare Expenses > Gift Coupon > Staff Welfare Expenses @ 18%","tb_row":310},{"code":"TB0311","name":"Staff Welfare Expenses @ 5%","type":"EXPENSE","parent_code":"TB0305","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"23. Employee Benefits Expenses > Staff Welfare Expenses > Gift Coupon > Staff Welfare Expenses @ 5%","tb_row":311},{"code":"TB0312","name":"Staff Welfare Expenses @ 5% (Interstate)","type":"EXPENSE","parent_code":"TB0305","is_group":"N","gst_rate":5.0,"interstate":1,"rcm":0,"path":"23. Employee Benefits Expenses > Staff Welfare Expenses > Gift Coupon > Staff Welfare Expenses @ 5% (Interstate)","tb_row":312},{"code":"TB0313","name":"24. Finance Costs","type":"EXPENSE","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"24. Finance Costs","tb_row":313},{"code":"TB0314","name":"Bank Interest Paid","type":"EXPENSE","parent_code":"TB0313","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"24. Finance Costs > Bank Interest Paid","tb_row":314},{"code":"TB0316","name":"26. Other Expenses Selling & Admin Exp","type":"EXPENSE","parent_code":null,"is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp","tb_row":316},{"code":"TB0317","name":"Freight and Forwarding","type":"EXPENSE","parent_code":"TB0316","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Freight and Forwarding","tb_row":317},{"code":"TB0318","name":"Freight Charges","type":"EXPENSE","parent_code":"TB0317","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Freight and Forwarding > Freight Charges","tb_row":318},{"code":"TB0319","name":"Freight Charges @ 12%","type":"EXPENSE","parent_code":"TB0318","is_group":"N","gst_rate":12.0,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Freight and Forwarding > Freight Charges > Freight Charges @ 12%","tb_row":319},{"code":"TB0320","name":"Freight Charges @ 18%","type":"EXPENSE","parent_code":"TB0318","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Freight and Forwarding > Freight Charges > Freight Charges @ 18%","tb_row":320},{"code":"TB0321","name":"Freight Charges @ 18% Interstate","type":"EXPENSE","parent_code":"TB0318","is_group":"N","gst_rate":18.0,"interstate":1,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Freight and Forwarding > Freight Charges > Freight Charges @ 18% Interstate","tb_row":321},{"code":"TB0322","name":"Freight Charges @ 5%","type":"EXPENSE","parent_code":"TB0318","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Freight and Forwarding > Freight Charges > Freight Charges @ 5%","tb_row":322},{"code":"TB0323","name":"Freight Charges @ 5% Interstate","type":"EXPENSE","parent_code":"TB0318","is_group":"N","gst_rate":5.0,"interstate":1,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Freight and Forwarding > Freight Charges > Freight Charges @ 5% Interstate","tb_row":323},{"code":"TB0324","name":"Freight Charges @ 5% - RCM","type":"EXPENSE","parent_code":"TB0318","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":1,"path":"26. Other Expenses Selling & Admin Exp > Freight and Forwarding > Freight Charges > Freight Charges @ 5% - RCM","tb_row":324},{"code":"TB0325","name":"Freight -Reverse Charges @ 5% Interstate RCM","type":"EXPENSE","parent_code":"TB0318","is_group":"N","gst_rate":5.0,"interstate":1,"rcm":1,"path":"26. Other Expenses Selling & Admin Exp > Freight and Forwarding > Freight Charges > Freight -Reverse Charges @ 5% Interstate RCM","tb_row":325},{"code":"TB0326","name":"Transport Charges","type":"EXPENSE","parent_code":"TB0317","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Freight and Forwarding > Transport Charges","tb_row":326},{"code":"TB0327","name":"Miscellaneous Expenses","type":"EXPENSE","parent_code":"TB0316","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Miscellaneous Expenses","tb_row":327},{"code":"TB0328","name":"Excess / Short","type":"EXPENSE","parent_code":"TB0327","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Miscellaneous Expenses > Excess / Short","tb_row":328},{"code":"TB0329","name":"Rounded Off (Round Off)","type":"EXPENSE","parent_code":"TB0328","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Miscellaneous Expenses > Excess / Short > Rounded Off (Round Off)","tb_row":329},{"code":"TB0330","name":"Office Maintenance","type":"EXPENSE","parent_code":"TB0316","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance","tb_row":330},{"code":"TB0331","name":"House Keeping & Maintenance","type":"EXPENSE","parent_code":"TB0330","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > House Keeping & Maintenance","tb_row":331},{"code":"TB0332","name":"House Keeping & Maintenance @ 18%","type":"EXPENSE","parent_code":"TB0331","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > House Keeping & Maintenance > House Keeping & Maintenance @ 18%","tb_row":332},{"code":"TB0333","name":"House Keeping & Maintenance @ 5%","type":"EXPENSE","parent_code":"TB0331","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > House Keeping & Maintenance > House Keeping & Maintenance @ 5%","tb_row":333},{"code":"TB0334","name":"House Keeping & Maintenance Exempted","type":"EXPENSE","parent_code":"TB0331","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > House Keeping & Maintenance > House Keeping & Maintenance Exempted","tb_row":334},{"code":"TB0335","name":"Office Maintenance - Others","type":"EXPENSE","parent_code":"TB0330","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > Office Maintenance - Others","tb_row":335},{"code":"TB0336","name":"Office Maintenance","type":"EXPENSE","parent_code":"TB0335","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > Office Maintenance - Others > Office Maintenance","tb_row":336},{"code":"TB0337","name":"Office Maintenance @ 18%","type":"EXPENSE","parent_code":"TB0335","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > Office Maintenance - Others > Office Maintenance @ 18%","tb_row":337},{"code":"TB0338","name":"Office Maintenance Exempted","type":"EXPENSE","parent_code":"TB0335","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > Office Maintenance - Others > Office Maintenance Exempted","tb_row":338},{"code":"TB0339","name":"Pooja Expenses","type":"EXPENSE","parent_code":"TB0330","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > Pooja Expenses","tb_row":339},{"code":"TB0340","name":"Pooja Expenses","type":"EXPENSE","parent_code":"TB0339","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > Pooja Expenses > Pooja Expenses","tb_row":340},{"code":"TB0341","name":"Shop Expenses","type":"EXPENSE","parent_code":"TB0330","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > Shop Expenses","tb_row":341},{"code":"TB0342","name":"Mobile Purchase Expenses @ 18%","type":"EXPENSE","parent_code":"TB0341","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > Shop Expenses > Mobile Purchase Expenses @ 18%","tb_row":342},{"code":"TB0343","name":"Shop Expenses","type":"EXPENSE","parent_code":"TB0341","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > Shop Expenses > Shop Expenses","tb_row":343},{"code":"TB0344","name":"Shop Expenses @ 12%","type":"EXPENSE","parent_code":"TB0343","is_group":"N","gst_rate":12.0,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > Shop Expenses > Shop Expenses > Shop Expenses @ 12%","tb_row":344},{"code":"TB0345","name":"Shop Expenses @ 18%","type":"EXPENSE","parent_code":"TB0343","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > Shop Expenses > Shop Expenses > Shop Expenses @ 18%","tb_row":345},{"code":"TB0346","name":"Shop Expenses @ 18% Interstate","type":"EXPENSE","parent_code":"TB0343","is_group":"N","gst_rate":18.0,"interstate":1,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > Shop Expenses > Shop Expenses > Shop Expenses @ 18% Interstate","tb_row":346},{"code":"TB0347","name":"Shop Expenses @ 5%","type":"EXPENSE","parent_code":"TB0343","is_group":"N","gst_rate":5.0,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > Shop Expenses > Shop Expenses > Shop Expenses @ 5%","tb_row":347},{"code":"TB0348","name":"Yoga Expenses Exempted","type":"EXPENSE","parent_code":"TB0343","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Office Maintenance > Shop Expenses > Shop Expenses > Yoga Expenses Exempted","tb_row":348},{"code":"TB0349","name":"Postage, Courier & Telegram","type":"EXPENSE","parent_code":"TB0316","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Postage, Courier & Telegram","tb_row":349},{"code":"TB0350","name":"Postage, Courier & Telegram @ 18%","type":"EXPENSE","parent_code":"TB0349","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Postage, Courier & Telegram > Postage, Courier & Telegram @ 18%","tb_row":350},{"code":"TB0351","name":"Insurance","type":"EXPENSE","parent_code":"TB0316","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Insurance","tb_row":351},{"code":"TB0352","name":"Insurance","type":"EXPENSE","parent_code":"TB0351","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Insurance > Insurance","tb_row":352},{"code":"TB0353","name":"Insurance @ 18%","type":"EXPENSE","parent_code":"TB0351","is_group":"N","gst_rate":18.0,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Insurance > Insurance @ 18%","tb_row":353},{"code":"TB0354","name":"Insurance @ 5% Interstate","type":"EXPENSE","parent_code":"TB0351","is_group":"N","gst_rate":5.0,"interstate":1,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Insurance > Insurance @ 5% Interstate","tb_row":354},{"code":"TB0355","name":"Legal and Professional Charges","type":"EXPENSE","parent_code":"TB0316","is_group":"Y","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Legal and Professional Charges","tb_row":355},{"code":"TB0356","name":"Professional Fees","type":"EXPENSE","parent_code":"TB0355","is_group":"N","gst_rate":null,"interstate":0,"rcm":0,"path":"26. Other Expenses Selling & Admin Exp > Legal and Professional Charges > Professional Fees","tb_row":356}]';
INSERT INTO dbo.acct_account_head (head_code, head_name, head_type, is_group, gst_rate, is_interstate, is_rcm, head_path, source, tb_row, created_by)
SELECT x.code, x.name, x.type, x.is_group, x.gst_rate, x.interstate, x.rcm, x.path, 'TB', x.tb_row, 'TrialBal.xlsx'
FROM OPENJSON(@j) WITH (code VARCHAR(20) '$.code', name NVARCHAR(240) '$.name', type VARCHAR(12) '$.type', is_group CHAR(1) '$.is_group',
                        gst_rate DECIMAL(5,2) '$.gst_rate', interstate BIT '$.interstate', rcm BIT '$.rcm', path NVARCHAR(600) '$.path', tb_row INT '$.tb_row') x
WHERE NOT EXISTS (SELECT 1 FROM dbo.acct_account_head h WHERE h.head_code = x.code);

UPDATE h SET parent_head_sno = p.head_sno
FROM dbo.acct_account_head h
JOIN OPENJSON(@j) WITH (code VARCHAR(20) '$.code', parent_code VARCHAR(20) '$.parent_code') x ON x.code = h.head_code
JOIN dbo.acct_account_head p ON p.head_code = x.parent_code
WHERE h.source = 'TB' AND h.parent_head_sno IS NULL AND x.parent_code IS NOT NULL;
GO

-- ── product -> account head ─────────────────────────────────────────────────
IF COL_LENGTH('dbo.product_master', 'account_head_sno') IS NULL ALTER TABLE dbo.product_master ADD account_head_sno INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_product_account_head')
    ALTER TABLE dbo.product_master ADD CONSTRAINT FK_product_account_head FOREIGN KEY (account_head_sno) REFERENCES dbo.acct_account_head (head_sno);
GO

-- ── master procedures ───────────────────────────────────────────────────────
-- list for the master grid
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetAccountHeadRecords
AS
BEGIN
    SET NOCOUNT ON;
    SELECT h.head_sno, h.head_code, h.head_name, h.head_type, h.parent_head_sno, p.head_name AS parent_name, h.head_path,
           h.is_group, h.gst_rate, h.is_interstate, h.is_rcm, h.source, h.is_active,
           (SELECT COUNT(*) FROM dbo.product_master pm WHERE pm.account_head_sno = h.head_sno AND pm.prod_active = 'Y') AS product_count
    FROM dbo.acct_account_head h
    LEFT JOIN dbo.acct_account_head p ON p.head_sno = h.parent_head_sno
    WHERE h.is_active = 'Y'
    ORDER BY CASE h.head_type WHEN 'ASSET' THEN 1 WHEN 'LIABILITY' THEN 2 WHEN 'INCOME' THEN 3 WHEN 'EXPENSE' THEN 4 ELSE 5 END, ISNULL(h.tb_row, 100000 + h.head_sno), h.head_sno;
END
GO

-- picker for the Product master: postable ledgers (not groups) that can carry stock / expense
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetAccountLedgerOptions
AS
BEGIN
    SET NOCOUNT ON;
    SELECT h.head_sno, h.head_code, h.head_type,
           h.head_name + CASE WHEN p.head_name IS NOT NULL THEN N'  (' + p.head_name + N')' ELSE N'' END AS head_label
    FROM dbo.acct_account_head h
    LEFT JOIN dbo.acct_account_head p ON p.head_sno = h.parent_head_sno
    WHERE h.is_active = 'Y' AND h.is_group = 'N' AND h.head_type IN ('ASSET', 'EXPENSE')
      AND ISNULL(h.system_key, '') NOT IN ('SUSPENSE', 'BANK', 'ADVANCE_SUPPLIER', 'INPUT_CGST', 'INPUT_SGST', 'INPUT_IGST')
    ORDER BY h.head_type DESC, h.head_name;
END
GO

-- { head_name, head_type, parent_head_sno?, is_group?, head_code?, gst_rate?, created_by }
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateAccountHeadRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 53801, N'Invalid JSON payload provided.', 1;
    DECLARE @name NVARCHAR(240) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.head_name'))), ''),
            @type VARCHAR(12) = UPPER(JSON_VALUE(@jsonInput, '$.head_type')),
            @parent INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.parent_head_sno') AS INT),
            @grp CHAR(1) = CASE WHEN UPPER(JSON_VALUE(@jsonInput, '$.is_group')) IN ('Y', '1', 'TRUE') THEN 'Y' ELSE 'N' END,
            @code VARCHAR(20) = NULLIF(UPPER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.head_code')))), ''),
            @rate DECIMAL(5,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.gst_rate') AS DECIMAL(5,2)),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.created_by');
    IF @name IS NULL OR @type IS NULL THROW 53802, N'head_name and head_type are required.', 1;
    IF @type NOT IN ('ASSET', 'LIABILITY', 'EXPENSE', 'INCOME', 'EQUITY') THROW 53803, N'head_type must be ASSET, LIABILITY, EXPENSE, INCOME or EQUITY.', 1;
    DECLARE @ppath NVARCHAR(600) = NULL;
    IF @parent IS NOT NULL
    BEGIN
        SELECT @ppath = head_path FROM dbo.acct_account_head WHERE head_sno = @parent AND is_active = 'Y' AND is_group = 'Y';
        IF @ppath IS NULL THROW 53804, N'The parent must be an active group.', 1;
    END
    IF EXISTS (SELECT 1 FROM dbo.acct_account_head WHERE is_active = 'Y' AND head_name = @name AND ISNULL(parent_head_sno, 0) = ISNULL(@parent, 0))
        THROW 53805, N'An account head with this name already exists under the same parent.', 1;
    IF @code IS NULL SET @code = 'AH' + RIGHT('00000' + CAST(ISNULL((SELECT MAX(head_sno) FROM dbo.acct_account_head), 0) + 1 AS VARCHAR(8)), 5);
    IF EXISTS (SELECT 1 FROM dbo.acct_account_head WHERE head_code = @code) THROW 53806, N'This account head code is already used.', 1;

    INSERT INTO dbo.acct_account_head (head_code, head_name, head_type, parent_head_sno, is_group, gst_rate, head_path, source, created_by)
    VALUES (@code, @name, @type, @parent, @grp, @rate, CASE WHEN @ppath IS NULL THEN @name ELSE @ppath + N' > ' + @name END, 'MANUAL', @by);
    SELECT SCOPE_IDENTITY() AS head_sno, @code AS head_code, N'SUCCESS' AS status, N'Account head created successfully.' AS message;
END
GO

-- { id | head_sno, head_name?, head_type?, parent_head_sno?, gst_rate?, modified_by }  (system heads keep their name/type)
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateAccountHeadRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.head_sno') AS INT);
    DECLARE @src VARCHAR(10), @oldtype VARCHAR(12), @oldname NVARCHAR(240), @oldparent INT, @oldpath NVARCHAR(600);
    SELECT @src = source, @oldtype = head_type, @oldname = head_name, @oldparent = parent_head_sno, @oldpath = head_path FROM dbo.acct_account_head WHERE head_sno = @id;
    IF @src IS NULL THROW 53810, N'Account head not found.', 1;

    DECLARE @name NVARCHAR(240) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.head_name'))), ''),
            @type VARCHAR(12) = UPPER(NULLIF(JSON_VALUE(@jsonInput, '$.head_type'), '')),
            @hasParent BIT = CASE WHEN EXISTS (SELECT 1 FROM OPENJSON(@jsonInput) WHERE [key] = 'parent_head_sno') THEN 1 ELSE 0 END,
            @parent INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.parent_head_sno') AS INT),
            @rate DECIMAL(5,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.gst_rate') AS DECIMAL(5,2)),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.modified_by');
    IF @src = 'SYSTEM' AND ((@type IS NOT NULL AND @type <> @oldtype) OR @hasParent = 1)
        THROW 53811, N'System account heads (used by the journals) cannot change type or parent.', 1;
    IF @type IS NOT NULL AND @type NOT IN ('ASSET', 'LIABILITY', 'EXPENSE', 'INCOME', 'EQUITY') THROW 53803, N'head_type must be ASSET, LIABILITY, EXPENSE, INCOME or EQUITY.', 1;

    DECLARE @newparent INT = CASE WHEN @hasParent = 1 THEN @parent ELSE @oldparent END, @ppath NVARCHAR(600) = NULL;
    IF @newparent IS NOT NULL
    BEGIN
        IF @newparent = @id THROW 53812, N'An account head cannot be its own parent.', 1;
        SELECT @ppath = head_path FROM dbo.acct_account_head WHERE head_sno = @newparent AND is_active = 'Y' AND is_group = 'Y';
        IF @ppath IS NULL THROW 53804, N'The parent must be an active group.', 1;
    END
    DECLARE @newname NVARCHAR(240) = ISNULL(@name, @oldname);
    IF EXISTS (SELECT 1 FROM dbo.acct_account_head WHERE is_active = 'Y' AND head_sno <> @id AND head_name = @newname AND ISNULL(parent_head_sno, 0) = ISNULL(@newparent, 0))
        THROW 53805, N'An account head with this name already exists under the same parent.', 1;

    UPDATE dbo.acct_account_head
    SET head_name = @newname, head_type = ISNULL(@type, head_type), parent_head_sno = @newparent,
        gst_rate = CASE WHEN EXISTS (SELECT 1 FROM OPENJSON(@jsonInput) WHERE [key] = 'gst_rate') THEN @rate ELSE gst_rate END,
        head_path = CASE WHEN @ppath IS NULL THEN @newname ELSE @ppath + N' > ' + @newname END,
        modified_by = @by, modified_at = GETDATE()
    WHERE head_sno = @id;
    SELECT * FROM dbo.acct_account_head WHERE head_sno = @id;
END
GO

-- soft delete; refused while the head is in use
CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteAccountHeadRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    DECLARE @src VARCHAR(10) = (SELECT source FROM dbo.acct_account_head WHERE head_sno = @id);
    IF @src IS NULL THROW 53810, N'Account head not found.', 1;
    IF @src = 'SYSTEM' THROW 53813, N'System account heads are used by the journals and cannot be deleted.', 1;
    IF EXISTS (SELECT 1 FROM dbo.acct_account_head WHERE parent_head_sno = @id AND is_active = 'Y') THROW 53814, N'This group still has heads under it.', 1;
    IF EXISTS (SELECT 1 FROM dbo.product_master WHERE account_head_sno = @id AND prod_active = 'Y')
        OR EXISTS (SELECT 1 FROM dbo.subcategory_master WHERE subcat_account_head_sno = @id)
        OR EXISTS (SELECT 1 FROM dbo.acct_journal_line WHERE head_sno = @id)
        THROW 53815, N'This account head is used by products or journal entries - re-assign them first.', 1;
    UPDATE dbo.acct_account_head SET is_active = 'N', modified_at = GETDATE() WHERE head_sno = @id;
    SELECT @id AS head_sno, 'N' AS is_active, 'SUCCESS' AS status;
END
GO

-- ── product procedures: carry account_head_sno ──────────────────────────────
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_CreateProductRecord]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    -- ───────────────────────────────────────────
    -- 1. Basic Input Validation
    -- ───────────────────────────────────────────
    IF @jsonInput IS NULL OR LTRIM(RTRIM(@jsonInput)) = ''
    BEGIN
        SELECT 'Failed' AS Status, 'JSON input is required' AS ErrorMessage;
        RETURN;
    END

    IF ISJSON(@jsonInput) = 0
    BEGIN
        SELECT 'Failed' AS Status, 'Invalid JSON format' AS ErrorMessage;
        RETURN;
    END

    -- ───────────────────────────────────────────
    -- 2. Normalize: wrap single object into array
    --    Handles both {} and [{}] inputs transparently
    -- ───────────────────────────────────────────
    DECLARE @normalizedJson NVARCHAR(MAX);

    SET @normalizedJson = CASE
        WHEN LEFT(LTRIM(@jsonInput), 1) = '{'
        THEN '[' + @jsonInput + ']'   -- single object → wrap as array
        ELSE @jsonInput               -- already an array
    END;

    -- Re-validate after normalization
    IF ISJSON(@normalizedJson) = 0
    BEGIN
        SELECT 'Failed' AS Status, 'Invalid JSON structure after normalization' AS ErrorMessage;
        RETURN;
    END

    BEGIN TRY

        -- ───────────────────────────────────────────
        -- 3. Parse JSON Array into Temp Table ONCE
        --    WITH clause = single parse pass (faster)
        --    ROW_NUMBER() used instead of [key]
        --    ([key] not available when WITH clause is used)
        -- ───────────────────────────────────────────
        CREATE TABLE #parsed_input (
            row_index            INT,
            company_sno          INT,
            division_sno         INT,
            branch_sno           INT,
            dept_sno             INT,
            cat_sno              INT,
            subcat_sno           INT,
            prod_name            VARCHAR(255),
            prod_description     VARCHAR(MAX),
            prod_notes           VARCHAR(MAX),
            hsn_code             VARCHAR(50),
            uom_sno              INT,
            tax_sno              INT,
            prod_uom_con_factor  DECIMAL(18,6),
            prod_uom_con_uom_sno INT,
            account_head_sno     INT,
            created_by           VARCHAR(50)
        );

        INSERT INTO #parsed_input
        SELECT
            ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1  AS row_index,
            company_sno,
            division_sno,
            branch_sno,
            dept_sno,
            cat_sno,
            subcat_sno,
            LTRIM(RTRIM(prod_name))                         AS prod_name,
            LTRIM(RTRIM(ISNULL(prod_description, '')))      AS prod_description,
            LTRIM(RTRIM(ISNULL(prod_notes, '')))            AS prod_notes,
            LTRIM(RTRIM(ISNULL(hsn_code, '')))              AS hsn_code,
            uom_sno,
            tax_sno,
            prod_uom_con_factor,
            prod_uom_con_uom_sno,
            account_head_sno,
            created_by
        FROM OPENJSON(@normalizedJson)
        WITH (
            company_sno          INT             '$.company_sno',
            division_sno         INT             '$.division_sno',
            branch_sno           INT             '$.branch_sno',
            dept_sno             INT             '$.dept_sno',
            cat_sno              INT             '$.cat_sno',
            subcat_sno           INT             '$.subcat_sno',
            prod_name            VARCHAR(255)    '$.prod_name',
            prod_description     VARCHAR(MAX)    '$.prod_description',
            prod_notes           VARCHAR(MAX)    '$.prod_notes',
            hsn_code             VARCHAR(50)     '$.hsn_code',
            uom_sno              INT             '$.uom_sno',
            tax_sno              INT             '$.tax_sno',
            prod_uom_con_factor  DECIMAL(18,6)   '$.prod_uom_con_factor',
            prod_uom_con_uom_sno INT             '$.prod_uom_con_uom_sno',
            account_head_sno     INT             '$.account_head_sno',
            created_by           VARCHAR(50)     '$.created_by'
        );

        -- ───────────────────────────────────────────
        -- 4. Row-Level Validation
        --    Collects ALL failures across ALL rows before aborting
        -- ───────────────────────────────────────────
        CREATE TABLE #validation_errors (
            row_index    INT,
            ErrorMessage VARCHAR(500)
        );

        INSERT INTO #validation_errors (row_index, ErrorMessage)
        SELECT row_index, 'cat_sno is required'
            FROM #parsed_input WHERE cat_sno IS NULL
        UNION ALL
        SELECT row_index, 'prod_name is required'
            FROM #parsed_input WHERE prod_name IS NULL OR prod_name = ''
        UNION ALL
        SELECT row_index, 'uom_sno is required'
            FROM #parsed_input WHERE uom_sno IS NULL;

        IF EXISTS (SELECT 1 FROM #validation_errors)
        BEGIN
            SELECT
                'Failed'   AS Status,
                row_index  AS RowIndex,
                ErrorMessage
            FROM #validation_errors
            ORDER BY row_index;

            DROP TABLE #parsed_input;
            DROP TABLE #validation_errors;
            RETURN;
        END

        DROP TABLE #validation_errors;

        -- ───────────────────────────────────────────
        -- 5. Validate All Categories Exist (set-based)
        -- ───────────────────────────────────────────
        IF EXISTS (
            SELECT 1
            FROM (SELECT DISTINCT cat_sno FROM #parsed_input) pi
            LEFT JOIN category_master cm ON cm.cat_sno = pi.cat_sno
            WHERE cm.cat_sno IS NULL
        )
        BEGIN
            SELECT
                'Failed'             AS Status,
                pi.cat_sno           AS InvalidCatSno,
                'Category not found' AS ErrorMessage
            FROM (SELECT DISTINCT cat_sno FROM #parsed_input) pi
            LEFT JOIN category_master cm ON cm.cat_sno = pi.cat_sno
            WHERE cm.cat_sno IS NULL;

            DROP TABLE #parsed_input;
            RETURN;
        END

        -- 5a. account head (optional): must be an active LEDGER (not a group) of type ASSET or EXPENSE
        IF EXISTS (
            SELECT 1 FROM #parsed_input pi
            WHERE pi.account_head_sno IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM acct_account_head h WHERE h.head_sno = pi.account_head_sno AND h.is_active = 'Y'
                              AND h.is_group = 'N' AND h.head_type IN ('ASSET', 'EXPENSE'))
        )
        BEGIN
            SELECT 'Failed' AS Status, pi.row_index AS RowIndex,
                   'account_head_sno must be an active Asset/Expense ledger (not a group)' AS ErrorMessage
            FROM #parsed_input pi
            WHERE pi.account_head_sno IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM acct_account_head h WHERE h.head_sno = pi.account_head_sno AND h.is_active = 'Y'
                              AND h.is_group = 'N' AND h.head_type IN ('ASSET', 'EXPENSE'));
            DROP TABLE #parsed_input;
            RETURN;
        END

        -- ───────────────────────────────────────────
        -- 5b. Validate product-specific UOM conversion factor + unit
        --     A non-base UOM with no fixed uom_master.uom_con_factor (e.g.
        --     Box, Tin) varies per product, so prod_uom_con_factor AND
        --     prod_uom_con_uom_sno must both be supplied. The chosen
        --     conversion unit must exist and belong to the SAME uom_class as
        --     the product's own uom_sno (a Tin's contents can only be
        --     expressed in a MASS unit, never a VOLUME/LENGTH one).
        -- ───────────────────────────────────────────
        IF EXISTS (
            SELECT 1
            FROM #parsed_input pi
            JOIN uom_master um ON um.uom_sno = pi.uom_sno
            WHERE um.uom_base_uom_flag = 'N'
              AND um.uom_con_factor IS NULL
              AND (pi.prod_uom_con_factor IS NULL OR pi.prod_uom_con_factor <= 0)
        )
        BEGIN
            SELECT
                'Failed'                                                    AS Status,
                pi.row_index                                                AS RowIndex,
                'prod_uom_con_factor is required for unit ' + um.uom_name +
                    ' (its conversion is not fixed and varies per product)' AS ErrorMessage
            FROM #parsed_input pi
            JOIN uom_master um ON um.uom_sno = pi.uom_sno
            WHERE um.uom_base_uom_flag = 'N'
              AND um.uom_con_factor IS NULL
              AND (pi.prod_uom_con_factor IS NULL OR pi.prod_uom_con_factor <= 0);

            DROP TABLE #parsed_input;
            RETURN;
        END

        IF EXISTS (
            SELECT 1
            FROM #parsed_input pi
            JOIN uom_master um ON um.uom_sno = pi.uom_sno
            WHERE um.uom_base_uom_flag = 'N'
              AND um.uom_con_factor IS NULL
              AND pi.prod_uom_con_uom_sno IS NULL
        )
        BEGIN
            SELECT
                'Failed'                                                    AS Status,
                pi.row_index                                                AS RowIndex,
                'prod_uom_con_uom_sno is required for unit ' + um.uom_name +
                    ' (choose the unit the quantity above is expressed in)' AS ErrorMessage
            FROM #parsed_input pi
            JOIN uom_master um ON um.uom_sno = pi.uom_sno
            WHERE um.uom_base_uom_flag = 'N'
              AND um.uom_con_factor IS NULL
              AND pi.prod_uom_con_uom_sno IS NULL;

            DROP TABLE #parsed_input;
            RETURN;
        END

        IF EXISTS (
            SELECT 1
            FROM #parsed_input pi
            JOIN uom_master um    ON um.uom_sno = pi.uom_sno
            LEFT JOIN uom_master cu ON cu.uom_sno = pi.prod_uom_con_uom_sno
            WHERE pi.prod_uom_con_uom_sno IS NOT NULL
              AND (cu.uom_sno IS NULL OR cu.uom_class <> um.uom_class)
        )
        BEGIN
            SELECT
                'Failed'                                                        AS Status,
                pi.row_index                                                    AS RowIndex,
                'prod_uom_con_uom_sno must be a valid unit of the same class (' +
                    um.uom_class + ') as ' + um.uom_name                        AS ErrorMessage
            FROM #parsed_input pi
            JOIN uom_master um    ON um.uom_sno = pi.uom_sno
            LEFT JOIN uom_master cu ON cu.uom_sno = pi.prod_uom_con_uom_sno
            WHERE pi.prod_uom_con_uom_sno IS NOT NULL
              AND (cu.uom_sno IS NULL OR cu.uom_class <> um.uom_class);

            DROP TABLE #parsed_input;
            RETURN;
        END

        -- ───────────────────────────────────────────
        -- 6. Generate Product Codes — set-based per category
        --    MAX existing seq fetched once per category (with lock)
        --    ROW_NUMBER() per cat assigns each new row its offset
        -- ───────────────────────────────────────────
        CREATE TABLE #products_with_code (
            row_index            INT,
            company_sno          INT,
            division_sno         INT,
            branch_sno           INT,
            dept_sno             INT,
            cat_sno              INT,
            subcat_sno           INT,
            prod_name            VARCHAR(255),
            prod_description     VARCHAR(MAX),
            prod_notes           VARCHAR(MAX),
            prod_code            VARCHAR(50),
            hsn_code             VARCHAR(50),
            uom_sno              INT,
            tax_sno              INT,
            prod_uom_con_factor  DECIMAL(18,6),
            prod_uom_con_uom_sno INT,
            account_head_sno     INT,
            created_by           VARCHAR(50)
        );

        ;WITH CategoryPrefix AS (
            SELECT
                cm.cat_sno,
                cm.cat_notes AS cat_prefix,
                ISNULL(MAX(
                    CASE
                        WHEN ISNUMERIC(
                            SUBSTRING(pm.prod_code, LEN(cm.cat_notes) + 1, LEN(pm.prod_code))
                        ) = 1
                        THEN CAST(
                            SUBSTRING(pm.prod_code, LEN(cm.cat_notes) + 1, LEN(pm.prod_code))
                        AS INT)
                        ELSE 0
                    END
                ), 0) AS max_seq
            FROM (SELECT DISTINCT cat_sno FROM #parsed_input) pi
            JOIN category_master cm ON cm.cat_sno = pi.cat_sno
            LEFT JOIN product_master pm WITH (UPDLOCK, ROWLOCK)
                ON  pm.cat_sno   = cm.cat_sno
                AND pm.prod_code LIKE cm.cat_notes + '%'
            GROUP BY cm.cat_sno, cm.cat_notes
        ),
        RankedRows AS (
            SELECT
                pi.*,
                cp.cat_prefix,
                cp.max_seq,
                ROW_NUMBER() OVER (
                    PARTITION BY pi.cat_sno
                    ORDER BY pi.row_index
                ) AS rn
            FROM #parsed_input pi
            JOIN CategoryPrefix cp ON cp.cat_sno = pi.cat_sno
        )
        INSERT INTO #products_with_code
        SELECT
            row_index,
            company_sno,
            division_sno,
            branch_sno,
            dept_sno,
            cat_sno,
            subcat_sno,
            prod_name,
            prod_description,
            prod_notes,
            cat_prefix + RIGHT('00000' + CAST((max_seq + rn) AS VARCHAR(5)), 5) AS prod_code,
            hsn_code,
            uom_sno,
            tax_sno,
            prod_uom_con_factor,
            prod_uom_con_uom_sno,
            account_head_sno,
            created_by
        FROM RankedRows;

        DROP TABLE #parsed_input;

        -- ───────────────────────────────────────────
        -- 7. Bulk Insert with OUTPUT clause
        --    All prod_sno values captured safely — no SCOPE_IDENTITY() race
        -- ───────────────────────────────────────────
        CREATE TABLE #inserted_results (
            prod_sno  INT,
            prod_code VARCHAR(50)
        );

        BEGIN TRANSACTION;

            INSERT INTO [dbo].[product_master] (
                company_sno,
                division_sno,
                branch_sno,
                dept_sno,
                cat_sno,
                subcat_sno,
                prod_name,
                prod_description,
                prod_notes,
                prod_code,
                uom_sno,
                tax_sno,
                prod_hsn_code,
                prod_uom_con_factor,
                prod_uom_con_uom_sno,
                account_head_sno,
                prod_active,
                prod_created_date,
                prod_created_by
            )
            OUTPUT
                INSERTED.prod_sno,
                INSERTED.prod_code
            INTO #inserted_results (prod_sno, prod_code)
            SELECT
                company_sno,
                division_sno,
                branch_sno,
                dept_sno,
                cat_sno,
                subcat_sno,
                prod_name,
                prod_description,
                prod_notes,
                prod_code,
                uom_sno,
                tax_sno,
                hsn_code             AS prod_hsn_code,
                prod_uom_con_factor,
                prod_uom_con_uom_sno,
                account_head_sno,
                'Y'                  AS prod_active,
                GETDATE()            AS prod_created_date,
                created_by           AS prod_created_by
            FROM #products_with_code
            ORDER BY row_index;

        COMMIT TRANSACTION;

        -- ───────────────────────────────────────────
        -- 8. Return Results — joined via prod_code
        -- ───────────────────────────────────────────
        SELECT
            'Success'                       AS Status,
            'Product inserted successfully' AS Message,
            ir.prod_sno,
            ir.prod_code,
            pwc.prod_name,
            pwc.cat_sno,
            pwc.row_index                   AS InputRowIndex
        FROM #inserted_results ir
        JOIN #products_with_code pwc ON pwc.prod_code = ir.prod_code
        ORDER BY pwc.row_index;

        DROP TABLE #products_with_code;
        DROP TABLE #inserted_results;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        IF OBJECT_ID('tempdb..#parsed_input')       IS NOT NULL DROP TABLE #parsed_input;
        IF OBJECT_ID('tempdb..#validation_errors')  IS NOT NULL DROP TABLE #validation_errors;
        IF OBJECT_ID('tempdb..#products_with_code') IS NOT NULL DROP TABLE #products_with_code;
        IF OBJECT_ID('tempdb..#inserted_results')   IS NOT NULL DROP TABLE #inserted_results;

        SELECT
            'Failed'        AS Status,
            ERROR_MESSAGE() AS ErrorMessage,
            ERROR_NUMBER()  AS ErrorNumber,
            ERROR_LINE()    AS ErrorLine;
    END CATCH
END
GO


-- ============================================================================
-- ProductMaster (product_master: prod_sno PK, prod_active). Create SP
-- (sp_nt_CreateProductRecord) is already bulk-safe and untouched â€” only
-- Update/Delete are new. Category/product-code regeneration on category
-- change is intentionally out of scope; Update only touches the columns the
-- Edit form actually exposes.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateProductRecord
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.prod_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.product_master WHERE prod_sno = @id)
    BEGIN
        RAISERROR('Product not found.', 16, 1);
        RETURN;
    END

    IF TRY_CAST(JSON_VALUE(@jsonInput, '$.account_head_sno') AS INT) IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.acct_account_head h WHERE h.head_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.account_head_sno') AS INT)
                       AND h.is_active = 'Y' AND h.is_group = 'N' AND h.head_type IN ('ASSET', 'EXPENSE'))
    BEGIN
        RAISERROR('Account head must be an active Asset/Expense ledger (not a group).', 16, 1);
        RETURN;
    END

    UPDATE dbo.product_master
    SET cat_sno              = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.cat_sno') AS INT), cat_sno),
        subcat_sno           = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.subcat_sno') AS INT), subcat_sno),
        prod_name            = ISNULL(JSON_VALUE(@jsonInput, '$.prod_name'), prod_name),
        prod_description     = ISNULL(JSON_VALUE(@jsonInput, '$.prod_description'), prod_description),
        prod_hsn_code        = ISNULL(JSON_VALUE(@jsonInput, '$.hsn_code'), prod_hsn_code),
        uom_sno              = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.uom_sno') AS INT), uom_sno),
        prod_uom_con_factor  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.prod_uom_con_factor') AS DECIMAL(18,6)), prod_uom_con_factor),
        prod_uom_con_uom_sno = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.prod_uom_con_uom_sno') AS INT), prod_uom_con_uom_sno),
        account_head_sno     = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.account_head_sno') AS INT), account_head_sno),
        prod_modified_date   = GETDATE(),
        prod_modified_by     = JSON_VALUE(@jsonInput, '$.modified_by')
    WHERE prod_sno = @id;

    SELECT * FROM dbo.product_master WHERE prod_sno = @id;
END
GO
CREATE OR ALTER PROCEDURE [dbo].[sp_nt_GetProductRecords]
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        -- NOTE: must NOT use a bare `SELECT *` here — uom_master is joined
        -- twice (um for the purchase UOM, cuom for the conversion unit), and
        -- node-mssql silently collapses same-named duplicate columns
        -- (uom_name, uom_code, uom_class, ...) into arrays rather than erroring,
        -- which would corrupt every existing consumer expecting a plain string.
        -- pm.*/cm.*/scm.*/um.* reproduces exactly what the old bare `SELECT *`
        -- returned (same 4 tables, no cuom.* mixed in); only the two aliased
        -- cuom columns are new.
        SELECT pm.*, cm.*, scm.*, um.*,
               cuom.uom_name AS con_uom_name,
               cuom.uom_code AS con_uom_code,
               ah.head_name  AS account_head_name,
               ah.head_path  AS account_head_path
        FROM product_master pm
        INNER JOIN category_master cm ON pm.cat_sno = cm.cat_sno
        INNER JOIN subcategory_master scm ON scm.subcat_sno = pm.subcat_sno
        INNER JOIN uom_master um ON um.uom_sno = pm.uom_sno
        LEFT JOIN uom_master cuom ON cuom.uom_sno = pm.prod_uom_con_uom_sno
        LEFT JOIN acct_account_head ah ON ah.head_sno = pm.account_head_sno
        WHERE prod_active = 'Y'
        ORDER BY prod_sno;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO


-- ── first mapping of the Dev products (best guesses - Accounts to confirm on the Product master) ──
-- Test products are left blank on purpose.
;WITH m(prod_sno, code) AS (
    SELECT p.prod_sno, x.code FROM dbo.product_master p
    JOIN (VALUES
        (22,'TB0200'),(23,'TB0200'),(26,'TB0200'),(27,'TB0200'),(28,'TB0200'),(30,'TB0200'),   -- pencils  -> Printing & Stationery (Office)
        (31,'TB0304'),(32,'TB0304'),(33,'TB0304'),                                           -- vegetables -> Canteen Expenses - Exempted
        (1,'TB0210'),(2,'TB0210'),(3,'TB0210'),(4,'TB0210'),(5,'TB0210'),                    -- chit gift items -> Sales Promotion Expenses
        (24,'TB0083'),                                                                       -- laptop -> Computer & IT Accessories @ 18%
        (25,'TB0071')                                                                        -- mobile -> Mobile Purchase @ 18%
    ) x(prod_sno, code) ON x.prod_sno = p.prod_sno
)
UPDATE p SET account_head_sno = h.head_sno
FROM dbo.product_master p JOIN m ON m.prod_sno = p.prod_sno JOIN dbo.acct_account_head h ON h.head_code = m.code
WHERE p.account_head_sno IS NULL;
GO
