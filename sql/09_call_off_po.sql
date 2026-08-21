-- ============================================================
-- sp_nt_CreateCallOffPO — Type-3 (Vendor-Bill-Driven) repeat cycle
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend-stpl/src/ServicePO (createCallOffPO)
--
-- Why this is needed
-- ------------------
-- Service_Procurement_Flow.pdf, Type 3: "raise one annual/quarterly blanket
-- PO for the vendor and treat each 10-15 day bill as a call-off against it
-- (steps 4-7 then run only once)". A call-off is a lightweight CHILD PO
-- against an already-approved STANDING blanket PO (po_request_info.
-- parent_blanket_po_sno, added in 07_po_service_extensions.sql) — it skips
-- the full requisition+approval cycle entirely (auto-Approved, no
-- workflow_types_id/current_approver_id) since the blanket PO was already
-- approved once and the goods/services for this cycle are already
-- delivered/verified by the time the call-off is raised.
-- ============================================================

IF OBJECT_ID('dbo.sp_nt_CreateCallOffPO', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateCallOffPO;
GO
CREATE PROCEDURE dbo.sp_nt_CreateCallOffPO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @parent_blanket_po_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.parent_blanket_po_sno') AS INT);
        DECLARE @invoice_sno           INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_sno') AS INT);
        DECLARE @delivery_address      VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.delivery_address');
        DECLARE @terms_conditions      VARCHAR(MAX)  = JSON_VALUE(@jsonInput, '$.terms_conditions');
        DECLARE @purpose               VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.purpose');
        DECLARE @created_by            VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
        DECLARE @items                 NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');

        IF @parent_blanket_po_sno IS NULL OR @created_by IS NULL
            THROW 56001, 'parent_blanket_po_sno and created_by are required.', 1;

        IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
            THROW 56002, 'At least one item is required.', 1;

        DECLARE @vendor_sno INT, @service_type_sno INT, @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT, @parentStatus VARCHAR(10), @parentPoType VARCHAR(20);
        SELECT
            @vendor_sno = vendor_sno, @service_type_sno = service_type_sno,
            @com_sno = com_sno, @div_sno = div_sno, @brn_sno = brn_sno, @dept_sno = dept_sno,
            @parentStatus = status, @parentPoType = po_type
        FROM dbo.po_request_info
        WHERE po_basic_sno = @parent_blanket_po_sno;

        IF @vendor_sno IS NULL
            THROW 56003, 'parent_blanket_po_sno not found.', 1;

        IF @parentStatus <> 'A' OR @parentPoType <> 'STANDING'
            THROW 56004, 'The parent PO must be an approved Standing PO to accept call-offs.', 1;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(po_df_no, 4) AS INT)), 0) + 1
        FROM dbo.po_request_info WITH (UPDLOCK, HOLDLOCK)
        WHERE po_df_no LIKE 'CO-' + @year + '-%';
        DECLARE @po_no VARCHAR(50) = 'CO-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.po_request_info (
            vendor_sno, brn_sno, dept_sno, com_sno, div_sno, po_date, purpose, terms_conditions, delivery_address,
            is_active, workflow_types_id, current_approver_id, status, po_df_no,
            po_type, service_type_sno, is_retrospective, parent_blanket_po_sno, consumed_amount
        )
        VALUES (
            @vendor_sno, @brn_sno, @dept_sno, @com_sno, @div_sno, CAST(GETDATE() AS DATE), @purpose, @terms_conditions, @delivery_address,
            'Y', NULL, NULL, 'A', @po_no,
            'ONE_TIME', @service_type_sno, 1, @parent_blanket_po_sno, 0
        );

        DECLARE @po_basic_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.po_item_details (
            po_basic_sno, service_sno, prod_name, specification, qty, unit, unit_name,
            agreed_unit_price, total_cost, net_cost, remarks, po_section, created_by, created_date, is_active
        )
        SELECT
            @po_basic_sno,
            TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT),
            sm.service_name,
            JSON_VALUE(j.value, '$.specification'),
            TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)),
            TRY_CAST(JSON_VALUE(j.value, '$.unit') AS INT),
            um.uom_name,
            TRY_CAST(JSON_VALUE(j.value, '$.agreed_unit_price') AS DECIMAL(18,4)),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 0) * ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.agreed_unit_price') AS DECIMAL(18,4)), 0),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.net_cost') AS DECIMAL(18,4)),
                   ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.qty') AS DECIMAL(18,4)), 0) * ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.agreed_unit_price') AS DECIMAL(18,4)), 0)),
            JSON_VALUE(j.value, '$.remarks'),
            'SERVICE',
            -- po_item_details.is_active uses '1'/'0' (see 07_po_service_extensions.sql's note)
            @created_by, GETDATE(), '1'
        FROM OPENJSON(@items) j
        LEFT JOIN dbo.service_master sm ON sm.service_sno = TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT)
        LEFT JOIN dbo.uom_master um     ON um.uom_sno = TRY_CAST(JSON_VALUE(j.value, '$.unit') AS INT);

        IF @@ROWCOUNT = 0
            THROW 56005, 'No items were inserted.', 1;

        -- Optionally link the already-captured pre-PO invoice to this call-off PO
        IF @invoice_sno IS NOT NULL
        BEGIN
            UPDATE dbo.invoice_info SET po_basic_sno = @po_basic_sno, modified_date = GETDATE()
            WHERE invoice_sno = @invoice_sno;
        END

        COMMIT TRANSACTION;

        SELECT @po_basic_sno AS po_basic_sno, @po_no AS po_no, @parent_blanket_po_sno AS parent_blanket_po_sno, 'SUCCESS' AS result;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT name FROM sys.procedures WHERE name = 'sp_nt_CreateCallOffPO';
-- ============================================================
