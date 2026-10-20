import React, { useEffect, useMemo, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Checkbox } from '@/components/ui/checkbox';
import { Input } from '@/components/ui/input';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import { Wallet, Search, Send, RefreshCw, Package } from 'lucide-react';
import { FormSection, PageHeader } from '@/CustomComponent/PageComponents';
import { CustomInputField } from '@/CustomComponent/InputComponents/CustomInputField';
import axios from 'axios';
import { toast } from 'sonner';
import { usePermissions } from '@/globalState/hooks/usePermissions';
import { useMasterOptions } from '@/hooks/ReUsableHook/useMasterOptions';
import { getErrorMessage } from '@/lib/errors';
import {
  payNetBills, payNetGrnPending, payNetAdjustments, payNetPreview, payNetRelease,
  type GrnPendingPayment, type PayableBillNet, type PaymentAdjustments, type NetPreview,
} from '@/Services/GrnService/paymentNetApi';

const MODE_OPTIONS = [
  { label: 'NEFT', value: 'NEFT' },
  { label: 'RTGS', value: 'RTGS' },
  { label: 'Cheque', value: 'Cheque' },
  { label: 'Cash', value: 'Cash' },
  { label: 'UPI', value: 'UPI' },
  { label: 'DD', value: 'DD' },
];

const money = (n: number | null | undefined) =>
  `₹${Number(n ?? 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

/** Why a bill cannot be selected yet (empty = payable). */
const blockReason = (b: PayableBillNet): string => {
  if (b.grn_state === 'Pending approval') return 'GRN is awaiting approval';
  if (b.grn_state === 'No GRN') return 'No approved GRN for this PO';
  if (b.on_hold_2b) return 'Not in GSTR-2B yet - Accounts can release the hold on the GSTR-2B screen';
  return '';
};

const grnBadge = (b: PayableBillNet) => {
  if (b.grn_state === 'Done') return <Badge className="bg-green-100 text-green-800 text-[10px]">GRN done</Badge>;
  if (b.grn_state === 'NA') return <Badge variant="secondary" className="text-[10px]">Service</Badge>;
  return <Badge variant="destructive" className="text-[10px]">{b.grn_state}</Badge>;
};

const itcBadge = (b: PayableBillNet) => {
  if (!b.gst_supplier) return <Badge variant="secondary" className="text-[10px]">No GSTIN</Badge>;
  if (b.itc_status === 'Eligible') return <Badge className="bg-green-100 text-green-800 text-[10px]">In 2B</Badge>;
  if (b.itc_status === 'Ineligible') return <Badge className="bg-amber-100 text-amber-800 text-[10px]">In 2B · no ITC</Badge>;
  if (b.payment_hold_override === 'Y') return <Badge className="bg-blue-100 text-blue-800 text-[10px]">Hold released</Badge>;
  return <Badge variant="destructive" className="text-[10px]">Not in 2B</Badge>;
};

const PaymentPage: React.FC = () => {
  const { canCreate, canEdit } = usePermissions();
  const permissionComponent = 'PaymentPage';
  const canSubmit = canCreate(permissionComponent) || canEdit(permissionComponent);

  const { options } = useMasterOptions(['VendorMaster']);

  const [vendorSno, setVendorSno] = useState<string>('');
  const [bills, setBills] = useState<PayableBillNet[]>([]);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [grnPending, setGrnPending] = useState<GrnPendingPayment[]>([]);
  const [searched, setSearched] = useState(false);
  const [searching, setSearching] = useState(false);
  const [releasing, setReleasing] = useState(false);
  const [paymentDetails, setPaymentDetails] = useState<Record<string, any>>({ mode: 'NEFT', payment_date: new Date().toISOString().slice(0, 10) });

  // adjustments for the selected supplier
  const [adj, setAdj] = useState<PaymentAdjustments | null>(null);
  const [advAmt, setAdvAmt] = useState<Record<number, string>>({});
  const [dnPick, setDnPick] = useState<Set<number>>(new Set());
  const [cnPick, setCnPick] = useState<Set<number>>(new Set());
  const [applyTds, setApplyTds] = useState(true);
  const [tdsSection, setTdsSection] = useState<Record<number, string>>({});   // invoice_sno -> section ('' = none)
  const [preview, setPreview] = useState<NetPreview | null>(null);
  const [previewError, setPreviewError] = useState('');

  const handleSearch = async () => {
    setSearching(true);
    setSearched(true);
    setSelected(new Set());
    try {
      const res = await axios.get(payNetBills, { params: vendorSno ? { vendor_sno: vendorSno } : {} });
      const rows: PayableBillNet[] = res?.data?.data ?? [];
      setBills(rows);
      setTdsSection(Object.fromEntries(rows.map((r) => [r.invoice_sno, r.tds_section_code ?? ''])));
      // GRN done but no supplier invoice yet - informational, so a failure here must not hide the bills.
      try {
        const pend = await axios.get(payNetGrnPending, { params: vendorSno ? { vendor_sno: vendorSno } : {} });
        setGrnPending(pend?.data?.data ?? []);
      } catch {
        setGrnPending([]);
      }
    } catch (error) {
      toast.error(getErrorMessage(error, 'Failed to load payable bills'));
      setBills([]);
    } finally {
      setSearching(false);
    }
  };

  const selectedBills = useMemo(() => bills.filter((b) => selected.has(b.bill_sno)), [bills, selected]);
  const selectedVendorSno = selectedBills[0]?.vendor_sno ?? null;
  const selectedTotal = selectedBills.reduce((sum, b) => sum + (Number(b.outstanding) || 0), 0);

  const toggleRow = (bill: PayableBillNet) => {
    if (blockReason(bill)) return;
    if (selectedVendorSno && selectedVendorSno !== bill.vendor_sno && !selected.has(bill.bill_sno)) {
      toast.error('A payment release covers one supplier at a time - clear the current selection first.');
      return;
    }
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(bill.bill_sno)) next.delete(bill.bill_sno); else next.add(bill.bill_sno);
      return next;
    });
  };

  const payable = bills.filter((b) => !blockReason(b));
  const allSelected = payable.length > 0 && selected.size === payable.length;
  const toggleAll = () => {
    if (allSelected) { setSelected(new Set()); return; }
    const vendorToUse = payable[0]?.vendor_sno;
    setSelected(new Set(payable.filter((b) => b.vendor_sno === vendorToUse).map((b) => b.bill_sno)));
  };

  // load advances / notes when the supplier of the selection changes
  useEffect(() => {
    setAdvAmt({});
    setDnPick(new Set());
    setCnPick(new Set());
    setPreview(null);
    if (!selectedVendorSno) { setAdj(null); return; }
    axios.get(payNetAdjustments(selectedVendorSno))
      .then((res) => {
        const data: PaymentAdjustments = res.data?.data;
        setAdj(data);
        setDnPick(new Set(data.debitNotes.map((n) => n.note_sno)));     // pending notes are applied by default
        setCnPick(new Set(data.creditNotes.map((n) => n.note_sno)));
      })
      .catch((e) => toast.error(getErrorMessage(e, 'Failed to load advances and notes')));
  }, [selectedVendorSno]);

  const buildBody = () => ({
    vendor_sno: selectedVendorSno,
    payment_date: paymentDetails.payment_date,
    mode: paymentDetails.mode,
    bank_account: paymentDetails.bank_account,
    reference_no: paymentDetails.reference_no,
    remarks: paymentDetails.remarks,
    apply_tds: applyTds,
    allocations: selectedBills.map((b) => ({ invoice_alloc_sno: b.bill_sno, amount: Number(b.outstanding) })),
    advances: Object.entries(advAmt).filter(([, v]) => Number(v) > 0).map(([id, v]) => ({ advance_sno: Number(id), amount: Number(v) })),
    notes: [
      ...[...dnPick].map((id) => ({ type: 'DEBIT', note_sno: id })),
      ...[...cnPick].map((id) => ({ type: 'CREDIT', note_sno: id })),
    ],
    tds_overrides: [...new Set(selectedBills.map((b) => b.invoice_sno))].map((id) => ({ invoice_sno: id, section: tdsSection[id] ?? '' })),
  });

  // live preview of the amount to pay
  useEffect(() => {
    if (!selectedVendorSno || selectedBills.length === 0 || !adj) { setPreview(null); return; }
    let cancelled = false;
    const t = setTimeout(async () => {
      try {
        const res = await axios.post(payNetPreview, buildBody());
        if (cancelled) return;
        setPreview(res.data?.data ?? null);
        setPreviewError('');
      } catch (e) {
        if (cancelled) return;
        setPreview(null);
        setPreviewError(getErrorMessage(e, 'Could not work out the amount'));
      }
    }, 300);
    return () => { cancelled = true; clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selected, advAmt, dnPick, cnPick, applyTds, tdsSection, paymentDetails.payment_date, adj]);

  const toggleSet = (set: Set<number>, id: number, setter: (s: Set<number>) => void) => {
    const next = new Set(set);
    if (next.has(id)) next.delete(id); else next.add(id);
    setter(next);
  };

  const handleReleasePayment = async () => {
    if (selectedBills.length === 0 || !selectedVendorSno) return;
    setReleasing(true);
    try {
      const res = await axios.post(payNetRelease, buildBody());
      const row = res?.data?.data;
      toast.success(row?.payment_no ? `Payment ${row.payment_no} released - pay ${money(row.net_paid)} to the supplier` : 'Payment released');
      await handleSearch();
    } catch (error) {
      toast.error(getErrorMessage(error, 'Failed to release payment. Try again.'));
    } finally {
      setReleasing(false);
    }
  };

  const sum = preview?.summary;

  return (
    <div className="flex flex-col h-full bg-muted/30 min-h-full">
      <PageHeader
        icon={Wallet}
        title="Payment"
        description="Pick GRN-done, 2B-cleared invoices; TDS, advances and debit/credit notes are netted to the amount payable"
      />

      <div className="container mx-auto py-6 px-4 space-y-6">
        <Card className="shadow-md">
          <CardContent className="pt-6 space-y-4">
            <FormSection icon={Search} title="Find Payable Bills">
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-x-4 gap-y-5">
                <div className="flex flex-col">
                  <CustomInputField
                    field="vendor_sno"
                    label="Supplier (optional)"
                    type="search-select"
                    options={options?.VendorMaster}
                    value={vendorSno}
                    onChange={(value) => setVendorSno(String(value))}
                    placeholder="All suppliers"
                    className="h-10"
                  />
                </div>
              </div>
              <div className="flex justify-end pt-1">
                <Button type="button" onClick={handleSearch} disabled={searching} className="h-9">
                  {searching ? <RefreshCw className="h-4 w-4 mr-2 animate-spin" /> : <Search className="h-4 w-4 mr-2" />}
                  Search
                </Button>
              </div>
            </FormSection>
          </CardContent>
        </Card>

        {searched && (
          <Card className="shadow-md">
            <CardContent className="pt-6 space-y-4">
              <div className="flex items-center justify-between">
                <h3 className="text-sm font-semibold text-foreground flex items-center gap-2">
                  Payable Bills<Badge variant="secondary">{bills.length}</Badge>
                </h3>
                {selected.size > 0 && (
                  <span className="text-xs text-muted-foreground">
                    {selected.size} selected - bills total {money(selectedTotal)}
                  </span>
                )}
              </div>

              {bills.length > 0 ? (
                <div className="border rounded-xl overflow-x-auto">
                  <Table>
                    <TableHeader>
                      <TableRow className="bg-muted/50 hover:bg-muted/50">
                        <TableHead className="w-10"><Checkbox checked={allSelected} onCheckedChange={toggleAll} /></TableHead>
                        <TableHead className="text-xs">Bill No</TableHead>
                        <TableHead className="text-xs">Supplier</TableHead>
                        <TableHead className="text-xs">PO No</TableHead>
                        <TableHead className="text-xs">Invoice Date</TableHead>
                        <TableHead className="text-xs">GRN</TableHead>
                        <TableHead className="text-xs">GSTR-2B</TableHead>
                        <TableHead className="text-xs">TDS section</TableHead>
                        <TableHead className="text-xs text-right">Outstanding</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {bills.map((bill) => {
                        const reason = blockReason(bill);
                        const isSel = selected.has(bill.bill_sno);
                        return (
                          <TableRow key={bill.bill_sno} title={reason} className={`${isSel ? 'bg-blue-50 dark:bg-blue-950/20' : ''} ${reason ? 'opacity-60' : ''}`}>
                            <TableCell>
                              <Checkbox checked={isSel} disabled={!!reason} onCheckedChange={() => toggleRow(bill)} />
                            </TableCell>
                            <TableCell className="text-xs font-medium">{bill.bill_no}</TableCell>
                            <TableCell className="text-xs">{bill.vendor_name}</TableCell>
                            <TableCell className="text-xs">{bill.po_no ?? '—'}</TableCell>
                            <TableCell className="text-xs">{String(bill.invoice_date).slice(0, 10)}</TableCell>
                            <TableCell>{grnBadge(bill)}</TableCell>
                            <TableCell>{itcBadge(bill)}</TableCell>
                            <TableCell>
                              <select
                                className="h-7 rounded-md border bg-background px-1 text-xs"
                                value={tdsSection[bill.invoice_sno] ?? ''}
                                disabled={!isSel}
                                onChange={(e) => setTdsSection((p) => ({ ...p, [bill.invoice_sno]: e.target.value }))}
                              >
                                <option value="">No TDS</option>
                                {(adj?.tdsSections ?? []).filter((t) => t.is_active === 'Y').map((t) => (
                                  <option key={t.section_code} value={t.section_code}>{t.section_code}</option>
                                ))}
                              </select>
                            </TableCell>
                            <TableCell className="text-xs text-right font-medium">{money(bill.outstanding)}</TableCell>
                          </TableRow>
                        );
                      })}
                    </TableBody>
                  </Table>
                </div>
              ) : (
                <div className="text-center py-10 text-muted-foreground border rounded-xl bg-muted/10">
                  <Package className="h-10 w-10 mx-auto mb-3 opacity-20" />
                  <p className="text-sm">No payable bills found.</p>
                </div>
              )}
              {bills.some((b) => blockReason(b)) && (
                <p className="text-xs text-muted-foreground">Greyed bills are not payable yet - hover a row to see why.</p>
              )}
            </CardContent>
          </Card>
        )}

        {searched && grnPending.length > 0 && (
          <Card className="shadow-md">
            <CardContent className="pt-6 space-y-4">
              <h3 className="text-sm font-semibold text-foreground flex items-center gap-2">
                Pending payment - goods received, invoice awaited<Badge variant="secondary">{grnPending.length}</Badge>
              </h3>
              <p className="text-xs text-muted-foreground">
                GST is worked on the quantity actually received (less on a shortage, more on an excess). Shortage debit notes are not deducted again. TDS is an estimate for goods (194Q); the final section is chosen at payment. Enter the supplier's invoice on the Invoice screen (allocate and match it) and the bill moves to Payable Bills above.
              </p>
              <div className="border rounded-xl overflow-x-auto">
                <Table>
                  <TableHeader>
                    <TableRow className="bg-muted/50 hover:bg-muted/50">
                      <TableHead className="text-xs">Supplier / PO</TableHead>
                      <TableHead className="text-xs">GRN</TableHead>
                      <TableHead className="text-xs text-right">Qty (ordered / received)</TableHead>
                      <TableHead className="text-xs text-right">Taxable</TableHead>
                      <TableHead className="text-xs text-right">GST</TableHead>
                      <TableHead className="text-xs text-right">Gross</TableHead>
                      <TableHead className="text-xs text-right">Debit notes</TableHead>
                      <TableHead className="text-xs text-right">Credit notes</TableHead>
                      <TableHead className="text-xs text-right">Advances paid</TableHead>
                      <TableHead className="text-xs text-right">TDS payable (est.)</TableHead>
                      <TableHead className="text-xs text-right">Net payable</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {grnPending.map((g) => {
                      const qv = Number(g.qty_variance) || 0;
                      const gv = Number(g.gst_variance) || 0;
                      return (
                        <TableRow key={g.po_basic_sno}>
                          <TableCell className="text-xs">
                            <p className="font-medium">{g.vendor_name ?? '-'}</p>
                            <p className="text-muted-foreground">{g.po_no}</p>
                          </TableCell>
                          <TableCell className="text-xs">
                            <p>{g.grn_nos}</p>
                            <p className="text-muted-foreground">{g.last_received_date ? new Date(g.last_received_date).toLocaleDateString('en-IN', { timeZone: 'UTC' }) : '-'}</p>
                          </TableCell>
                          <TableCell className="text-xs text-right tabular-nums">
                            {Number(g.ordered_qty)} / {Number(g.received_qty)}
                            {qv < 0 && <p className="text-amber-700">Shortage {Math.abs(qv)}</p>}
                            {qv > 0 && <p className="text-blue-700">Excess {qv}</p>}
                          </TableCell>
                          <TableCell className="text-xs text-right tabular-nums">{money(g.taxable_value)}</TableCell>
                          <TableCell className="text-xs text-right tabular-nums">
                            {money(g.gst_value)}
                            {gv !== 0 && (
                              <p className={gv < 0 ? 'text-amber-700' : 'text-blue-700'}>
                                {gv < 0 ? 'less ' : 'more '}{money(Math.abs(gv))} for {gv < 0 ? 'shortage' : 'excess'}
                              </p>
                            )}
                          </TableCell>
                          <TableCell className="text-xs text-right tabular-nums font-medium">{money(g.grn_value)}</TableCell>
                          <TableCell className="text-xs text-right tabular-nums">{Number(g.debit_notes) > 0 ? `- ${money(g.debit_notes)}` : '-'}</TableCell>
                          <TableCell className="text-xs text-right tabular-nums">{Number(g.credit_notes) > 0 ? `+ ${money(g.credit_notes)}` : '-'}</TableCell>
                          <TableCell className="text-xs text-right tabular-nums">{Number(g.advances) > 0 ? `- ${money(g.advances)}` : '-'}</TableCell>
                          <TableCell className="text-xs text-right tabular-nums">{Number(g.tds_estimate) > 0 ? `- ${money(g.tds_estimate)}` : '-'}</TableCell>
                          <TableCell className="text-xs text-right tabular-nums font-semibold">{money(g.net_payable)}</TableCell>
                        </TableRow>
                      );
                    })}
                  </TableBody>
                </Table>
              </div>
            </CardContent>
          </Card>
        )}

        {searched && selected.size > 0 && adj && (
          <Card className="shadow-md">
            <CardContent className="pt-6 space-y-5">
              <FormSection icon={Wallet} title="Adjustments for this supplier">
                <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
                  <div className="space-y-2">
                    <p className="text-xs font-semibold">Advances paid</p>
                    {adj.advances.length === 0 && <p className="text-xs text-muted-foreground">None outstanding</p>}
                    {adj.advances.map((a) => (
                      <div key={a.advance_sno} className="flex items-center justify-between gap-2 rounded-md border p-2">
                        <div className="text-xs">
                          <p className="font-medium">{a.advance_no}</p>
                          <p className="text-muted-foreground">balance {money(a.balance)}</p>
                        </div>
                        <div className="flex items-center gap-1">
                          <Input
                            className="h-8 w-28 text-right text-xs" inputMode="decimal" placeholder="Adjust"
                            value={advAmt[a.advance_sno] ?? ''}
                            onChange={(e) => setAdvAmt((p) => ({ ...p, [a.advance_sno]: e.target.value.replace(/[^\d.]/g, '') }))}
                          />
                          <Button type="button" size="sm" variant="ghost" className="h-8 text-xs" onClick={() => setAdvAmt((p) => ({ ...p, [a.advance_sno]: String(a.balance) }))}>Max</Button>
                        </div>
                      </div>
                    ))}
                  </div>

                  <div className="space-y-2">
                    <p className="text-xs font-semibold">Debit notes raised (reduce payment)</p>
                    {adj.debitNotes.length === 0 && <p className="text-xs text-muted-foreground">None pending</p>}
                    {adj.debitNotes.map((n) => (
                      <label key={n.note_sno} className="flex items-center justify-between gap-2 rounded-md border p-2 text-xs">
                        <span className="flex items-center gap-2">
                          <Checkbox checked={dnPick.has(n.note_sno)} onCheckedChange={() => toggleSet(dnPick, n.note_sno, setDnPick)} />
                          <span><span className="font-medium">{n.note_no}</span>{n.remarks ? <span className="block text-muted-foreground">{n.remarks}</span> : null}</span>
                        </span>
                        <span>- {money(n.amount)}</span>
                      </label>
                    ))}
                  </div>

                  <div className="space-y-2">
                    <p className="text-xs font-semibold">Credit notes (add to payment)</p>
                    {adj.creditNotes.length === 0 && <p className="text-xs text-muted-foreground">None pending</p>}
                    {adj.creditNotes.map((n) => (
                      <label key={n.note_sno} className="flex items-center justify-between gap-2 rounded-md border p-2 text-xs">
                        <span className="flex items-center gap-2">
                          <Checkbox checked={cnPick.has(n.note_sno)} onCheckedChange={() => toggleSet(cnPick, n.note_sno, setCnPick)} />
                          <span><span className="font-medium">{n.note_no}</span>{n.remarks ? <span className="block text-muted-foreground">{n.remarks}</span> : null}</span>
                        </span>
                        <span>+ {money(n.amount)}</span>
                      </label>
                    ))}
                  </div>
                </div>
                <label className="mt-3 flex items-center gap-2 text-xs">
                  <Checkbox checked={applyTds} onCheckedChange={(v) => setApplyTds(v === true)} /> Deduct TDS where a section is chosen
                </label>
              </FormSection>

              {/* amount to pay */}
              <div className="rounded-xl border bg-muted/20 p-4">
                {previewError && <p className="text-sm text-red-600">{previewError}</p>}
                {sum && (
                  <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
                    <div className="space-y-1 text-sm">
                      <div className="flex justify-between"><span>Bills selected</span><span>{money(sum.gross_amount)}</span></div>
                      <div className="flex justify-between text-red-700"><span>Less TDS</span><span>- {money(sum.tds_amount)}</span></div>
                      <div className="flex justify-between text-red-700"><span>Less advance adjusted</span><span>- {money(sum.advance_adjusted)}</span></div>
                      <div className="flex justify-between text-red-700"><span>Less debit notes</span><span>- {money(sum.debit_notes)}</span></div>
                      <div className="flex justify-between text-green-700"><span>Add credit notes</span><span>+ {money(sum.credit_notes)}</span></div>
                      <div className="flex justify-between border-t pt-2 text-base font-semibold"><span>Amount to pay supplier</span><span>{money(sum.net_paid)}</span></div>
                    </div>
                    <div className="text-xs">
                      <p className="mb-1 font-semibold">TDS by bill</p>
                      {(preview?.invoices ?? []).map((l) => (
                        <div key={l.invoice_sno} className="flex justify-between border-b py-1">
                          <span>{l.invoice_no} {l.tds_section ? `· ${l.tds_section} @ ${l.tds_rate_pct ?? 0}%` : '· no TDS'}</span>
                          <span>{money(l.tds_amount)}</span>
                        </div>
                      ))}
                    </div>
                  </div>
                )}
                {!sum && !previewError && <p className="text-sm text-muted-foreground">Working out the amount…</p>}
              </div>

              <FormSection icon={Wallet} title="Payment Details">
                <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-x-4 gap-y-5">
                  <div className="flex flex-col">
                    <CustomInputField
                      field="payment_date" label="Payment Date" require type="date"
                      value={paymentDetails.payment_date ?? ''}
                      onChange={(value) => setPaymentDetails((prev) => ({ ...prev, payment_date: value }))}
                      className="h-10"
                    />
                  </div>
                  <div className="flex flex-col">
                    <CustomInputField
                      field="mode" label="Mode" require type="select" options={MODE_OPTIONS}
                      value={paymentDetails.mode ?? 'NEFT'}
                      onChange={(value) => setPaymentDetails((prev) => ({ ...prev, mode: value }))}
                      className="h-10"
                    />
                  </div>
                  <div className="flex flex-col">
                    <CustomInputField
                      field="reference_no" label="Reference No" type="text"
                      value={paymentDetails.reference_no ?? ''}
                      onChange={(value) => setPaymentDetails((prev) => ({ ...prev, reference_no: value }))}
                      className="h-10"
                    />
                  </div>
                  <div className="flex flex-col">
                    <CustomInputField
                      field="bank_account" label="Bank Account" type="text"
                      value={paymentDetails.bank_account ?? ''}
                      onChange={(value) => setPaymentDetails((prev) => ({ ...prev, bank_account: value }))}
                      className="h-10"
                    />
                  </div>
                </div>
              </FormSection>

              <div className="flex items-center justify-end pt-4 border-t">
                {canSubmit && (
                  <Button
                    type="button"
                    onClick={handleReleasePayment}
                    disabled={releasing || !sum || !paymentDetails.mode || !paymentDetails.payment_date}
                    className="bg-blue-600 hover:bg-blue-700 h-9"
                  >
                    {releasing ? <RefreshCw className="h-4 w-4 mr-2 animate-spin" /> : <Send className="h-4 w-4 mr-2" />}
                    Release Payment ({money(sum?.net_paid ?? 0)})
                  </Button>
                )}
              </div>
            </CardContent>
          </Card>
        )}
      </div>
    </div>
  );
};

export default PaymentPage;
