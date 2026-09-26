-- ============================================================
-- KYC Approval screen: show Business Type / Account Type NAMES, not master ids.
-- Database: Non_Trade + Non_trade_Dev (MSSQL)
--
-- Problem (reported 2026-09-24): on the KYC Approval screen "Business Type"
-- showed "2" / "4" / "6" and the bank "Account Type" showed "1" / "2".
--
-- Cause: the KYC entry form stores the SELECTED MASTER ID in
--   kyc_basic_info.business_type   -> business_types.business_types_id
--   kyc_bank_info.ac_type          -> bank_account_type_master.bank_account_type_sno
-- (both NVARCHAR(50) columns, so the id is held as text), and
-- sp_get_kyc_approval was a bare SELECT * over vw_get_all_kyc_info, which
-- returns those columns untouched. Nothing on the way to the screen ever
-- joined the two masters.
--
-- Fix: resolve both in sp_get_kyc_approval, ADDITIVELY:
--   * new column  business_type_name          (business_type itself stays the raw id)
--   * new key     ac_type_name inside the kyc_bank_info JSON  (ac_type stays the raw id)
-- Everything else in the result set is unchanged, so nothing reading the old
-- fields can break.
--
-- Why the SP and not the view: vw_get_all_kyc_info is shared with
-- sp_nt_ApproveSupplierQuotation / sp_nt_GetQuotationsForApproval (and
-- sp_nt_ApproveServicePoCycle on Dev). Adding a column there would change the
-- shape their SELECT * consumers see; scoping the change to this one SP does not.
--
-- Legacy rows: Non_trade_Dev still has free-text values from before the masters
-- ("current", "SAVINGS", "Proprietorship" ...). TRY_CONVERT(INT, ...) is NULL for
-- those, the LEFT JOIN finds nothing, and COALESCE falls back to the stored text,
-- so they keep displaying as they always did. An empty value stays empty.
-- Inactive master rows are still resolved (a KYC submitted while a type was
-- active must not lose its label).
--
-- A temp table is used only so the existing column name `kyc_bank_info` can be
-- overwritten in place (SELECT v.*, <new JSON> AS kyc_bank_info would return the
-- name twice and node-mssql collapses duplicate column names into an array).
--
-- Re-runnable (CREATE OR ALTER). Rollback:
-- backups/kyc_approval_master_names_2026-09-24_ROLLBACK.sql
-- ============================================================

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
