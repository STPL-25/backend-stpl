-- DEV TEST DATA (Non_trade_Dev only): give every KYC that has no bank row a
-- primary bank account. Re-runnable: skips KYCs that already have one.
-- Account numbers are fictitious (9-digit, derived from the KYC id).
-- (kyc_address_sno is kyc_bank_info's own identity key, despite the name.)
DECLARE @banks TABLE (n INT, bank NVARCHAR(100), ifsc NVARCHAR(100), branch NVARCHAR(100), addr VARCHAR(300), pin NVARCHAR(20));
INSERT @banks VALUES
 (0,N'HDFC BANK LIMITED',N'HDFC0000240',N'COIMBATORE RS PURAM',  'RS PURAM, COIMBATORE',N'641002'),
 (1,N'STATE BANK OF INDIA',N'SBIN0000841',N'COIMBATORE MAIN',     'BIG BAZAAR STREET, COIMBATORE',N'641001'),
 (2,N'ICICI BANK LIMITED',N'ICIC0000052',N'COIMBATORE',           'AVINASHI ROAD, COIMBATORE',N'641018'),
 (3,N'AXIS BANK LIMITED',N'UTIB0000012',N'COIMBATORE TRICHY ROAD','TRICHY ROAD, COIMBATORE',N'641018'),
 (4,N'KOTAK MAHINDRA BANK LIMITED',N'KKBK0000961',N'KALBADEVI',   'KALBADEVI ROAD, MUMBAI',N'400002');

INSERT kyc_bank_info (kyc_basic_info_sno, ac_holder_name, ac_number, ac_type, ifsc,
                      bank_name, bank_branch_name, bank_address, pincode, is_primary, created_date, is_active, status)
SELECT b.kyc_basic_info_sno,
       UPPER(ISNULL(b.company_name, N'KYC ' + CAST(b.kyc_basic_info_sno AS NVARCHAR(10)))),
       CAST(500000000 + b.kyc_basic_info_sno * 1117 AS BIGINT),
       N'2', k.ifsc, k.bank, k.branch, k.addr, k.pin, 'Y', GETDATE(), 'Y', 'P'
FROM kyc_basic_info b
JOIN @banks k ON k.n = b.kyc_basic_info_sno % 5
WHERE NOT EXISTS (SELECT 1 FROM kyc_bank_info x WHERE x.kyc_basic_info_sno = b.kyc_basic_info_sno);

SELECT COUNT(*) AS kycs_without_bank FROM kyc_basic_info b
WHERE NOT EXISTS (SELECT 1 FROM kyc_bank_info x WHERE x.kyc_basic_info_sno = b.kyc_basic_info_sno);
