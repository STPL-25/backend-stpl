-- ── release a payment with TDS / advance / note adjustments ─────────────────
-- @jsonInput: { vendor_sno, payment_date, mode, bank_account?, reference_no?, remarks?, created_by, preview?, apply_tds?,
--   allocations: [{ invoice_alloc_sno, amount }], advances: [{ advance_sno, amount }], notes: [{ type: 'DEBIT'|'CREDIT', note_sno }] }
CREATE   PROCEDURE dbo.sp_nt_ReleasePaymentNet
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @v INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
            @pdate DATE = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_date') AS DATE), CAST(GETDATE() AS DATE)),
            @mode VARCHAR(10) = JSON_VALUE(@jsonInput, '$.mode'), @bank VARCHAR(100) = JSON_VALUE(@jsonInput, '$.bank_account'),
            @ref VARCHAR(100) = JSON_VALUE(@jsonInput, '$.reference_no'), @rem VARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks'),
            @by VARCHAR(20) = JSON_VALUE(@jsonInput, '$.created_by'),
            @preview BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.preview') IN ('1', 'true') THEN 1 ELSE 0 END,
            @applyTds BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.apply_tds') IN ('0', 'false') THEN 0 ELSE 1 END,
            @allocJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.allocations'),
            @advJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.advances'),
            @noteJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.notes');
    IF @v IS NULL OR @mode IS NULL OR @by IS NULL OR @allocJson IS NULL THROW 55011, 'vendor_sno, mode, created_by and allocations are required.', 1;

    DECLARE @alloc TABLE (invoice_alloc_sno INT, amount DECIMAL(18,2));
    INSERT INTO @alloc SELECT TRY_CAST(JSON_VALUE(value, '$.invoice_alloc_sno') AS INT), TRY_CAST(JSON_VALUE(value, '$.amount') AS DECIMAL(18,2)) FROM OPENJSON(@allocJson);
    IF NOT EXISTS (SELECT 1 FROM @alloc) OR EXISTS (SELECT 1 FROM @alloc WHERE invoice_alloc_sno IS NULL OR amount IS NULL OR amount <= 0)
        THROW 55012, 'Each allocation needs an invoice_alloc_sno and a positive amount.', 1;

    -- same release limit rule as sp_nt_ReleasePayment, plus every bucket must belong to this supplier
    IF EXISTS (
        SELECT 1 FROM @alloc a
        LEFT JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = a.invoice_alloc_sno
        LEFT JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
        OUTER APPLY (SELECT ISNULL(SUM(pad.amount), 0) AS paid FROM dbo.payment_allocation_details pad WHERE pad.invoice_alloc_sno = a.invoice_alloc_sno) p
        WHERE iad.invoice_alloc_sno IS NULL OR i.vendor_sno <> @v OR a.amount > (iad.release_amount - p.paid) + 0.01
    )
        THROW 55013, 'An allocation is unknown, belongs to another supplier, or exceeds its unpaid release amount.', 1;

    DECLARE @gross DECIMAL(18,2) = (SELECT SUM(amount) FROM @alloc);

    -- per-invoice TDS
    DECLARE @inv TABLE (invoice_sno INT PRIMARY KEY, gross DECIMAL(18,2), base DECIMAL(18,2), section VARCHAR(10),
                        taxable DECIMAL(18,2) NULL, rate DECIMAL(6,3) NULL, tds DECIMAL(18,2) NOT NULL DEFAULT 0, fy INT NULL);
    INSERT INTO @inv (invoice_sno, gross, base, section)
    SELECT i.invoice_sno, SUM(a.amount),
           ROUND(SUM(a.amount) * CASE WHEN ISNULL(i.invoice_amount, 0) > 0 AND i.taxable_value IS NOT NULL THEN i.taxable_value / i.invoice_amount ELSE 1 END, 2),
           i.tds_section_code
    FROM @alloc a JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = a.invoice_alloc_sno
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
    GROUP BY i.invoice_sno, i.invoice_amount, i.taxable_value, i.tds_section_code;

    -- optional per-invoice TDS section chosen on the payment screen: tds_overrides [{ invoice_sno, section }] ('' = no TDS)
    DECLARE @tdsJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.tds_overrides');
    IF @tdsJson IS NOT NULL
        UPDATE x SET section = NULLIF(UPPER(LTRIM(RTRIM(JSON_VALUE(o.value, '$.section')))), '')
        FROM @inv x JOIN OPENJSON(@tdsJson) o ON x.invoice_sno = TRY_CAST(JSON_VALUE(o.value, '$.invoice_sno') AS INT);

    -- GSTR-2B hold: a GST-registered supplier's invoice cannot be paid until 2B has matched it, unless Accounts released the hold (sql/45)
    IF EXISTS (SELECT 1 FROM @inv x JOIN dbo.invoice_info inv ON inv.invoice_sno = x.invoice_sno
               JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = inv.vendor_sno
               WHERE LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 AND ISNULL(inv.itc_status, '') NOT IN ('Eligible', 'Ineligible') AND ISNULL(inv.payment_hold_override, 'N') <> 'Y')
    BEGIN
        DECLARE @held NVARCHAR(400) = (SELECT STRING_AGG(inv.invoice_no, ', ') FROM @inv x JOIN dbo.invoice_info inv ON inv.invoice_sno = x.invoice_sno
               JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = inv.vendor_sno
               WHERE LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 AND ISNULL(inv.itc_status, '') NOT IN ('Eligible', 'Ineligible') AND ISNULL(inv.payment_hold_override, 'N') <> 'Y');
        DECLARE @heldMsg NVARCHAR(500) = N'Payment held until the invoice appears in GSTR-2B (or Accounts releases the hold): ' + @held;
        THROW 55021, @heldMsg, 1;
    END

    IF @applyTds = 1
    BEGIN
        DECLARE @isno INT, @ibase DECIMAL(18,2), @isec VARCHAR(10), @t DECIMAL(18,2), @r DECIMAL(6,3), @tx DECIMAL(18,2), @fy INT;
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT invoice_sno, base, section FROM @inv WHERE section IS NOT NULL ORDER BY invoice_sno;
        OPEN cur; FETCH NEXT FROM cur INTO @isno, @ibase, @isec;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @xp DECIMAL(18,2) = ISNULL((SELECT SUM(base) FROM @inv WHERE section = @isec AND taxable IS NOT NULL), 0),
                    @xd DECIMAL(18,2) = ISNULL((SELECT SUM(taxable) FROM @inv WHERE section = @isec AND taxable IS NOT NULL), 0);
            EXEC dbo.sp_nt_CalcTDS @vendor_sno = @v, @section = @isec, @base = @ibase, @on_date = @pdate,
                 @extra_prior = @xp, @extra_deducted = @xd, @tds = @t OUTPUT, @rate = @r OUTPUT, @taxable = @tx OUTPUT, @fy = @fy OUTPUT;
            UPDATE @inv SET taxable = @tx, rate = @r, tds = @t, fy = @fy WHERE invoice_sno = @isno;
            FETCH NEXT FROM cur INTO @isno, @ibase, @isec;
        END
        CLOSE cur; DEALLOCATE cur;
    END
    DECLARE @tds DECIMAL(18,2) = ISNULL((SELECT SUM(tds) FROM @inv), 0);

    -- advances
    DECLARE @adv TABLE (advance_sno INT, amount DECIMAL(18,2));
    IF @advJson IS NOT NULL
        INSERT INTO @adv SELECT TRY_CAST(JSON_VALUE(value, '$.advance_sno') AS INT), TRY_CAST(JSON_VALUE(value, '$.amount') AS DECIMAL(18,2)) FROM OPENJSON(@advJson);
    IF EXISTS (SELECT 1 FROM @adv a LEFT JOIN dbo.nt_supplier_advance_payment s ON s.advance_sno = a.advance_sno AND s.vendor_sno = @v AND s.is_active = 'Y'
               WHERE a.amount IS NULL OR a.amount <= 0 OR s.advance_sno IS NULL OR a.amount > s.amount - s.adjusted_amount + 0.01)
        THROW 55014, 'An advance is unknown, belongs to another supplier, or the amount exceeds its balance.', 1;
    DECLARE @advTotal DECIMAL(18,2) = ISNULL((SELECT SUM(amount) FROM @adv), 0);
    IF @advTotal > @gross - @tds + 0.01 THROW 55015, 'Advance adjusted cannot exceed the amount payable after TDS.', 1;

    -- notes
    DECLARE @notes TABLE (note_type VARCHAR(6), note_sno INT, amount DECIMAL(18,2));
    IF @noteJson IS NOT NULL
        INSERT INTO @notes (note_type, note_sno) SELECT UPPER(JSON_VALUE(value, '$.type')), TRY_CAST(JSON_VALUE(value, '$.note_sno') AS INT) FROM OPENJSON(@noteJson);
    IF EXISTS (SELECT 1 FROM @notes WHERE note_type NOT IN ('DEBIT', 'CREDIT') OR note_sno IS NULL) THROW 55016, 'Each note needs type DEBIT or CREDIT and a note_sno.', 1;
    UPDATE n SET amount = d.total_amount FROM @notes n JOIN dbo.debit_note_basic_info d ON d.debit_note_sno = n.note_sno AND d.vendor_sno = @v AND d.is_active = 'Y'
        WHERE n.note_type = 'DEBIT' AND NOT EXISTS (SELECT 1 FROM dbo.payment_adjustment pa WHERE pa.adj_type = 'DEBIT_NOTE' AND pa.ref_sno = n.note_sno);
    UPDATE n SET amount = c.total_amount FROM @notes n JOIN dbo.credit_note_basic_info c ON c.credit_note_sno = n.note_sno AND c.vendor_sno = @v AND c.is_active = 'Y'
        WHERE n.note_type = 'CREDIT' AND NOT EXISTS (SELECT 1 FROM dbo.payment_adjustment pa WHERE pa.adj_type = 'CREDIT_NOTE' AND pa.ref_sno = n.note_sno);
    IF EXISTS (SELECT 1 FROM @notes WHERE amount IS NULL) THROW 55017, 'A note is unknown, belongs to another supplier, or was already adjusted.', 1;
    DECLARE @dn DECIMAL(18,2) = ISNULL((SELECT SUM(amount) FROM @notes WHERE note_type = 'DEBIT'), 0),
            @cn DECIMAL(18,2) = ISNULL((SELECT SUM(amount) FROM @notes WHERE note_type = 'CREDIT'), 0);

    DECLARE @net DECIMAL(18,2) = @gross - @tds - @advTotal - @dn + @cn;
    IF @net < 0 THROW 55018, 'Debit notes and advances exceed what is payable - nothing to pay.', 1;

    IF @preview = 1
    BEGIN
        SELECT @gross AS gross_amount, @tds AS tds_amount, @advTotal AS advance_adjusted, @dn AS debit_notes, @cn AS credit_notes, @net AS net_paid;
        SELECT i.invoice_sno, inv.invoice_no, i.gross, i.base AS taxable_base, i.section AS tds_section, i.rate AS tds_rate_pct, i.taxable AS tds_taxable, i.tds AS tds_amount
        FROM @inv i JOIN dbo.invoice_info inv ON inv.invoice_sno = i.invoice_sno;
        RETURN;
    END

    DECLARE @h_pay INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'SUPPLIER_PAYABLE'),
            @h_tds INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'TDS_PAYABLE'),
            @h_adv INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'ADVANCE_SUPPLIER'),
            @h_bank INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'BANK'),
            @h_dn INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'DN_ADJ');
    IF @h_pay IS NULL OR @h_tds IS NULL OR @h_adv IS NULL OR @h_bank IS NULL OR @h_dn IS NULL THROW 55019, 'System account heads are missing.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(payment_no, 6) AS INT)), 0) + 1 FROM dbo.payment_info WITH (UPDLOCK, HOLDLOCK) WHERE payment_no LIKE 'PAY-' + @year + '-%';
        DECLARE @pno VARCHAR(30) = 'PAY-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6), @psno INT;

        INSERT INTO dbo.payment_info (payment_no, vendor_sno, payment_date, amount, mode, bank_account, reference_no, status, remarks, is_active, created_by, created_date,
                                      gross_amount, tds_amount, advance_adjusted, note_adjusted, net_paid)
        VALUES (@pno, @v, @pdate, @gross, @mode, @bank, @ref, 'Processed', @rem, 'Y', @by, GETDATE(), @gross, @tds, @advTotal, @dn - @cn, @net);
        SET @psno = SCOPE_IDENTITY();

        INSERT INTO dbo.payment_allocation_details (payment_sno, invoice_alloc_sno, amount, created_date) SELECT @psno, invoice_alloc_sno, amount, GETDATE() FROM @alloc;
        IF @tdsJson IS NOT NULL   -- remember the chosen section on the invoice for its later part-payments
            UPDATE inv SET tds_section_code = x.section FROM dbo.invoice_info inv JOIN @inv x ON x.invoice_sno = inv.invoice_sno;

        -- TDS: track every payment base (even when TDS = 0) so annual thresholds work
        INSERT INTO dbo.tds_deduction (vendor_sno, section_code, fin_year, invoice_sno, payment_sno, base_amount, base_deducted, rate_pct, tds_amount)
        SELECT @v, section, fy, invoice_sno, @psno, base, ISNULL(taxable, 0), ISNULL(rate, 0), tds FROM @inv WHERE section IS NOT NULL AND fy IS NOT NULL;
        INSERT INTO dbo.payment_adjustment (payment_sno, adj_type, ref_sno, invoice_sno, amount) SELECT @psno, 'TDS', NULL, invoice_sno, tds FROM @inv WHERE tds > 0;

        INSERT INTO dbo.payment_adjustment (payment_sno, adj_type, ref_sno, amount) SELECT @psno, 'ADVANCE', advance_sno, amount FROM @adv;
        UPDATE s SET adjusted_amount = s.adjusted_amount + a.amount FROM dbo.nt_supplier_advance_payment s JOIN @adv a ON a.advance_sno = s.advance_sno;
        INSERT INTO dbo.payment_adjustment (payment_sno, adj_type, ref_sno, amount) SELECT @psno, CASE note_type WHEN 'DEBIT' THEN 'DEBIT_NOTE' ELSE 'CREDIT_NOTE' END, note_sno, amount FROM @notes;

        -- journal
        DECLARE @com INT, @div INT, @brn INT, @dept INT, @j INT;
        SELECT TOP 1 @com = i.com_sno, @div = i.div_sno, @brn = i.brn_sno, @dept = i.dept_sno
        FROM @inv x JOIN dbo.invoice_info i ON i.invoice_sno = x.invoice_sno;
        INSERT INTO dbo.acct_journal (journal_date, source_type, source_sno, narration, com_sno, div_sno, brn_sno, dept_sno, created_by)
        VALUES (@pdate, 'PAYMENT', @psno, N'Payment ' + @pno, @com, @div, @brn, @dept, @by);
        SET @j = SCOPE_IDENTITY();
        UPDATE dbo.acct_journal SET journal_no = 'JV-' + RIGHT('000000' + CAST(@j AS VARCHAR(6)), 6) WHERE journal_sno = @j;

        DECLARE @jl TABLE (head_sno INT, debit DECIMAL(18,2), credit DECIMAL(18,2));
        INSERT INTO @jl VALUES (@h_pay, @gross + @cn, 0);
        IF @tds > 0      INSERT INTO @jl VALUES (@h_tds, 0, @tds);
        IF @advTotal > 0 INSERT INTO @jl VALUES (@h_adv, 0, @advTotal);
        IF @net > 0      INSERT INTO @jl VALUES (@h_bank, 0, @net);
        IF @dn > 0       INSERT INTO @jl VALUES (@h_dn, 0, @dn);
        IF @cn > 0       BEGIN INSERT INTO @jl VALUES (@h_dn, @cn, 0); INSERT INTO @jl VALUES (@h_pay, 0, @cn); END
        IF (SELECT SUM(debit) - SUM(credit) FROM @jl) <> 0 THROW 55020, 'Payment journal is not balanced.', 1;
        INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit, vendor_sno) SELECT @j, head_sno, debit, credit, @v FROM @jl;
        UPDATE dbo.payment_info SET journal_sno = @j WHERE payment_sno = @psno;

        COMMIT TRANSACTION;
        SELECT @psno AS payment_sno, @pno AS payment_no, @gross AS gross_amount, @tds AS tds_amount, @advTotal AS advance_adjusted,
               @dn AS debit_notes, @cn AS credit_notes, @net AS net_paid, @j AS journal_sno, 'SUCCESS' AS result;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END