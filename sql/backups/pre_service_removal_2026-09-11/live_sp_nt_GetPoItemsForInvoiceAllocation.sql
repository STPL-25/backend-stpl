CREATE PROCEDURE dbo.sp_nt_GetPoItemsForInvoiceAllocation
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT);

    IF @po_basic_sno IS NULL
        THROW 54020, 'po_basic_sno is required.', 1;

    SELECT
        poi.po_item_sno,
        ISNULL(poi.po_section, 'MATERIAL')          AS po_section,
        poi.prod_sno,
        ISNULL(poi.prod_name, pm.prod_name)         AS prod_name,
        poi.service_sno,
        sm.service_name,
        poi.qty,
        poi.unit_name,
        poi.net_cost                                AS line_value,
        ISNULL(alloc.already_allocated, 0)          AS already_allocated,
        (
            SELECT ISNULL(SUM(g.received_qty - ISNULL(g.rejected_qty, 0)), 0)
            FROM dbo.grn_item_details g
            WHERE g.po_item_sno = poi.po_item_sno AND g.is_active = 'Y'
        ) AS received_qty
    FROM dbo.po_item_details poi
    LEFT JOIN dbo.product_master pm ON pm.prod_sno = poi.prod_sno
    LEFT JOIN dbo.service_master sm ON sm.service_sno = poi.service_sno
    OUTER APPLY (
        SELECT SUM(iad.allocated_amount) AS already_allocated
        FROM dbo.invoice_allocation_details iad
        WHERE iad.po_item_sno = poi.po_item_sno AND iad.is_active = 'Y'
    ) alloc
    WHERE poi.po_basic_sno = @po_basic_sno
      AND poi.is_active IN ('1', 'Y')  -- po_item_details.is_active observed as '1' in production
    ORDER BY poi.po_item_sno;
END;