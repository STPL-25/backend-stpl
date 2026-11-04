import React, { useEffect, useMemo, useState } from 'react';
import axios from 'axios';
import { toast } from 'sonner';
import { Loader2, Info, AlertTriangle } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { createInvoice, allocateInvoice, matchInvoice, getPoItemsForAllocation } from '@/Services/Api';
import { getErrorMessage } from '@/lib/errors';
import type { LedgerGrn, LedgerInvoice } from '@/Services/GrnService/paymentNetApi';
import type { InvoiceType, PoItemForAllocation } from '@/Application/Invoice/Invoice/types';

const money = (n: number) => `₹${n.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const norm = (v: string | null | undefined) => String(v ?? '').trim().toUpperCase();

interface Props {
  open: boolean;
  poBasicSno: number | null;
  poNo: string | null;
  vendorSno: number | null;
  vendorName: string | null;
  /** Gross value of goods received (taxable + GST) - shown as a hint for the invoice amount. */
  suggestedAmount?: number | null;
  existingInvoices: LedgerInvoice[];   // this supplier's invoices (duplicate check)
  existingGrns: LedgerGrn[];
  onClose: () => void;
  onDone: () => void;
}

const lineLabel = (i: PoItemForAllocation) =>
  i.po_section === 'SERVICE' ? (i.service_name ?? `Service line #${i.po_item_sno}`) : (i.prod_name ?? `Material line #${i.po_item_sno}`);

const EnterInvoiceDialog: React.FC<Props> = ({
  open, poBasicSno, poNo, vendorSno, vendorName, suggestedAmount, existingInvoices, existingGrns, onClose, onDone,
}) => {
  const today = new Date().toISOString().slice(0, 10);
  const [invoiceNo, setInvoiceNo] = useState('');
  const [invoiceDate, setInvoiceDate] = useState(today);
  const [dueDate, setDueDate] = useState('');
  const [amount, setAmount] = useState('');
  const [remarks, setRemarks] = useState('');
  const [file, setFile] = useState<File | null>(null);
  const [items, setItems] = useState<PoItemForAllocation[]>([]);
  const [loadingItems, setLoadingItems] = useState(false);
  const [alloc, setAlloc] = useState<Record<number, string>>({});
  const [touched, setTouched] = useState(false);   // user edited the split by hand -> stop auto-splitting
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    setInvoiceNo(''); setInvoiceDate(today); setDueDate(''); setRemarks(''); setFile(null);
    setAmount(suggestedAmount && suggestedAmount > 0 ? String(Math.round(suggestedAmount * 100) / 100) : '');
    setAlloc({}); setTouched(false);
    if (!poBasicSno) return;
    setLoadingItems(true);
    axios.get(getPoItemsForAllocation(poBasicSno))
      .then((res) => setItems(res.data?.data ?? []))
      .catch((e) => { toast.error(getErrorMessage(e, 'Failed to load PO lines')); setItems([]); })
      .finally(() => setLoadingItems(false));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, poBasicSno]);

  const amt = Number(amount) || 0;

  // Auto-split the invoice amount over the PO lines in proportion to what is still unbilled on each line.
  useEffect(() => {
    if (touched || items.length === 0) return;
    const remaining = items.map((i) => Math.max(0, Number(i.line_value) - Number(i.already_allocated || 0)));
    const base = remaining.some((r) => r > 0) ? remaining : items.map((i) => Number(i.line_value) || 0);
    const total = base.reduce((a, b) => a + b, 0);
    const next: Record<number, string> = {};
    if (amt > 0 && total > 0) {
      let given = 0; let biggest = 0;
      items.forEach((it, idx) => {
        const v = Math.round((amt * base[idx] / total) * 100) / 100;
        next[it.po_item_sno] = v ? String(v) : '';
        given += v;
        if (base[idx] > base[biggest]) biggest = idx;
      });
      const diff = Math.round((amt - given) * 100) / 100;   // rounding remainder goes on the biggest line
      if (diff !== 0) next[items[biggest].po_item_sno] = String(Math.round(((Number(next[items[biggest].po_item_sno]) || 0) + diff) * 100) / 100);
    }
    setAlloc(next);
  }, [amt, items, touched]);

  const allocTotal = useMemo(() => Object.values(alloc).reduce((s, v) => s + (Number(v) || 0), 0), [alloc]);
  const diff = amt - allocTotal;
  const balanced = amt > 0 && Math.abs(diff) <= 1;

  const dupInvoice = invoiceNo.trim()
    ? existingInvoices.find((i) => i.vendor_sno === vendorSno && norm(i.supplier_invoice_no) === norm(invoiceNo))
    : undefined;
  const dupGrn = invoiceNo.trim() && !dupInvoice
    ? existingGrns.find((g) => g.vendor_sno === vendorSno && g.po_basic_sno !== poBasicSno && norm(g.invoice_no) === norm(invoiceNo))
    : undefined;

  const canSave = !!poBasicSno && !!vendorSno && invoiceNo.trim().length > 0 && !!invoiceDate && balanced && !dupInvoice && !saving;

  const handleSave = async () => {
    if (!canSave || !poBasicSno || !vendorSno) return;
    const rows = items
      .map((i) => ({ item: i, amount: Number(alloc[i.po_item_sno]) || 0 }))
      .filter((r) => r.amount > 0);
    const buckets = new Set(rows.map((r) => r.item.po_section));
    const invoice_type: InvoiceType = buckets.size > 1 ? 'COMPOSITE' : buckets.has('SERVICE') ? 'SERVICE' : 'MATERIAL';

    setSaving(true);
    let invoiceSno: number | null = null;
    try {
      const fd = new FormData();
      fd.append('vendor_invoice_no', invoiceNo.trim());
      fd.append('vendor_sno', String(vendorSno));
      fd.append('po_basic_sno', String(poBasicSno));
      fd.append('invoice_date', invoiceDate);
      if (dueDate) fd.append('due_date', dueDate);
      fd.append('invoice_amount', String(amt));
      fd.append('invoice_type', invoice_type);
      fd.append('source_type', 'STANDARD');
      if (remarks) fd.append('remarks', remarks);
      if (file) fd.append('invoice_file', file);
      const res = await axios.post(createInvoice, fd, { headers: { 'Content-Type': 'multipart/form-data' } });
      invoiceSno = res.data?.data?.[0]?.invoice_sno ?? null;
      const invoiceNoOut = res.data?.data?.[0]?.invoice_no ?? '';
      if (!invoiceSno) throw new Error('Invoice was created but its id was not returned.');

      await axios.post(allocateInvoice, {
        invoice_sno: invoiceSno,
        allocations: rows.map((r) => ({ po_item_sno: r.item.po_item_sno, allocated_amount: r.amount })),
      });

      try {
        await axios.post(matchInvoice, { invoice_sno: invoiceSno });
        toast.success(`Invoice ${invoiceNoOut} entered, allocated and matched - it is now listed for payment`);
      } catch (e) {
        toast.warning(`Invoice ${invoiceNoOut} entered and allocated, but matching failed: ${getErrorMessage(e, 'try Match on the Invoice screen')}`);
      }
      onDone();
      onClose();
    } catch (e) {
      toast.error(invoiceSno
        ? `Invoice was saved but could not be allocated (${getErrorMessage(e, 'error')}). Finish it on the Invoice screen.`
        : getErrorMessage(e, 'Failed to save invoice'));
      if (invoiceSno) onDone();
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={(o) => !o && !saving && onClose()}>
      <DialogContent className="flex max-h-[92vh] w-[calc(100%-1rem)] flex-col gap-0 overflow-hidden p-0 sm:w-full sm:max-w-3xl">
        <DialogHeader className="border-b px-4 py-4 pr-12 sm:px-6">
          <DialogTitle>Enter supplier invoice</DialogTitle>
          <p className="text-sm text-muted-foreground">{vendorName ?? 'Supplier'} · {poNo ?? 'PO'}</p>
        </DialogHeader>

        <div className="flex-1 space-y-4 overflow-y-auto px-4 py-4 sm:px-6">
          <div className="flex gap-2 rounded-md border border-blue-200 bg-blue-50 p-3 text-sm text-blue-900">
            <Info className="mt-0.5 h-4 w-4 shrink-0" />
            <span>Saves the invoice, splits it across the PO lines and matches it against the GRN, so it appears on this page ready to select and pay.</span>
          </div>

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div className="space-y-1.5">
              <Label>Supplier invoice no *</Label>
              <Input value={invoiceNo} onChange={(e) => setInvoiceNo(e.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label>Invoice amount (incl. GST) *</Label>
              <Input type="number" min={0} value={amount} onChange={(e) => { setAmount(e.target.value); setTouched(false); }} />
              {suggestedAmount ? <p className="text-[11px] text-muted-foreground">Goods received on this PO: {money(suggestedAmount)}</p> : null}
            </div>
            <div className="space-y-1.5">
              <Label>Invoice date *</Label>
              <Input type="date" value={invoiceDate} onChange={(e) => setInvoiceDate(e.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label>Due date</Label>
              <Input type="date" value={dueDate} onChange={(e) => setDueDate(e.target.value)} />
            </div>
            <div className="space-y-1.5 sm:col-span-2">
              <Label>Invoice file</Label>
              <Input type="file" onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
            </div>
            <div className="space-y-1.5 sm:col-span-2">
              <Label>Remarks</Label>
              <Input value={remarks} onChange={(e) => setRemarks(e.target.value)} />
            </div>
          </div>

          {dupInvoice && (
            <div className="flex gap-2 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
              <span>Duplicate - this supplier already has invoice <b>{dupInvoice.supplier_invoice_no}</b> ({dupInvoice.invoice_no}, PO {dupInvoice.po_no ?? '—'}, {dupInvoice.payment_status}). It cannot be entered twice.</span>
            </div>
          )}
          {dupGrn && (
            <div className="flex gap-2 rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
              <span>This invoice no was captured on GRN {dupGrn.grn_no} of another PO ({dupGrn.po_no ?? '—'}). Check it is not the same bill.</span>
            </div>
          )}

          <div>
            <p className="mb-1.5 text-xs font-semibold">Split across PO lines</p>
            {loadingItems ? (
              <div className="flex items-center justify-center gap-2 py-6 text-muted-foreground"><Loader2 className="h-4 w-4 animate-spin" /><span className="text-sm">Loading PO lines…</span></div>
            ) : items.length === 0 ? (
              <p className="text-sm text-muted-foreground">No PO lines found for this PO.</p>
            ) : (
              <div className="overflow-x-auto rounded-md border">
                <Table>
                  <TableHeader>
                    <TableRow className="bg-muted/40">
                      <TableHead className="text-xs">Line</TableHead>
                      <TableHead className="text-xs">Bucket</TableHead>
                      <TableHead className="text-xs text-right">Line value</TableHead>
                      <TableHead className="text-xs text-right">Already billed</TableHead>
                      <TableHead className="text-xs text-right">This invoice</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {items.map((i) => (
                      <TableRow key={i.po_item_sno}>
                        <TableCell className="text-xs">{lineLabel(i)}</TableCell>
                        <TableCell><Badge variant="outline" className="text-[10px]">{i.po_section}</Badge></TableCell>
                        <TableCell className="text-xs text-right tabular-nums">{money(Number(i.line_value) || 0)}</TableCell>
                        <TableCell className="text-xs text-right tabular-nums">{money(Number(i.already_allocated) || 0)}</TableCell>
                        <TableCell className="text-right">
                          <Input
                            type="number" min={0} className="inline-block h-8 w-32 text-right text-sm"
                            value={alloc[i.po_item_sno] ?? ''}
                            onChange={(e) => { setTouched(true); setAlloc((p) => ({ ...p, [i.po_item_sno]: e.target.value })); }}
                          />
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            )}
            <p className={`mt-2 text-xs ${balanced ? 'text-green-700' : 'text-red-600'}`}>
              Allocated {money(allocTotal)} of {money(amt)}
              {!balanced && amt > 0 && ` - ${diff > 0 ? 'short by' : 'over by'} ${money(Math.abs(diff))}`}
            </p>
          </div>
        </div>

        <DialogFooter className="border-t px-4 py-3 sm:px-6">
          <Button type="button" variant="outline" onClick={onClose} disabled={saving}>Cancel</Button>
          <Button type="button" onClick={handleSave} disabled={!canSave}>
            {saving ? <><Loader2 className="mr-2 h-4 w-4 animate-spin" />Saving…</> : 'Save invoice'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

export default EnterInvoiceDialog;
