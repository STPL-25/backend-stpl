-- ── what can be adjusted against a supplier's payment ───────────────────────
-- { vendor_sno }  -> 4 recordsets: advances, debit notes, credit notes, TDS sections
CREATE   PROCEDURE dbo.sp_nt_GetPaymentAdjustments
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @v INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    SELECT advance_sno, advance_no, po_basic_sno, paid_date, amount, amount - adjusted_amount AS balance
    FROM dbo.nt_supplier_advance_payment WHERE vendor_sno = @v AND is_active = 'Y' AND amount - adjusted_amount > 0 ORDER BY paid_date, advance_sno;

    SELECT d.debit_note_sno AS note_sno, d.debit_note_no AS note_no, d.po_basic_sno, d.grn_basic_sno, d.debit_note_date AS note_date, d.total_amount AS amount, d.remarks
    FROM dbo.debit_note_basic_info d
    WHERE d.vendor_sno = @v AND d.is_active = 'Y' AND ISNULL(d.total_amount, 0) > 0
      AND NOT EXISTS (SELECT 1 FROM dbo.payment_adjustment pa WHERE pa.adj_type = 'DEBIT_NOTE' AND pa.ref_sno = d.debit_note_sno)
    ORDER BY d.debit_note_sno;

    SELECT c.credit_note_sno AS note_sno, c.credit_note_no AS note_no, c.po_basic_sno, c.grn_basic_sno, c.credit_note_date AS note_date, c.total_amount AS amount, c.remarks
    FROM dbo.credit_note_basic_info c
    WHERE c.vendor_sno = @v AND c.is_active = 'Y' AND ISNULL(c.total_amount, 0) > 0
      AND NOT EXISTS (SELECT 1 FROM dbo.payment_adjustment pa WHERE pa.adj_type = 'CREDIT_NOTE' AND pa.ref_sno = c.credit_note_sno)
    ORDER BY c.credit_note_sno;

    SELECT section_code, description, rate_individual, rate_other, rate_no_pan, single_threshold, annual_threshold, excess_only, is_active
    FROM dbo.tds_section_master ORDER BY section_code;
END