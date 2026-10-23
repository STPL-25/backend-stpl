-- ROLLBACK for 137_subcategory_list_perishable_days.sql (Non_trade_Dev), 2026-10-21: previous sp_product_sub_catagory.
CREATE OR ALTER PROCEDURE [dbo].[sp_product_sub_catagory]
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SELECT sc.[subcat_sno]
              ,sc.[subcat_name]
              ,sc.[subcat_description]
              ,sc.[subcat_notes]
              ,sc.[subcat_stock_type]
              ,sc.[cat_sno]
              ,cm.[cat_name]
        FROM [Non_trade_Dev].[dbo].[subcategory_master] sc
        INNER JOIN [Non_trade_Dev].[dbo].[category_master] cm ON cm.cat_sno = sc.cat_sno
        WHERE sc.subcat_active = 'Y'
        ORDER BY sc.subcat_sno;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
