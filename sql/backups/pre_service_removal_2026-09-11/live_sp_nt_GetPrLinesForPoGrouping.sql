CREATE PROCEDURE dbo.sp_nt_GetPrLinesForPoGrouping
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @pr_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.pr_basic_sno') AS INT);

    IF @pr_basic_sno IS NULL
    BEGIN
        RAISERROR('pr_basic_sno is required.', 16, 1);
        RETURN;
    END

    ;WITH pr_lines AS (
        SELECT
            pid.pr_item_sno,
            pid.item_type,
            pid.prod_sno,
            pm.prod_name,
            pid.service_sno,
            sm.service_name,
            pid.qty,
            pid.remarks,
            sq.vendor_sno,
            k.company_name AS vendor_name
        FROM dbo.pr_item_details pid
        LEFT JOIN dbo.product_master pm ON pm.prod_sno = pid.prod_sno
        LEFT JOIN dbo.service_master sm ON sm.service_sno = pid.service_sno
        LEFT JOIN dbo.supplier_quotation_items sqi ON sqi.pr_item_sno = pid.pr_item_sno AND sqi.is_active = 1
        LEFT JOIN dbo.supplier_quotation_info sq ON sq.sq_basic_sno = sqi.sq_basic_sno AND sq.is_selected = 1
        LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sq.vendor_sno
        WHERE pid.pr_basic_sno = @pr_basic_sno AND pid.is_active = 'Y'
    )
    SELECT
        vendor_sno,
        vendor_name,
        item_type AS line_type,
        (
            SELECT pl2.pr_item_sno, pl2.item_type, pl2.prod_sno, pl2.prod_name,
                   pl2.service_sno, pl2.service_name, pl2.qty, pl2.remarks
            FROM pr_lines pl2
            WHERE ISNULL(pl2.vendor_sno, -1) = ISNULL(pr_lines.vendor_sno, -1)
              AND pl2.item_type = pr_lines.item_type
            FOR JSON PATH
        ) AS lines,
        (
            SELECT TOP 1 po_basic_sno FROM dbo.po_request_info
            WHERE pr_basic_sno = @pr_basic_sno AND vendor_sno = pr_lines.vendor_sno AND is_active = 'Y'
        ) AS existing_po_basic_sno
    FROM pr_lines
    GROUP BY vendor_sno, vendor_name, item_type
    ORDER BY vendor_name, item_type;
END;