-- ROLLBACK for grn-service/sql/35_stock_request_org_from_items.sql (Non_Trade, 2026-09-21).
-- This is the sp_nt_CreateStockRequest definition that was live before the fix.
SET QUOTED_IDENTIFIER OFF;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateStockRequest
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @requested_by   VARCHAR(50)  = JSON_VALUE(@jsonInput, '$.requested_by');
    DECLARE @requested_name VARCHAR(255) = JSON_VALUE(@jsonInput, '$.requested_name');
    DECLARE @department     VARCHAR(100) = JSON_VALUE(@jsonInput, '$.department');
    DECLARE @purpose        VARCHAR(500) = JSON_VALUE(@jsonInput, '$.purpose');
    DECLARE @com_sno        INT          = JSON_VALUE(@jsonInput, '$.com_sno');
    DECLARE @div_sno        INT          = JSON_VALUE(@jsonInput, '$.div_sno');
    DECLARE @brn_sno        INT          = JSON_VALUE(@jsonInput, '$.brn_sno');
    DECLARE @dept_sno       INT          = JSON_VALUE(@jsonInput, '$.dept_sno');

    IF @requested_by IS NULL
    BEGIN
        RAISERROR('requested_by is required.', 16, 1);
        RETURN;
    END

    DECLARE @items TABLE (
        item_sno      INT,
        quantity      DECIMAL(18,2),
        remarks       VARCHAR(255)
    );

    INSERT INTO @items (item_sno, quantity, remarks)
    SELECT item_sno, quantity, remarks
    FROM OPENJSON(@jsonInput, '$.items')
    WITH (
        item_sno INT            '$.item_sno',
        quantity DECIMAL(18,2)  '$.quantity',
        remarks  VARCHAR(255)   '$.remarks'
    );

    IF NOT EXISTS (SELECT 1 FROM @items)
    BEGIN
        RAISERROR('At least one item is required.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM @items WHERE item_sno IS NULL OR quantity IS NULL OR quantity <= 0)
    BEGIN
        RAISERROR('Every item needs an item_sno and a quantity greater than zero.', 16, 1);
        RETURN;
    END

    IF EXISTS (
        SELECT 1 FROM @items t
        LEFT JOIN dbo.nt_inventory_items i ON i.item_sno = t.item_sno
        WHERE i.item_sno IS NULL OR i.status <> 'Active'
    )
    BEGIN
        RAISERROR('One or more items do not exist or are not Active.', 16, 1);
        RETURN;
    END

    DECLARE @request_sno INT;
    DECLARE @request_no  VARCHAR(30);
    DECLARE @year        VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));

    BEGIN TRANSACTION;
    BEGIN TRY
        -- Next sequence for the year (serialised by the transaction + UPDLOCK)
        DECLARE @seq INT;
        SELECT @seq = ISNULL(MAX(CAST(RIGHT(request_no, 4) AS INT)), 0) + 1
        FROM dbo.nt_stock_requests WITH (UPDLOCK, HOLDLOCK)
        WHERE request_no LIKE 'SR-' + @year + '-%';

        SET @request_no = 'SR-' + @year + '-' + RIGHT('0000' + CAST(@seq AS VARCHAR(4)), 4);

        INSERT INTO dbo.nt_stock_requests (
            request_no, requested_by, requested_name, department, purpose,
            status, com_sno, div_sno, brn_sno, dept_sno, created_at
        )
        VALUES (
            @request_no, @requested_by, @requested_name, @department, @purpose,
            'Pending', @com_sno, @div_sno, @brn_sno, @dept_sno, GETDATE()
        );

        SET @request_sno = SCOPE_IDENTITY();

        INSERT INTO dbo.nt_stock_request_items (
            request_sno, item_sno, item_code, item_name, uom,
            requested_qty, issued_qty, line_status, remarks
        )
        SELECT
            @request_sno, t.item_sno, i.item_code, i.item_name, i.uom,
            t.quantity, 0, 'Pending', t.remarks
        FROM @items t
        JOIN dbo.nt_inventory_items i ON i.item_sno = t.item_sno;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT
        r.request_sno, r.request_no, r.requested_by, r.requested_name, r.department,
        r.purpose, r.status, r.com_sno, r.div_sno, r.brn_sno, r.dept_sno,
        (SELECT COUNT(*) FROM dbo.nt_stock_request_items WHERE request_sno = r.request_sno) AS item_count,
        CONVERT(VARCHAR(30), r.created_at, 120) AS created_at
    FROM dbo.nt_stock_requests r
    WHERE r.request_sno = @request_sno;
END;

GO
