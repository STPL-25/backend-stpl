
CREATE   PROCEDURE dbo.sp_nt_UpdateSubCategoryRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.subcat_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.subcategory_master WHERE subcat_sno = @id)
    BEGIN
        RAISERROR('Sub category not found.', 16, 1);
        RETURN;
    END

    DECLARE @stock_type VARCHAR(20) = ISNULL(JSON_VALUE(@jsonInput, '$.subcat_stock_type'), (SELECT subcat_stock_type FROM dbo.subcategory_master WHERE subcat_sno = @id));
    DECLARE @perishable_days INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.perishable_days') AS INT);

    UPDATE dbo.subcategory_master
    SET cat_sno             = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.cat_sno') AS INT), cat_sno),
        subcat_name         = ISNULL(JSON_VALUE(@jsonInput, '$.subcat_name'), subcat_name),
        subcat_description  = ISNULL(JSON_VALUE(@jsonInput, '$.subcat_description'), subcat_description),
        subcat_notes        = ISNULL(JSON_VALUE(@jsonInput, '$.subcat_notes'), subcat_notes),
        subcat_stock_type   = @stock_type,
        perishable_days     = CASE WHEN @stock_type = 'Perishable' THEN ISNULL(@perishable_days, perishable_days) ELSE NULL END,
        subcat_modified_date = GETDATE(),
        subcat_modified_by   = JSON_VALUE(@jsonInput, '$.modified_by')
    WHERE subcat_sno = @id;

    SELECT * FROM dbo.subcategory_master WHERE subcat_sno = @id;
END
