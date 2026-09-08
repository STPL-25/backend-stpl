-- ============================================================
-- sp_nt_GetAllServicePOs v2 — add po_pdf_url to the SELECT
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Why this is needed
-- ------------------
-- Recurring Service POs (auto-issued off an approved Fixed/Variable
-- Recurring Service Agreement, po_type='RECURRING') were never shown
-- anywhere in the frontend — ServiceAgreementListPage.tsx's "Vendor Driven"
-- tab is the only screen that consumes this proc, and it filters down to
-- service_type_code='VENDOR_BILL' only. Adding a "Recurring POs" tab there
-- needs a link to the actual PO document, which this proc didn't return —
-- everything else it needs (items, amount, status, vendor) was already here.
-- Byte-for-byte identical to the version in 07_po_service_extensions.sql
-- otherwise.
-- ============================================================

IF OBJECT_ID('dbo.sp_nt_GetAllServicePOs', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetAllServicePOs;
GO
CREATE PROCEDURE dbo.sp_nt_GetAllServicePOs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = NULL, @vendor_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @status = JSON_VALUE(@jsonInput, '$.status');
        SET @vendor_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    END

    SELECT
        p.po_basic_sno,
        p.po_df_no        AS po_no,
        p.pr_basic_sno,
        pr.pr_no,
        p.vendor_sno,
        k.company_name    AS vendor_name,
        p.po_type,
        st.service_type_code,
        st.service_type_name,
        p.validity_from,
        p.validity_to,
        p.ceiling_amount,
        p.consumed_amount,
        p.status,
        p.po_pdf_url,
        (
            SELECT
                pid.po_item_sno, pid.service_sno, sm.service_name,
                pid.qty, pid.unit_name, pid.agreed_unit_price, pid.net_cost, pid.po_section
            FROM dbo.po_item_details pid
            LEFT JOIN dbo.service_master sm ON sm.service_sno = pid.service_sno
            WHERE pid.po_basic_sno = p.po_basic_sno AND pid.is_active = '1'
            FOR JSON PATH
        ) AS items
    FROM dbo.po_request_info p
    LEFT JOIN dbo.service_type_master st ON st.service_type_sno = p.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k        ON k.kyc_basic_info_sno = p.vendor_sno
    LEFT JOIN dbo.pr_basic_info pr        ON pr.pr_basic_sno = p.pr_basic_sno
    WHERE p.service_type_sno IS NOT NULL
      AND (@status IS NULL OR p.status = @status)
      AND (@vendor_sno IS NULL OR p.vendor_sno = @vendor_sno)
    ORDER BY p.po_basic_sno DESC;
END;
GO

-- ============================================================
-- After running, confirm:
--   EXEC dbo.sp_nt_GetAllServicePOs;
--   -- po_pdf_url should now be present in the result set.
-- ============================================================
