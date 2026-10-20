CREATE PROCEDURE dbo.sp_nt_GetServiceAgreements
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @com_sno INT = NULL, @div_sno INT = NULL, @brn_sno INT = NULL, @dept_sno INT = NULL, @status CHAR(1) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @com_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        SET @div_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        SET @brn_sno  = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        SET @dept_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        SET @status   = JSON_VALUE(@jsonInput, '$.status');
    END

    SELECT sa.agreement_sno, sa.agreement_no, sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
           sa.service_sno, sm.service_name, st.service_type_code, st.service_type_name,
           sa.vendor_sno, k.company_name AS vendor_name,
           (
               SELECT v.vendor_sno, kv.company_name AS vendor_name, v.share_amount, v.share_pct
               FROM dbo.service_agreement_vendor v
               LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = v.vendor_sno
               WHERE v.agreement_sno = sa.agreement_sno
               ORDER BY v.sort_order, v.agreement_vendor_sno
               FOR JSON PATH
           ) AS vendors_json,
           (SELECT COUNT(*) FROM dbo.service_agreement_vendor v WHERE v.agreement_sno = sa.agreement_sno) AS supplier_count,
           sa.qty, sa.rate_amount, sa.rate_uom_sno, um.uom_name AS rate_uom_name,
           sa.recurrence_cadence_sno, rc.cadence_name, rc.interval_unit, rc.interval_value,
           sa.po_generation_day, sa.notify_days_before,
           sa.period_start_date, sa.period_end_date, sa.agreement_doc_url, sa.remarks, sa.terms_conditions,
           sa.ceiling_amount,
           stt.facility_type, stt.facility_ref_no, stt.sanctioned_amount, stt.drawing_power,
           stt.rate_type, stt.benchmark_rate_pct, stt.spread_pct, stt.interest_rate_pct,
           stt.benchmark_name, stt.disbursed_amount, stt.disbursement_date, stt.interest_payment_day, stt.day_count_basis,
           (SELECT MAX(ver.version_no) FROM dbo.service_agreement_version ver WHERE ver.agreement_sno = sa.agreement_sno) AS version_no,
           (SELECT COUNT(*) FROM dbo.service_agreement_version ver WHERE ver.agreement_sno = sa.agreement_sno AND ver.action_type = 'RENEWED') AS renewal_count,
           sa.current_approver_id, sa.status, sa.created_by, sa.created_at
    FROM dbo.service_agreement sa
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = sa.vendor_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = sa.rate_uom_sno
    LEFT JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
    LEFT JOIN dbo.service_agreement_statutory stt ON stt.agreement_sno = sa.agreement_sno
    WHERE sa.is_active = 'Y'
      AND (@com_sno IS NULL OR sa.com_sno = @com_sno)
      AND (@div_sno IS NULL OR sa.div_sno = @div_sno)
      AND (@brn_sno IS NULL OR sa.brn_sno = @brn_sno)
      AND (@dept_sno IS NULL OR sa.dept_sno = @dept_sno)
      AND (@status IS NULL OR sa.status = @status)
    ORDER BY sa.agreement_sno DESC;
END;