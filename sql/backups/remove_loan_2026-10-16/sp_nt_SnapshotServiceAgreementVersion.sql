CREATE PROCEDURE dbo.sp_nt_SnapshotServiceAgreementVersion
    @agreement_sno INT,
    @action_type VARCHAR(20),
    @submitted_by VARCHAR(30),
    @submitted_at DATETIME = NULL,
    @outcome VARCHAR(10) = 'PENDING',
    @note NVARCHAR(300) = NULL,
    @out_version_no INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @terms NVARCHAR(MAX) = (
        SELECT sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno,
               sa.service_sno, sm.service_name, st.service_type_code, st.service_type_name,
               sa.qty, sa.rate_amount, sa.rate_uom_sno, um.uom_name AS rate_uom_name,
               sa.recurrence_cadence_sno, rc.cadence_name, sa.po_generation_day, sa.notify_days_before,
               sa.period_start_date, sa.period_end_date, sa.agreement_doc_url,
               sa.remarks, sa.terms_conditions, sa.ceiling_amount,
               (
                   SELECT v.vendor_sno, kv.company_name AS vendor_name, v.share_amount, v.share_pct
                   FROM dbo.service_agreement_vendor v
                   LEFT JOIN dbo.kyc_basic_info kv ON kv.kyc_basic_info_sno = v.vendor_sno
                   WHERE v.agreement_sno = sa.agreement_sno
                   ORDER BY v.sort_order, v.agreement_vendor_sno
                   FOR JSON PATH
               ) AS suppliers,
               JSON_QUERY((SELECT s.facility_type, s.facility_ref_no, s.sanctioned_amount, s.drawing_power,
                          s.rate_type, s.benchmark_rate_pct, s.spread_pct, s.interest_rate_pct,
                          s.benchmark_name, s.disbursed_amount, s.disbursement_date, s.interest_payment_day, s.day_count_basis
                   FROM dbo.service_agreement_statutory s
                   WHERE s.agreement_sno = sa.agreement_sno
                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS statutory
        FROM dbo.service_agreement sa
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno
        LEFT JOIN dbo.uom_master um ON um.uom_sno = sa.rate_uom_sno
        LEFT JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
        WHERE sa.agreement_sno = @agreement_sno
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    IF @terms IS NULL
        THROW 58180, 'Cannot snapshot: agreement not found.', 1;

    DECLARE @version_no INT =
        ISNULL((SELECT MAX(version_no) FROM dbo.service_agreement_version WITH (UPDLOCK, HOLDLOCK) WHERE agreement_sno = @agreement_sno), 0) + 1;

    UPDATE dbo.service_agreement_version
    SET superseded_at = GETDATE()
    WHERE agreement_sno = @agreement_sno AND superseded_at IS NULL;

    INSERT INTO dbo.service_agreement_version (
        agreement_sno, version_no, action_type, outcome, period_start_date, period_end_date,
        terms_json, note, submitted_by, submitted_at
    )
    SELECT @agreement_sno, @version_no, @action_type, @outcome, sa.period_start_date, sa.period_end_date,
           @terms, @note, @submitted_by, ISNULL(@submitted_at, GETDATE())
    FROM dbo.service_agreement sa
    WHERE sa.agreement_sno = @agreement_sno;

    SET @out_version_no = @version_no;
END;