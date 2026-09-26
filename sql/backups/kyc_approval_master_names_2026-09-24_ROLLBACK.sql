-- Rollback for sql/95_kyc_approval_master_names.sql
-- Restores sp_get_kyc_approval to its definition on 2026-09-24 (identical on Non_Trade and
-- Non_trade_Dev): a bare SELECT * over vw_get_all_kyc_info for the approver's pending rows.

CREATE OR ALTER PROCEDURE dbo.sp_get_kyc_approval
    @Ecno VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NULLIF(LTRIM(RTRIM(@Ecno)), '') IS NULL
            THROW 50001, 'Ecno cannot be null or empty.', 1;

        SELECT *
        FROM vw_get_all_kyc_info
        WHERE approver_ecno = @Ecno
          AND status = 'P';
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        THROW;
    END CATCH
END
GO
