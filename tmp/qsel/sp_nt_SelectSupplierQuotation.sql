      
CREATE        PROCEDURE [dbo].[sp_nt_SelectSupplierQuotation]      
    @jsonInput NVARCHAR(MAX)      
AS      
BEGIN      
    SET NOCOUNT ON;      
      
    -- ─── Input Validation ──────────────────────────────────────────────      
    IF @jsonInput IS NULL OR @jsonInput = ''      
    BEGIN      
        SELECT 'Failed' AS Status, 'JSON input is required' AS ErrorMessage;      
        RETURN;      
    END      
      
    IF ISJSON(@jsonInput) = 0      
    BEGIN      
        SELECT 'Failed' AS Status, 'Invalid JSON format' AS ErrorMessage;      
        RETURN;      
    END      
      
    -- ─── Parse Input ───────────────────────────────────────────────────      
    DECLARE @sq_basic_sno       INT           = JSON_VALUE(@jsonInput, '$.sq_basic_sno');      
    DECLARE @selected_quotation INT           = JSON_VALUE(@jsonInput, '$.selected_quotation');      
    DECLARE @selected_by        NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.selected_by');      
    DECLARE @pr_basic_sno       INT           = JSON_VALUE(@jsonInput, '$.pr_basic_sno');      
    DECLARE @comment            NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.comment');      
    DECLARE @workflow_types_id  INT           = JSON_VALUE(@jsonInput, '$.workflow_types_id');      
    DECLARE @approver_ecno      NVARCHAR(100) = JSON_VALUE(@jsonInput, '$.approver_ecno');      
    DECLARE @pr_no              NVARCHAR(20) = JSON_VALUE(@jsonInput, '$.pr_no');      
      
      
    -- If the app doesn't send selected_quotation separately, fall back to sq_basic_sno.      
    SET @selected_quotation = ISNULL(@selected_quotation, @sq_basic_sno);      
      
    -- ─── Required field checks ─────────────────────────────────────────      
    IF @sq_basic_sno IS NULL      
    BEGIN      
        SELECT 'Failed' AS Status, 'sq_basic_sno is required' AS ErrorMessage;      
        RETURN;      
    END      
      
    -- FIX #5: Re-enabled — selected_by is used throughout; must be validated      
    IF @selected_by IS NULL OR @selected_by = ''      
    BEGIN      
        SELECT 'Failed' AS Status, 'selected_by is required' AS ErrorMessage;      
        RETURN;      
    END      
      
    BEGIN TRY      
        BEGIN TRANSACTION;      
      
        -- ─── Find the user's current ACTIVE selection for this PR ──────────      
        -- FIX #3: Scoped to @pr_basic_sno so cross-PR selections don't interfere      
        DECLARE @currentSelected INT;      
      
        SELECT TOP 1 @currentSelected = sq_basic_sno      
        FROM   supplier_quotation_history WITH (UPDLOCK, HOLDLOCK)      
        WHERE  selected_by   = @selected_by      
          AND  pr_basic_sno  = @pr_basic_sno      
          AND  pr_no=@pr_no -- scoped to this PR      
          AND  is_active      = 1      
        ORDER BY sq_history_sno DESC;      
      
        -- ─── Same user re-selecting the SAME quotation → no change ──────────      
        -- FIX #4: Compare against @selected_quotation (the explicitly sent value),      
        --         not @sq_basic_sno, so change-detection works as designed      
        IF @currentSelected IS NOT NULL AND @currentSelected = @selected_quotation      
        BEGIN      
            COMMIT TRANSACTION;      
            -- FIX #1: Removed trailing comma after @sq_basic_sno      
            SELECT 'Success'                                    AS Status,      
                   'Quotation already selected; no change made' AS Message,      
                   @sq_basic_sno                                AS sq_basic_sno;      
            RETURN;      
        END      
      
        -- ─── Deactivate the previous active selection (1 → 0) ───────────────      
        -- FIX #2: Deactivate by @currentSelected (the previously active quotation),      
        --         not @sq_basic_sno (the newly selected one — that row doesn't exist yet)      
        IF @currentSelected IS NOT NULL      
        BEGIN      
            UPDATE supplier_quotation_history      
            SET    is_active = 0      
            WHERE  sq_basic_sno = @currentSelected   -- was: @sq_basic_sno (wrong)      
              AND  selected_by  = @selected_by      
              AND  is_active    = 1;      
  END      
      
        -- ─── Insert the new active selection (= 1) ──────────────────────────      
        INSERT INTO supplier_quotation_history      
        (      
            sq_basic_sno,      
            sq_edit_data,      
            is_active,      
            workflow_types_id,      
            approver_ecno,      
            status,      
            status_by,      
            comment,      
            action_type,      
            pr_basic_sno,      
            selected_by,      
            pr_no      
        )      
        VALUES      
        (      
            @sq_basic_sno,      
            (   -- audit snapshot of the chosen quotation + its items      
                SELECT sqi.sq_basic_sno,      
                       sqi.pr_basic_sno,      
                       sqi.vendor_sno,      
                       sqi.quotation_ref_no,      
                       sqi.quotation_date,      
                       sqi.valid_upto,      
                       sqi.currency_code,      
                       sqi.payment_terms,      
                       sqi.delivery_days,      
                       sqi.remarks,      
                       sqi.status,      
                       (      
                           SELECT it.sq_item_sno, it.pr_item_sno, it.prod_sno,      
                                  it.specification, it.qty, it.unit, it.unit_price,      
                                  it.discount_pct, it.tax_pct, it.total_amount,      
                                  it.delivery_days, it.remarks      
                           FROM   supplier_quotation_items it      
                           WHERE  it.sq_basic_sno = sqi.sq_basic_sno      
                             AND  it.is_active    = 1      
                           FOR JSON PATH      
                       ) AS items      
                FROM   supplier_quotation_info sqi      
                WHERE  sqi.sq_basic_sno = @sq_basic_sno      
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER      
            ),      
            1,                                          -- is_active = new active row      
            @workflow_types_id,      
            @approver_ecno,      
            'A',      
            @selected_by,                               -- status_by      
            ISNULL(@comment, 'Supplier quotation selected'),      
            'QUOTATION_SELECTION',      
            @pr_basic_sno,      
            @selected_by,      
            @pr_no      
        );      
      
        -- ─── Reflect the choice in supplier_quotation_info ──────────────────      
        IF @pr_basic_sno IS NOT NULL      
        BEGIN      
            UPDATE supplier_quotation_info      
            SET    is_selected  = 0,      
                   modifed_by   = @selected_by,      
                   modifed_date = GETDATE()
            WHERE  pr_basic_sno = @pr_basic_sno      
               AND pr_no=@pr_no    
              AND  is_active    = 1;      
      
            UPDATE supplier_quotation_info      
            SET    is_selected  = 1,      
                   modifed_by   = @selected_by,      
                   modifed_date = GETDATE()      
            WHERE  sq_basic_sno = @sq_basic_sno     
            AND pr_no=@pr_no    
              AND  is_active    = 1;      
        END      
      
        COMMIT TRANSACTION;      
      
        SELECT 'Success'                                         AS Status,      
               'Supplier quotation selected and history recorded' AS Message,      
               @sq_basic_sno                                      AS sq_basic_sno,      
               @selected_by                                       AS selected_by     
    END TRY      
    BEGIN CATCH      
        IF @@TRANCOUNT > 0      
            ROLLBACK TRANSACTION;      
      
        SELECT 'Failed'           AS Status,      
               ERROR_MESSAGE()    AS ErrorMessage,      
               ERROR_NUMBER()     AS ErrorNumber,      
               ERROR_LINE()       AS ErrorLine,      
               ERROR_PROCEDURE()  AS ErrorProcedure;      
    END CATCH      
END 