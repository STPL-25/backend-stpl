-- 110: sp_get_kyc_approval - fix truncation of #kyc.kyc_bank_info (widen to NVARCHAR(MAX)). Re-runnable.

CREATE OR ALTER PROCEDURE dbo.sp_get_kyc_approval
    @Ecno VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NULLIF(LTRIM(RTRIM(@Ecno)), '') IS NULL
            THROW 50001, 'Ecno cannot be null or empty.', 1;

        SELECT v.*,
               CAST(NULL AS NVARCHAR(200)) AS business_type_name
        INTO #kyc
        FROM dbo.vw_get_all_kyc_info v
        WHERE v.approver_ecno = @Ecno
          AND v.status = 'P';

        -- View column kyc_bank_info is fixed-width; long/multi-account JSON overflowed it (error 2628).
        ALTER TABLE #kyc ALTER COLUMN kyc_bank_info NVARCHAR(MAX) NULL;

        UPDATE k
        SET business_type_name = COALESCE(bt.business_types_name, NULLIF(LTRIM(RTRIM(k.business_type)), '')),
            kyc_bank_info = ISNULL((
                SELECT kbi.ac_holder_name, kbi.ac_number, kbi.ac_type,
                       COALESCE(bat.account_type_name, NULLIF(LTRIM(RTRIM(kbi.ac_type)), '')) AS ac_type_name,
                       kbi.ifsc, kbi.bank_name, kbi.bank_branch_name, kbi.bank_address, kbi.is_primary
                FROM dbo.kyc_bank_info kbi
                LEFT JOIN dbo.bank_account_type_master bat
                       ON bat.bank_account_type_sno = TRY_CONVERT(INT, kbi.ac_type)
                WHERE kbi.kyc_basic_info_sno = k.kyc_basic_info_sno
                FOR JSON PATH), '[]')
        FROM #kyc k
        LEFT JOIN dbo.business_types bt
               ON bt.business_types_id = TRY_CONVERT(INT, k.business_type);

        SELECT * FROM #kyc;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

GO
-- View column metadata goes stale whenever kyc_basic_info gains a column (see sql/101, sql/109): re-run after any such ALTER.
EXEC sp_refreshview 'dbo.vw_get_all_kyc_info';
GO
