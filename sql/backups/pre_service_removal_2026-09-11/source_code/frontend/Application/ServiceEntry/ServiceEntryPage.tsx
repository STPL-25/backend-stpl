import React, { useMemo, useState } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { ClipboardCheck, RefreshCw, Loader2, Send, History, FilePlus2 } from 'lucide-react';
import { PageHeader } from '@/CustomComponent/PageComponents';
import {
  getPendingServicePOsForServiceEntry, createServiceEntry, getAllServiceEntries,
} from '@/Services/Api';
import { useAppState } from '@/imports';
import useFetch from '@/hooks/useFetchHook';
import usePost from '@/hooks/usePostHook';

interface PoItemForEntry {
  po_item_sno: number; service_sno?: number; service_name?: string;
  unit_name?: string; net_cost: number;
}

interface PendingPo {
  po_basic_sno: number; po_no: string; vendor_sno?: number; vendor_name?: string;
  po_type: string; service_type_code: string; service_type_name: string;
  validity_from?: string; validity_to?: string; ceiling_amount?: number;
  consumed_amount?: number; variance_tolerance_pct?: number;
  com_sno: number; div_sno: number; brn_sno: number; dept_sno: number;
  items?: string | PoItemForEntry[];
}

interface EntryItem {
  service_entry_item_sno: number; po_item_sno: number; service_sno?: number; service_name?: string;
  billed_qty?: number; unit_price?: number; po_amount: number; confirmed_amount: number; diff_amount: number;
}

interface EntryRow {
  service_entry_sno: number; service_entry_no: number; po_basic_sno: number; po_no: string;
  vendor_name?: string; period_from?: string; period_to?: string; usage_reference?: string;
  confirmed_amount: number; variance_pct?: number; variance_status?: string;
  status: string; approved_by?: string; approved_at?: string;
  created_by?: string; created_date?: string; items?: string | EntryItem[];
}

const STATUS_COLORS: Record<string, string> = {
  Pending: 'bg-amber-100 text-amber-700', Approved: 'bg-emerald-100 text-emerald-700',
  Rejected: 'bg-red-100 text-red-700',
};

function parseJson<T>(raw: string | T[] | undefined): T[] {
  if (!raw) return [];
  try { return typeof raw === 'string' ? JSON.parse(raw) : raw; } catch { return []; }
}

const dateOnly = (v?: string) => (v ? v.slice(0, 10) : '');
const inr = (n?: number) => `₹${Number(n ?? 0).toLocaleString('en-IN')}`;

// ── Line-item confirmation form for the selected PO ─────────────────────
const RaiseEntryForm: React.FC<{ po: PendingPo; onDone: () => void }> = ({ po, onDone }) => {
  const { userData } = useAppState();
  const items = useMemo(() => parseJson<PoItemForEntry>(po.items), [po]);
  const [periodFrom, setPeriodFrom] = useState('');
  const [periodTo, setPeriodTo] = useState('');
  const [usageReference, setUsageReference] = useState('');
  const [confirmedByItem, setConfirmedByItem] = useState<Record<number, string>>(
    () => Object.fromEntries(items.map((it) => [it.po_item_sno, String(it.net_cost ?? '')]))
  );
  const { postData, loading } = usePost();

  const total = items.reduce((sum, it) => sum + Number(confirmedByItem[it.po_item_sno] || 0), 0);

  const handleSubmit = async () => {
    const entryItems = items.map((it) => ({
      po_item_sno: it.po_item_sno,
      service_sno: it.service_sno,
      confirmed_amount: Number(confirmedByItem[it.po_item_sno] || 0),
    }));

    try {
      const result: any = await postData(createServiceEntry, {
        po_basic_sno: po.po_basic_sno,
        vendor_sno: po.vendor_sno,
        period_from: periodFrom || null,
        period_to: periodTo || null,
        usage_reference: usageReference,
        com_sno: po.com_sno, div_sno: po.div_sno, brn_sno: po.brn_sno, dept_sno: po.dept_sno,
        items: entryItems,
      });
      const status = result?.data?.[0]?.status;
      toast.success(
        status === 'Pending'
          ? `Entry raised — variance exceeded tolerance, routed for approval`
          : `Service Entry recorded and auto-approved`
      );
      onDone();
    } catch (err: any) {
      toast.error(err?.response?.data?.error || err?.message || 'Failed to raise Service Entry');
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>{po.po_no}</CardTitle>
        <CardDescription>
          {po.vendor_name ?? 'No vendor'} · {po.service_type_name}
          {po.variance_tolerance_pct != null && ` · Tolerance ${po.variance_tolerance_pct}%`}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
          <div>
            <Label className="text-xs">Period From</Label>
            <Input type="date" value={periodFrom} onChange={(e) => setPeriodFrom(e.target.value)} />
          </div>
          <div>
            <Label className="text-xs">Period To</Label>
            <Input type="date" value={periodTo} onChange={(e) => setPeriodTo(e.target.value)} />
          </div>
          <div>
            <Label className="text-xs">Usage Reference</Label>
            <Input placeholder="e.g. meter reading, ticket no." value={usageReference} onChange={(e) => setUsageReference(e.target.value)} />
          </div>
        </div>

        <div className="border rounded-lg overflow-x-auto">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Service</TableHead>
                <TableHead>Unit</TableHead>
                <TableHead className="text-right">PO Amount</TableHead>
                <TableHead className="text-right w-40">Confirmed Amount</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {items.length === 0 ? (
                <TableRow><TableCell colSpan={4} className="text-center py-6 text-muted-foreground">No items on this PO</TableCell></TableRow>
              ) : items.map((it) => (
                <TableRow key={it.po_item_sno}>
                  <TableCell>{it.service_name ?? '-'}</TableCell>
                  <TableCell>{it.unit_name ?? '-'}</TableCell>
                  <TableCell className="text-right">{inr(it.net_cost)}</TableCell>
                  <TableCell className="text-right">
                    <Input
                      type="number" className="text-right h-8"
                      value={confirmedByItem[it.po_item_sno] ?? ''}
                      onChange={(e) => setConfirmedByItem((prev) => ({ ...prev, [it.po_item_sno]: e.target.value }))}
                    />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>

        <div className="flex justify-end text-sm font-semibold">
          <span className="text-muted-foreground font-normal mr-2">Total Confirmed</span>{inr(total)}
        </div>

        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onDone} disabled={loading}>Cancel</Button>
          <Button onClick={handleSubmit} disabled={loading || items.length === 0}>
            {loading ? <><Loader2 size={15} className="animate-spin mr-1" />Submitting…</> : <><Send size={15} className="mr-1" />Raise Service Entry</>}
          </Button>
        </div>
      </CardContent>
    </Card>
  );
};

const ServiceEntryPage: React.FC = () => {
  const [activeTab, setActiveTab] = useState<'raise' | 'history'>('raise');
  const [selectedPo, setSelectedPo] = useState<PendingPo | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const { data: posRes, loading: loadingPos } = useFetch<{ success: boolean; data: PendingPo[] }>(
    getPendingServicePOsForServiceEntry, '', null, refreshKey
  );
  const { data: entriesRes, loading: loadingEntries } = useFetch<{ success: boolean; data: EntryRow[] }>(
    getAllServiceEntries, '', null, refreshKey
  );

  const pendingPos = posRes?.data ?? [];
  const entries = entriesRes?.data ?? [];
  const refresh = () => setRefreshKey((k) => k + 1);

  return (
    <div className="flex flex-col min-h-full bg-muted/20">
      <PageHeader icon={ClipboardCheck} title="Service Entry" description="Confirm usage/consumption against an Approved Service PO — the GRN-equivalent for services">
        <Button variant="outline" size="sm" className="bg-primary-foreground/10 border-primary-foreground/20 text-primary-foreground hover:bg-primary-foreground/20" onClick={refresh}>
          <RefreshCw size={15} className="mr-1" /> Refresh
        </Button>
      </PageHeader>

      <div className="p-4 sm:p-6 space-y-4">
        <Tabs value={activeTab} onValueChange={(v) => { setActiveTab(v as any); setSelectedPo(null); }}>
          <TabsList>
            <TabsTrigger value="raise"><FilePlus2 size={14} className="mr-1" /> Raise Entry ({pendingPos.length} eligible POs)</TabsTrigger>
            <TabsTrigger value="history"><History size={14} className="mr-1" /> History ({entries.length})</TabsTrigger>
          </TabsList>

          <TabsContent value="raise" className="mt-4 space-y-4">
            {selectedPo ? (
              <RaiseEntryForm po={selectedPo} onDone={() => { setSelectedPo(null); refresh(); }} />
            ) : (
              <div className="border rounded-lg overflow-x-auto bg-background">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>PO No</TableHead>
                      <TableHead>Vendor</TableHead>
                      <TableHead>Billing Pattern</TableHead>
                      <TableHead className="text-right">Ceiling</TableHead>
                      <TableHead className="text-right">Consumed</TableHead>
                      <TableHead className="w-32" />
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {loadingPos ? (
                      <TableRow><TableCell colSpan={6} className="text-center py-8 text-muted-foreground">
                        <Loader2 size={16} className="inline animate-spin mr-2" />Loading…
                      </TableCell></TableRow>
                    ) : pendingPos.length === 0 ? (
                      <TableRow><TableCell colSpan={6} className="text-center py-8 text-muted-foreground">No Approved Service POs available</TableCell></TableRow>
                    ) : pendingPos.map((po) => (
                      <TableRow key={po.po_basic_sno}>
                        <TableCell className="font-medium">{po.po_no}</TableCell>
                        <TableCell>{po.vendor_name ?? '—'}</TableCell>
                        <TableCell className="text-xs">{po.service_type_name}</TableCell>
                        <TableCell className="text-right">{po.ceiling_amount != null ? inr(po.ceiling_amount) : '—'}</TableCell>
                        <TableCell className="text-right">{po.consumed_amount != null ? inr(po.consumed_amount) : '—'}</TableCell>
                        <TableCell>
                          <Button size="sm" onClick={() => setSelectedPo(po)}>Raise Entry</Button>
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            )}
          </TabsContent>

          <TabsContent value="history" className="mt-4">
            <Card><CardContent className="p-0">
              <div className="border rounded-lg overflow-x-auto">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Entry No</TableHead>
                      <TableHead>PO No</TableHead>
                      <TableHead>Vendor</TableHead>
                      <TableHead>Period</TableHead>
                      <TableHead className="text-right">Confirmed</TableHead>
                      <TableHead>Variance</TableHead>
                      <TableHead>Status</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {loadingEntries ? (
                      <TableRow><TableCell colSpan={7} className="text-center py-8 text-muted-foreground">
                        <Loader2 size={16} className="inline animate-spin mr-2" />Loading…
                      </TableCell></TableRow>
                    ) : entries.length === 0 ? (
                      <TableRow><TableCell colSpan={7} className="text-center py-8 text-muted-foreground">No Service Entries yet</TableCell></TableRow>
                    ) : entries.map((e) => (
                      <TableRow key={e.service_entry_sno}>
                        <TableCell className="font-medium">SE-{e.service_entry_no}</TableCell>
                        <TableCell>{e.po_no}</TableCell>
                        <TableCell>{e.vendor_name ?? '—'}</TableCell>
                        <TableCell className="text-xs text-muted-foreground">{dateOnly(e.period_from)} – {dateOnly(e.period_to)}</TableCell>
                        <TableCell className="text-right font-medium">{inr(e.confirmed_amount)}</TableCell>
                        <TableCell className="text-xs">
                          {e.variance_status && e.variance_status !== 'N/A'
                            ? `${e.variance_status === 'EXCEEDED' ? '⚠ ' : ''}${Number(e.variance_pct ?? 0).toFixed(1)}%`
                            : '—'}
                        </TableCell>
                        <TableCell><Badge className={STATUS_COLORS[e.status] ?? ''} variant="secondary">{e.status}</Badge></TableCell>
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

export default ServiceEntryPage;
