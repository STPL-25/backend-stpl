-- ============================================================
-- recurrence_cadence_master: seed a Bi-Monthly (every 2 months) cadence
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- recurrence_cadence_master (23_service_recurring_flow_redesign.sql) already
-- reads interval_unit/interval_value generically — it was never hardcoded to
-- monthly, but only FIFTEEN_DAYS/MONTHLY/QUARTERLY/ANNUAL were ever seeded,
-- so "electricity every 2 months" had no option to pick. The admin can now
-- add arbitrary cadences themselves via the Masters grid (RecurrenceCadenceMaster
-- is wired into it as of this pass — see nt-frontend-stpl/src/FieldDatas/Data.tsx),
-- but this seeds the one exact case the user asked about so it works
-- immediately without that extra step.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM dbo.recurrence_cadence_master WHERE cadence_code = 'BIMONTHLY')
    INSERT INTO dbo.recurrence_cadence_master (cadence_code, cadence_name, interval_unit, interval_value, description, is_active, created_by)
    VALUES (N'BIMONTHLY', N'Bi-Monthly (Every 2 Months)', 'MONTH', 2, N'Bills every 2 months, on the anniversary of the period start date (or the explicit po_generation_day for Fixed Recurring)', 'Y', N'system');
GO

-- ============================================================
-- After running, confirm:
--   SELECT * FROM dbo.recurrence_cadence_master WHERE cadence_code = 'BIMONTHLY';
-- ============================================================
