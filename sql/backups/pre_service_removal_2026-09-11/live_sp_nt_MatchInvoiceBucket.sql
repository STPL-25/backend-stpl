CREATE PROCEDURE dbo.sp_nt_MatchInvoiceBucket
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @invoice_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_sno') AS INT);
        IF @invoice_sno IS NULL
            THROW 54010, 'invoice_sno is required.', 1;

        -- Per-bucket ratio: MATERIAL from GRN receipts, SERVICE from
        -- Service Entry (qty-based when the PO line carries a qty, else
        -- amount-based against the budgeted po_amount). Capped at 1.0.
        UPDATE iad
        SET matched_qty_ratio = ratios.ratio,
            hold_amount       = iad.allocated_amount * (1 - ratios.ratio),
            release_amount    = iad.allocated_amount * ratios.ratio,
            match_status      = CASE WHEN ratios.ratio >= 0.999999 THEN 'Matched' ELSE 'Partial' END
        FROM dbo.invoice_allocation_details iad
        JOIN dbo.po_item_details pid ON pid.po_item_sno = iad.po_item_sno
        CROSS APPLY (
            SELECT
                received_qty = (
                    SELECT ISNULL(SUM(gi.received_qty - ISNULL(gi.rejected_qty, 0)), 0)
                    FROM dbo.grn_item_details gi
                    WHERE gi.po_item_sno = pid.po_item_sno AND gi.is_active = 'Y'
                ),
                billed_qty_sum = (
                    SELECT ISNULL(SUM(sei.billed_qty), 0)
                    FROM dbo.service_entry_item_details sei
                    JOIN dbo.service_entry_info se ON se.service_entry_sno = sei.service_entry_sno
                    WHERE sei.po_item_sno = pid.po_item_sno AND sei.is_active = 'Y' AND se.status = 'Approved'
                ),
                confirmed_amt_sum = (
                    SELECT ISNULL(SUM(sei.confirmed_amount), 0)
                    FROM dbo.service_entry_item_details sei
                    JOIN dbo.service_entry_info se ON se.service_entry_sno = sei.service_entry_sno
                    WHERE sei.po_item_sno = pid.po_item_sno AND sei.is_active = 'Y' AND se.status = 'Approved'
                )
        ) raw
        CROSS APPLY (
            SELECT rawRatio = CASE
                WHEN iad.bucket_type = 'MATERIAL' THEN
                    CASE WHEN ISNULL(pid.qty, 0) = 0 THEN 0
                         ELSE CAST(raw.received_qty AS DECIMAL(18,6)) / pid.qty
                    END
                ELSE -- SERVICE
                    CASE
                        WHEN ISNULL(pid.qty, 0) > 0 THEN CAST(raw.billed_qty_sum AS DECIMAL(18,6)) / pid.qty
                        WHEN ISNULL(pid.net_cost, 0) > 0 THEN CAST(raw.confirmed_amt_sum AS DECIMAL(18,6)) / pid.net_cost
                        ELSE 0
                    END
                END
        ) computed
        CROSS APPLY (SELECT ratio = CASE WHEN computed.rawRatio > 1 THEN 1.0 ELSE computed.rawRatio END) ratios
        WHERE iad.invoice_sno = @invoice_sno AND iad.is_active = 'Y';

        DECLARE @totalRelease DECIMAL(18,2), @bucketCount INT, @matchedCount INT;
        SELECT
            @totalRelease = SUM(release_amount),
            @bucketCount  = COUNT(*),
            @matchedCount = SUM(CASE WHEN match_status = 'Matched' THEN 1 ELSE 0 END)
        FROM dbo.invoice_allocation_details WHERE invoice_sno = @invoice_sno AND is_active = 'Y';

        UPDATE dbo.invoice_info
        SET net_payable = ISNULL(@totalRelease, 0),
            match_status = CASE WHEN @matchedCount = @bucketCount THEN 'Matched' ELSE 'PartialRelease' END,
            modified_date = GETDATE()
        WHERE invoice_sno = @invoice_sno;

        COMMIT TRANSACTION;

        SELECT invoice_alloc_sno, po_item_sno, bucket_type, allocated_amount, matched_qty_ratio, hold_amount, release_amount, match_status
        FROM dbo.invoice_allocation_details WHERE invoice_sno = @invoice_sno AND is_active = 'Y';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;