import React, { useMemo, useState } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { ClipboardList, RefreshCw, Loader2, Send, History, Plus, Trash2, FileUp } from 'lucide-react';
import { PageHeader } from '@/CustomComponent/PageComponents';
import {
  getActiveCeilingAgreementsForBilling, createServiceBillRequest, getServiceBillRequests,
} from '@/Services/Api';
import { useMasterOptions } from '@/hooks/ReUsableHook/useMasterOptions';
import useFetch from '@/hooks/useFetchHook';
import usePost from '@/hooks/usePostHook';

interface CeilingAgreement {
  agreement_sno: number; agreement_no: string; service_sno: number; service_name: string;
  vendor_sno?: number; vendor_name?: string; ceiling_amount?: number; variance_tolerance_pct?: number;
  cadence_name?: string; period_start_date: string; period_end_date: string;
  com_sno: number; div_sno: number; brn_sno: number; dept_sno: number;
}

interface BillItem {
  service_sno: string; qty: string; uom_sno: string; unit_price: string; remarks: string;
}

interface BillItemRow {
  bill_request_item_sno: number; service_name?: string; qty: number; uom_name?: string; unit_price: number; amount: number;
}

interface BillRow {
  bill_request_sno: number; request_no: string; agreement_no?: string; service_name?: string;
  vendor_name?: string; billing_period_start?: string; billing_period_end?: string;
  invoice_no?: string; invoice_amount: number; status: string;
  po_no?: string; po_pdf_url?: string; created_by?: string; created_at?: string;
  items?: string | BillItemRow[];
}

const STATUS_LABELS: Record<string, string> = { P: 'Pending', A: 'Approved', R: 'Rejected' };
const STATUS_COLORS: Record<string, string> = {
  P: 'bg-amber-100 text-amber-700', A: 'bg-emerald-100 text-emerald-700', R: 'bg-red-100 text-red-700',
};

const dateOnly = (v?: string) => (v ? v.slice(0, 10) : '');
const inr = (n?: number) => `₹${Number(n ?? 0).toLocaleString('en-IN')}`;
const emptyItem = (): BillItem => ({ service_sno: '', qty: '1', uom_sno: '', unit_price: '', remarks: '' });

// ── Org cascade (Company -> Division -> Branch -> Department), plain selects ──
function OrgCascade({ options, value, onChange }: {
  options: any;
  value: { com_sno: string; div_sno: string; brn_sno: string; dept_sno: string };
  onChange: (v: { com_sno: string; div_sno: string; brn_sno: string; dept_sno: string }) => void;
}) {
  const divisionOptions = useMemo(
    () => (options?.DivisionMaster ?? []).filter((d: any) => !value.com_sno || String(d.com_sno) === value.com_sno),
    [options?.DivisionMaster, value.com_sno]
  );
  const branchOptions = useMemo(
    () => (options?.BranchMaster ?? []).filter((b: any) =>
      (!value.com_sno || String(b.com_sno) === value.com_sno) && (!value.div_sno || String(b.div_sno) === value.div_sno)),
    [options?.BranchMaster, value.com_sno, value.div_sno]
  );
  const deptOptions = useMemo(
    () => (options?.DeptMaster ?? []).filter((d: any) =>
      (!value.com_sno || String(d.com_sno) === value.com_sno) &&
      (!value.div_sno || String(d.div_sno) === value.div_sno) &&
      (!value.brn_sno || String(d.brn_sno) === value.brn_sno)),
    [options?.DeptMaster, value.com_sno, value.div_sno, value.brn_sno]
  );

  const sel = "flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm";

  return (
    <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
      <div>
        <Label className="text-xs">Company</Label>
        <select className={sel} value={value.com_sno} onChange={(e) => onChange({ com_sno: e.target.value, div_sno: '', brn_sno: '', dept_sno: '' })}>
          <option value="">Select…</option>
          {(options?.CompanyMaster ?? []).map((o: any) => <option key={o.value} value={o.value}>{o.label}</option>)}
        </select>
      </div>
      <div>
        <Label className="text-xs">Division</Label>
        <select className={sel} value={value.div_sno} disabled={!value.com_sno} onChange={(e) => onChange({ ...value, div_sno: e.target.value, brn_sno: '', dept_sno: '' })}>
          <option value="">Select…</option>
          {divisionOptions.map((o: any) => <option key={o.value} value={o.value}>{o.label}</option>)}
        </select>
      </div>
      <div>
        <Label className="text-xs">Branch</Label>
        <select className={sel} value={value.brn_sno} disabled={!value.div_sno} onChange={(e) => onChange({ ...value, brn_sno: e.target.value, dept_sno: '' })}>
          <option value="">Select…</option>
          {branchOptions.map((o: any) => <option key={o.value} value={o.value}>{o.label}</option>)}
        </select>
      </div>
      <div>
        <Label className="text-xs">Department</Label>
        <select className={sel} value={value.dept_sno} disabled={!value.brn_sno} onChange={(e) => onChange({ ...value, dept_sno: e.target.value })}>
          <option value="">Select…</option>
          {deptOptions.map((o: any) => <option key={o.value} value={o.value}>{o.label}</option>)}
        </select>
      </div>
    </div>
  );
}

// ── Create-bill form for a selected ceiling agreement ────────────────────
const RaiseBillForm: React.FC<{ agreement: CeilingAgreement; options: any; onDone: () => void }> = ({ agreement, options, onDone }) => {
  const [periodFrom, setPeriodFrom] = useState('');
  const [periodTo, setPeriodTo] = useState('');
  const [invoiceNo, setInvoiceNo] = useState('');
  const [invoiceDate, setInvoiceDate] = useState('');
  const [remarks, setRemarks] = useState('');
  const [file, setFile] = useState<File | null>(null);
  const [items, setItems] = useState<BillItem[]>([{ ...emptyItem(), service_sno: String(agreement.service_sno) }]);
  const { postData, loading } = usePost();

  const serviceOptions = options?.ServiceMaster ?? [];
  const uomOptions = options?.UomMaster ?? [];

  const updateItem = (idx: number, patch: Partial<BillItem>) =>
    setItems((prev) => prev.map((it, i) => (i === idx ? { ...it, ...patch } : it)));
  const addItem = () => setItems((prev) => [...prev, emptyItem()]);
  const removeItem = (idx: number) => setItems((prev) => prev.filter((_, i) => i !== idx));

  const total = items.reduce((sum, it) => sum + Number(it.qty || 0) * Number(it.unit_price || 0), 0);
  const ceilingWithTolerance = agreement.ceiling_amount != null
    ? agreement.ceiling_amount * (1 + (agreement.variance_tolerance_pct ?? 0) / 100)
    : null;
  const overCeiling = ceilingWithTolerance != null && total > ceilingWithTolerance;

  const handleSubmit = async () => {
    if (!file) { toast.error('Upload the invoice document'); return; }
    if (items.some((it) => !it.service_sno || !it.qty || !it.unit_price)) {
      toast.error('Every item needs a service, qty and unit price'); return;
    }

    const fd = new FormData();
    fd.append('agreement_sno', String(agreement.agreement_sno));
    fd.append('billing_period_start', periodFrom);
    fd.append('billing_period_end', periodTo);
    fd.append('invoice_no', invoiceNo);
    fd.append('invoice_date', invoiceDate);
    fd.append('remarks', remarks);
    fd.append('items', JSON.stringify(items.map((it) => ({
      service_sno: Number(it.service_sno), qty: Number(it.qty),
      uom_sno: it.uom_sno ? Number(it.uom_sno) : undefined,
      unit_price: Number(it.unit_price), remarks: it.remarks || undefined,
    }))));
    fd.append('invoice_document', file);

    try {
      await postData(createServiceBillRequest, fd, { headers: { 'Content-Type': 'multipart/form-data' } });
      toast.success('Service Bill Request submitted for approval');
      onDone();
    } catch (err: any) {
      toast.error(err?.response?.data?.error || err?.message || 'Failed to submit bill request');
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>{agreement.agreement_no}</CardTitle>
        <CardDescription>
          {agreement.service_name} · {agreement.vendor_name ?? 'No vendor'}
          {agreement.ceiling_amount != null && ` · Ceiling ${inr(agreement.ceiling_amount)}${agreement.variance_tolerance_pct ? ` (+${agreement.variance_tolerance_pct}% tolerance)` : ''}`}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="grid grid-cols-1 sm:grid-cols-4 gap-3">
          <div><Label className="text-xs">Period From</Label><Input type="date" value={periodFrom} onChange={(e) => setPeriodFrom(e.target.value)} /></div>
          <div><Label className="text-xs">Period To</Label><Input type="date" value={periodTo} onChange={(e) => setPeriodTo(e.target.value)} /></div>
          <div><Label className="text-xs">Invoice No</Label><Input value={invoiceNo} onChange={(e) => setInvoiceNo(e.target.value)} /></div>
          <div><Label className="text-xs">Invoice Date</Label><Input type="date" value={invoiceDate} onChange={(e) => setInvoiceDate(e.target.value)} /></div>
        </div>

        <div className="border rounded-lg overflow-x-auto">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Service</TableHead>
                <TableHead className="w-24">Qty</TableHead>
                <TableHead className="w-32">Unit</TableHead>
                <TableHead className="w-32">Unit Price</TableHead>
                <TableHead className="text-right w-28">Amount</TableHead>
                <TableHead className="w-10" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {items.map((it, idx) => (
                <TableRow key={idx}>
                  <TableCell>
                    <select className="flex h-9 w-full rounded-md border border-input bg-background px-2 text-sm"
                      value={it.service_sno} onChange={(e) => updateItem(idx, { service_sno: e.target.value })}>
                      <option value="">Select…</option>
                      {serviceOptions.map((o: any) => <option key={o.value} value={o.value}>{o.label}</option>)}
                    </select>
                  </TableCell>
                  <TableCell><Input type="number" className="h-9" value={it.qty} onChange={(e) => updateItem(idx, { qty: e.target.value })} /></TableCell>
                  <TableCell>
                    <select className="flex h-9 w-full rounded-md border border-input bg-background px-2 text-sm"
                      value={it.uom_sno} onChange={(e) => updateItem(idx, { uom_sno: e.target.value })}>
                      <option value="">—</option>
                      {uomOptions.map((o: any) => <option key={o.value} value={o.value}>{o.label}</option>)}
                    </select>
                  </TableCell>
                  <TableCell><Input type="number" className="h-9" value={it.unit_price} onChange={(e) => updateItem(idx, { unit_price: e.target.value })} /></TableCell>
                  <TableCell className="text-right font-medium">{inr(Number(it.qty || 0) * Number(it.unit_price || 0))}</TableCell>
                  <TableCell>
                    {items.length > 1 && (
                      <Button size="icon" variant="ghost" onClick={() => removeItem(idx)}><Trash2 size={14} /></Button>
                    )}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>

        <Button variant="outline" size="sm" onClick={addItem}><Plus size={14} className="mr-1" />Add Item</Button>

        <div className="flex justify-end items-center gap-2 text-sm font-semibold">
          <span className="text-muted-foreground font-normal">Total</span>
          <span className={overCeiling ? 'text-red-600' : ''}>{inr(total)}</span>
        </div>
        {overCeiling && (
          <p className="text-xs text-red-600">Total exceeds the ceiling + tolerance ({inr(ceilingWithTolerance ?? 0)}) — submission will be rejected server-side.</p>
        )}

        <div>
          <Label className="text-xs">Remarks</Label>
          <Textarea rows={2} value={remarks} onChange={(e) => setRemarks(e.target.value)} className="resize-none" />
        </div>

        <div>
          <Label className="text-xs flex items-center gap-1"><FileUp size={12} />Invoice Document</Label>
          <Input type="file" accept=".pdf,.png,.jpg,.jpeg" onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
        </div>

        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onDone} disabled={loading}>Cancel</Button>
          <Button onClick={handleSubmit} disabled={loading}>
            {loading ? <><Loader2 size={15} className="animate-spin mr-1" />Submitting…</> : <><Send size={15} className="mr-1" />Submit Bill Request</>}
          </Button>
        </div>
      </CardContent>
    </Card>
  );
};

const ServiceBillRequestPage: React.FC = () => {
  const [activeTab, setActiveTab] = useState<'raise' | 'history'>('raise');
  const [org, setOrg] = useState({ com_sno: '', div_sno: '', brn_sno: '', dept_sno: '' });
  const [selectedAgreement, setSelectedAgreement] = useState<CeilingAgreement | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const { options } = useMasterOptions(["CompanyMaster", "DivisionMaster", "BranchMaster", "DeptMaster", "ServiceMaster", "UomMaster"]);

  const canFetchAgreements = !!(org.com_sno && org.div_sno && org.brn_sno && org.dept_sno);
  const { data: agreementsRes, loading: loadingAgreements } = useFetch<{ success: boolean; data: CeilingAgreement[] }>(
    canFetchAgreements ? getActiveCeilingAgreementsForBilling : null, '', org, refreshKey
  );
  const { data: billsRes, loading: loadingBills } = useFetch<{ success: boolean; data: BillRow[] }>(
    getServiceBillRequests, '', null, refreshKey
  );

  const agreements = agreementsRes?.data ?? [];
  const bills = billsRes?.data ?? [];
  const refresh = () => setRefreshKey((k) => k + 1);

  return (
    <div className="flex flex-col min-h-full bg-muted/20">
      <PageHeader icon={ClipboardList} title="Service Bill Request" description="Enter the actual invoice for a Variable Recurring (Unfixed) ceiling agreement — items, amount and the invoice document, before the PO is auto-issued">
        <Button variant="outline" size="sm" className="bg-primary-foreground/10 border-primary-foreground/20 text-primary-foreground hover:bg-primary-foreground/20" onClick={refresh}>
          <RefreshCw size={15} className="mr-1" /> Refresh
        </Button>
      </PageHeader>

      <div className="p-4 sm:p-6 space-y-4">
        <Tabs value={activeTab} onValueChange={(v) => { setActiveTab(v as any); setSelectedAgreement(null); }}>
          <TabsList>
            <TabsTrigger value="raise">Raise Bill</TabsTrigger>
            <TabsTrigger value="history"><History size={14} className="mr-1" /> History ({bills.length})</TabsTrigger>
          </TabsList>

          <TabsContent value="raise" className="mt-4 space-y-4">
            {selectedAgreement ? (
              <RaiseBillForm agreement={selectedAgreement} options={options} onDone={() => { setSelectedAgreement(null); refresh(); }} />
            ) : (
              <Card>
                <CardContent className="p-4 sm:p-6 space-y-4">
                  <OrgCascade options={options} value={org} onChange={setOrg} />

                  {canFetchAgreements && (
                    <div className="border rounded-lg overflow-x-auto">
                      <Table>
                        <TableHeader>
                          <TableRow>
                            <TableHead>Agreement</TableHead>
                            <TableHead>Service</TableHead>
                            <TableHead>Vendor</TableHead>
                            <TableHead className="text-right">Ceiling</TableHead>
                            <TableHead>Cadence</TableHead>
                            <TableHead className="w-28" />
                          </TableRow>
                        </TableHeader>
                        <TableBody>
                          {loadingAgreements ? (
                            <TableRow><TableCell colSpan={6} className="text-center py-8 text-muted-foreground"><Loader2 size={16} className="inline animate-spin mr-2" />Loading…</TableCell></TableRow>
                          ) : agreements.length === 0 ? (
                            <TableRow><TableCell colSpan={6} className="text-center py-8 text-muted-foreground">No active Variable Recurring agreements for this org scope</TableCell></TableRow>
                          ) : agreements.map((a) => (
                            <TableRow key={a.agreement_sno}>
                              <TableCell className="font-medium">{a.agreement_no}</TableCell>
                              <TableCell>{a.service_name}</TableCell>
                              <TableCell>{a.vendor_name ?? '—'}</TableCell>
                              <TableCell className="text-right">{a.ceiling_amount != null ? inr(a.ceiling_amount) : '—'}</TableCell>
                              <TableCell className="text-xs">{a.cadence_name ?? '—'}</TableCell>
                              <TableCell><Button size="sm" onClick={() => setSelectedAgreement(a)}>Raise Bill</Button></TableCell>
                            </TableRow>
                          ))}
                        </TableBody>
                      </Table>
                    </div>
                  )}
                </CardContent>
              </Card>
            )}
          </TabsContent>

          <TabsContent value="history" className="mt-4">
            <Card><CardContent className="p-0">
              <div className="border rounded-lg overflow-x-auto">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Request No</TableHead>
                      <TableHead>Agreement</TableHead>
                      <TableHead>Vendor</TableHead>
                      <TableHead>Period</TableHead>
                      <TableHead className="text-right">Amount</TableHead>
                      <TableHead>PO</TableHead>
                      <TableHead>Submitted By</TableHead>
                      <TableHead>Status</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {loadingBills ? (
                      <TableRow><TableCell colSpan={8} className="text-center py-8 text-muted-foreground"><Loader2 size={16} className="inline animate-spin mr-2" />Loading…</TableCell></TableRow>
                    ) : bills.length === 0 ? (
                      <TableRow><TableCell colSpan={8} className="text-center py-8 text-muted-foreground">No bill requests yet</TableCell></TableRow>
                    ) : bills.map((b) => (
                      <TableRow key={b.bill_request_sno}>
                        <TableCell className="font-medium">{b.request_no}</TableCell>
                        <TableCell>{b.agreement_no}</TableCell>
                        <TableCell>{b.vendor_name ?? '—'}</TableCell>
                        <TableCell className="text-xs text-muted-foreground">{dateOnly(b.billing_period_start)} – {dateOnly(b.billing_period_end)}</TableCell>
                        <TableCell className="text-right font-medium">{inr(b.invoice_amount)}</TableCell>
                        <TableCell className="text-xs">
                          {b.po_no ? (b.po_pdf_url ? <a href={b.po_pdf_url} target="_blank" rel="noreferrer" className="text-blue-600 hover:underline">{b.po_no}</a> : b.po_no) : '—'}
                        </TableCell>
                        <TableCell className="text-xs">{b.created_by ?? '—'}</TableCell>
                        <TableCell><Badge className={STATUS_COLORS[b.status] ?? ''} variant="secondary">{STATUS_LABELS[b.status] ?? b.status}</Badge></TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            </CardContent></Card>
          </TabsContent>
        </Tabs>
      </div>
    </div>
  );
};

export default ServiceBillRequestPage;
