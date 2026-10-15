-- ============================================================
-- Clear TRANSACTION data, keep MASTER / config data  (structure untouched)
-- Database : run it on the database you mean to clear (Non_Trade = PRODUCTION)
--
-- NOT executed by Claude. Run it yourself in SSMS.
--
-- HOW TO USE
--   1. Take a backup first:
--        BACKUP DATABASE Non_Trade TO DISK = N'D:\backup\Non_Trade_before_clear.bak' WITH COPY_ONLY, INIT;
--   2. Run as-is (@Execute = 0): it only LISTS every table with its row count and
--      whether it will be KEPT or CLEARED. Nothing is changed. Review the list.
--   3. Fix the KEEP rules below if a table is wrongly classified.
--   4. Set @Execute = 1 and @ConfirmDb = N'Non_Trade' (must equal DB_NAME()) and run again.
--
-- WHAT IS KEPT (name rules - edit as needed)
--   * masters (*_master), company / division / branch / department / designation / hierarchy
--   * users, logins, staff, roles, permissions, screens, menus
--   * approval-workflow configuration (workflows, types, stages, routes, condition fields)
--   * suppliers and their KYC (supplier*, kyc_*, service_vendor_kyc*) - includes any KYC still
--     pending approval; supplier quotations/invoices are still cleared
--   * item/product masters, UOM, terms, payment terms, banks, GST/tax setup
-- EVERYTHING ELSE (PR, PO, GRN, KYC submissions, quotations, invoices, payments, stock,
--   notifications, logs, histories, service agreements/POs ...) IS CLEARED.
--
-- Identity columns are reseeded so new rows start from 1 again.
-- Everything runs in ONE transaction; any error rolls the whole thing back.
-- ============================================================
SET NOCOUNT ON;

DECLARE @Execute   BIT           = 0;               -- 0 = list only, 1 = really delete
DECLARE @ConfirmDb NVARCHAR(128) = N'';             -- must equal DB_NAME() when @Execute = 1

IF @Execute = 1 AND @ConfirmDb <> DB_NAME()
BEGIN
    RAISERROR('Refusing to delete: @ConfirmDb does not match DB_NAME() (%s).', 16, 1, @ConfirmDb);
    RETURN;
END;

-- ---------------- classification ----------------
IF OBJECT_ID('tempdb..#plan') IS NOT NULL DROP TABLE #plan;
SELECT  s.name AS schema_name,
        t.name AS table_name,
        t.object_id,
        ISNULL((SELECT SUM(ps.row_count) FROM sys.dm_db_partition_stats ps
                WHERE ps.object_id = t.object_id AND ps.index_id IN (0,1)), 0) AS row_count,
        CASE
            WHEN t.temporal_type = 1 THEN 'KEEP'            -- history side of a system-versioned table
            WHEN t.name LIKE '%[_]master'
              OR t.name LIKE '%[_]master[_]%'
              OR t.name LIKE '%compan%'     OR t.name LIKE '%division%'  OR t.name LIKE '%branch%'
              OR t.name LIKE '%dept%'       OR t.name LIKE '%department%' OR t.name LIKE '%hierarchy%'
              OR t.name LIKE '%designation%' OR t.name LIKE '%entity[_]master%'
              OR t.name LIKE '%login%'      OR t.name LIKE '%user%'      OR t.name LIKE '%staff%'
              OR t.name LIKE '%employee%'   OR t.name LIKE '%role%'      OR t.name LIKE '%permission%'
              OR t.name LIKE '%screen%'     OR t.name LIKE '%menu%'
              OR t.name LIKE 'approval[_]workflow%' OR t.name LIKE 'workflow[_]types%'
              OR t.name LIKE 'workflow[_]stage%'    OR t.name LIKE 'approval[_]condition[_]field%'
              OR t.name LIKE 'approval[_]entity[_]route%' OR t.name LIKE 'approval[_]route%'
              OR t.name LIKE '%approval[_]config%'
              OR t.name LIKE '%supplier%'   OR t.name LIKE 'kyc[_]%'     OR t.name LIKE 'vw[_]%kyc%'
              OR t.name LIKE 'service[_]vendor[_]kyc%'
              OR t.name LIKE '%uom%'        OR t.name LIKE '%gst%'       OR t.name LIKE '%tax%'
              OR t.name LIKE '%bank[_]account[_]type%'
              OR t.name IN (N'sysdiagrams')
            THEN 'KEEP' ELSE 'CLEAR'
        END AS action_
INTO    #plan
FROM    sys.tables t
JOIN    sys.schemas s ON s.schema_id = t.schema_id
WHERE   t.is_ms_shipped = 0;

SELECT action_, schema_name, table_name, row_count
FROM   #plan
ORDER  BY action_ DESC, table_name;

SELECT action_, COUNT(*) AS tables, SUM(row_count) AS total_rows FROM #plan GROUP BY action_;

IF @Execute = 0
BEGIN
    PRINT 'LIST ONLY - nothing deleted. Review the CLEAR rows, then set @Execute = 1 and @ConfirmDb.';
    RETURN;
END;

-- ---------------- delete ----------------
BEGIN TRY
    BEGIN TRAN;

    DECLARE @sql NVARCHAR(MAX), @obj NVARCHAR(300);

    -- 1. switch FK checking off on the tables being cleared AND on tables that reference them
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT QUOTENAME(s.name) + N'.' + QUOTENAME(t.name)
        FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
        WHERE t.is_ms_shipped = 0;
    OPEN c; FETCH NEXT FROM c INTO @obj;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ALTER TABLE ' + @obj + N' NOCHECK CONSTRAINT ALL;';
        EXEC (@sql);
        FETCH NEXT FROM c INTO @obj;
    END;
    CLOSE c; DEALLOCATE c;

    -- 2. delete rows (DELETE, not TRUNCATE: TRUNCATE is refused on FK-referenced tables)
    DECLARE d CURSOR LOCAL FAST_FORWARD FOR
        SELECT QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name), object_id
        FROM #plan WHERE action_ = 'CLEAR' AND row_count > 0;
    DECLARE @oid INT;
    OPEN d; FETCH NEXT FROM d INTO @obj, @oid;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'DELETE FROM ' + @obj + N';';
        EXEC (@sql);
        IF EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = @oid)
        BEGIN
            SET @sql = N'DBCC CHECKIDENT (' + QUOTENAME(@obj, '''') + N', RESEED, 0) WITH NO_INFOMSGS;';
            EXEC (@sql);
        END;
        FETCH NEXT FROM d INTO @obj, @oid;
    END;
    CLOSE d; DEALLOCATE d;

    -- 3. switch FK checking back on (re-validating existing rows)
    DECLARE e CURSOR LOCAL FAST_FORWARD FOR
        SELECT QUOTENAME(s.name) + N'.' + QUOTENAME(t.name)
        FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
        WHERE t.is_ms_shipped = 0;
    OPEN e; FETCH NEXT FROM e INTO @obj;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ALTER TABLE ' + @obj + N' WITH CHECK CHECK CONSTRAINT ALL;';
        EXEC (@sql);
        FETCH NEXT FROM e INTO @obj;
    END;
    CLOSE e; DEALLOCATE e;

    COMMIT TRAN;
    PRINT 'DONE - transaction data cleared, masters kept.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRAN;
    PRINT 'FAILED - rolled back, nothing was deleted: ' + ERROR_MESSAGE();
END CATCH;
