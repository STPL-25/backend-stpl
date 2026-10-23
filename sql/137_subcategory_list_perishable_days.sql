-- ============================================================================
-- 137_subcategory_list_perishable_days.sql
--
-- sp_product_sub_catagory is the list procedure behind the Product Sub Category
-- master grid (and its dropdown options). It never returned perishable_days, so
-- the "Perishable Days (shelf life)" column was blank for every row and the Edit
-- form opened with that required field empty, even for a Perishable sub
-- category that has a shelf life (77_subcategory_perishable_type.sql added the
-- column and the field but not this SELECT).
--
-- Only change: sc.perishable_days is returned, right after subcat_stock_type.
-- Also reads dbo.* instead of hard-coded database-qualified three-part names
-- (same data where it runs now; a verbatim copy of the old text into another
-- database would have kept reading the original one).
-- Previous definition: backups/subcategory_list_perishable_days_2026-10-21/.
-- Safe to re-run.
-- ============================================================================
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
              ,sc.[perishable_days]
              ,sc.[cat_sno]
              ,cm.[cat_name]
        FROM [dbo].[subcategory_master] sc
        INNER JOIN [dbo].[category_master] cm ON cm.cat_sno = sc.cat_sno
        WHERE sc.subcat_active = 'Y'
        ORDER BY sc.subcat_sno;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
