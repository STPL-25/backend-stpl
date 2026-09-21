import React, { useEffect, useState } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from '@/components/ui/dialog';
import { AlertCircle, AlertTriangle, CheckCircle2, XCircle, Clock, Loader2, RefreshCw } from 'lucide-react';
import { PageHeader } from '@/CustomComponent/PageComponents';
import { getAllServiceEntries, serviceEntryApproveAction } from '@/Services/Api';
import { useAppState } from '@/imports';
import useFetch from '@/hooks/useFetchHook';
import usePost from '@/hooks/usePostHook';
import {
  socket, SOCKET_JOIN_SERVICE_ENTRY, SOCKET_LEAVE_SERVICE_ENTRY, SOCKET_SERVICE_ENTRY_APPROVAL_UPDATED,
} from '@/Services/Socket';

interface EntryItem {
  service_entry_item_sno: number; service_name?: string;
  billed_qty?: number; unit_price?: number; po_amount: number; confirmed_amount: number; diff_amount: number;
}

interface EntryRow {
  service_entry_sno: number; service_entry_no: number; po_basic_sno: number; po_no: string;
  vendor_name?: string; period_from?: string; period_to?: string; usage_reference?: string;
  confirmed_amount: number; variance_pct?: number; variance_status?: string;
  status: string; created_by?: string; created_date?: string; items?: string | EntryItem[];
}

function parseItems(raw?: string | EntryItem[]): EntryItem[] {
  if (!raw) return [];
  try { return typeof raw === 'string' ? JSON.parse(raw) : raw; } catch { return []; }
}

const dateOnly = (v?: string) => (v ? v.slice(0, 10) : '');
const inr = (n?: number) => `₹${Number(n ?? 0).toLocaleString('en-IN')}`;

const ServiceEntryApprovalScreen: React.FC = () => {
  const [entries, setEntries] = useState<EntryRow[]>([]);
  const [selected, setSelected] = useState<EntryRow | null>(null);
  const [actionType, setActionType] = useState<'approve' | 'reject'>('approve');
  const [showDialog, setShowDialog] = useState(false);
  const [comments, setComments] = useState('');
  const [refreshKey, setRefreshKey] = useState(0);

  const { userData } = useAppState();
  const { postData, loading } = usePost();

  const { data, loading: fetchLoading, error } = useFetch<{ success: boolean; data: EntryRow[] }>(
    getAllServiceEntries, '', { status: 'Pending', mine: 'true' }, refreshKey
  );

  useEffect(() => {
    if (data && !fetchLoading) setEntries(data.data ?? []);
  }, [data, fetchLoading]);

  useEffect(() => {
    socket.emit(SOCKET_JOIN_SERVICE_ENTRY);
    const onUpdated = (payload: { approved_by?: string }) => {
      if (payload?.approved_by === userData[0]?.ecno) return;
      setRefreshKey((k) => k + 1);
      toast.info('A Service Entry was actioned — refreshing list…');
    };
    socket.on(SOCKET_SERVICE_ENTRY_APPROVAL_UPDATED, onUpdated);
    return () => {
      socket.emit(SOCKET_LEAVE_SERVICE_ENTRY);
      socket.off(SOCKET_SERVICE_ENTRY_APPROVAL_UPDATED, onUpdated);
    };
  }, [userData]);

  const handleAction = (entry: EntryRow, action: 'approve' | 'reject') => {
    setSelected(entry);
    setActionType(action);
    setComments('');
    setShowDialog(true);
  };

  const handleSubmit = async () => {
    if (!selected) return;
    try {
      await postData(serviceEntryApproveAction, {
        service_entry_sno: selected.service_entry_sno,
        comments: comments.trim(),
        action: actionType,
      });
      setEntries((prev) => prev.filter((e) => e.service_entry_sno !== selected.service_entry_sno));
      setShowDialog(false);
      setSelected(null);
      setComments('');
      toast.success(`Service Entry ${actionType === 'approve' ? 'approved' : 'rejected'}`);
    } catch (err: any) {
      toast.error(err?.response?.data?.error || err?.message || 'Action failed');
    }
  };

  if (error) {
    return (
      <div className="min-h-full flex items-center justify-center">
        <div className="text-center space-y-3">
          <AlertCircle className="h-16 w-16 text-red-500 mx-auto" />
          <h3 className="text-xl font-semibold text-muted-foreground">Error Loading Data</h3>
          <p className="text-sm text-muted-foreground">{error}</p>
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col min-h-full bg-muted/20">
      <PageHeader icon={AlertTriangle} title="Service Entry Approvals" description="Entries where confirmed usage exceeded the PO's variance tolerance">
        <Button variant="outline" size="sm" className="bg-primary-foreground/10 border-primary-foreground/20 text-primary-foreground hover:bg-primary-foreground/20" onClick={() => setRefreshKey((k) => k + 1)}>
          <RefreshCw size={15} className="mr-1" /> Refresh
        </Button>
      </PageHeader>

      <div className="p-4 sm:p-6 space-y-4">
        {fetchLoading && entries.length === 0 ? (
          <div className="text-center py-16 text-muted-foreground">
            <Loader2 size={20} className="inline animate-spin mr-2" />Loading…
          </div>
        ) : entries.length === 0 ? (
          <Card><CardContent className="text-center py-16 text-muted-foreground">No Service Entries pending your approval</CardContent></Card>
        ) : (
          <div className="grid gap-4">
            {entries.map((entry) => {
              const items = parseItems(entry.items);
              return (
                <Card key={entry.service_entry_sno} className="shadow-sm">
                  <CardHeader className="pb-3">
                    <div className="flex items-start justify-between flex-wrap gap-2">
                      <div>
                        <CardTitle className="text-base">SE-{entry.service_entry_no} · {entry.po_no}</CardTitle>
                        <CardDescription>
                          {entry.vendor_name ?? 'No vendor'} · {dateOnly(entry.period_from)} – {dateOnly(entry.period_to)}
                          {entry.usage_reference ? ` · ${entry.usage_reference}` : ''}
                        </CardDescription>
                      </div>
                      <Badge variant="destructive" className="flex items-center gap-1">
                        <AlertTriangle size={12} />{Number(entry.variance_pct ?? 0).toFixed(1)}% variance
                      </Badge>
                    </div>
                  </CardHeader>
                  <CardContent className="space-y-3">
                    <div className="border rounded-lg overflow-x-auto">
                      <Table>
                        <TableHeader>
                          <TableRow>
                            <TableHead>Service</TableHead>
                            <TableHead className="text-right">PO Amount</TableHead>
                            <TableHead className="text-right">Confirmed</TableHead>
                            <TableHead className="text-right">Diff</TableHead>
                          </TableRow>
                        </TableHeader>
                        <TableBody>
                          {items.map((it) => (
                            <TableRow key={it.service_entry_item_sno}>
                              <TableCell>{it.service_name ?? '-'}</TableCell>
                              <TableCell className="text-right">{inr(it.po_amount)}</TableCell>
                              <TableCell className="text-right">{inr(it.confirmed_amount)}</TableCell>
                              <TableCell className={`text-right ${it.diff_amount > 0 ? 'text-red-600' : 'text-emerald-600'}`}>
                                {it.diff_amount > 0 ? '+' : ''}{inr(it.diff_amount)}
                              </TableCell>
                            </TableRow>
                          ))}
                        </TableBody>
                      </Table>
                    </div>
                    <div className="flex justify-between items-center">
                      <span className="text-sm font-semibold">Total Confirmed: {inr(entry.confirmed_amount)}</span>
                      <div className="flex gap-2">
                        <Button size="sm" variant="destructive" onClick={() => handleAction(entry, 'reject')}>
                          <XCircle size={14} className="mr-1" />Reject
                        </Button>
                        <Button size="sm" className="bg-green-600 hover:bg-green-700" onClick={() => handleAction(entry, 'approve')}>
                          <CheckCircle2 size={14} className="mr-1" />Approve
                        </Button>
                      </div>
                    </div>
                  </CardContent>
                </Card>
              );
            })}
          </div>
        )}
      </div>

      <Dialog open={showDialog} onOpenChange={setShowDialog}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              {actionType === 'approve'
                ? <><CheckCircle2 className="h-5 w-5 text-green-600" />Approve Service Entry</>
                : <><XCircle className="h-5 w-5 text-red-600" />Reject Service Entry</>}
            </DialogTitle>
            <DialogDescription>
              {selected && `SE-${selected.service_entry_no} · ${selected.po_no}`}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-1.5">
            <Label htmlFor="se-comments">Comments {actionType === 'reject' && <span className="text-red-500">*</span>}</Label>
            <Textarea id="se-comments" rows={3} value={comments} onChange={(e) => setComments(e.target.value)}
              placeholder={actionType === 'approve' ? 'Optional notes…' : 'Reason for rejection…'} className="resize-none" />
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setShowDialog(false)} disabled={loading}>Cancel</Button>
            <Button
              onClick={handleSubmit}
              disabled={loading || (actionType === 'reject' && !comments.trim())}
              className={actionType === 'approve' ? 'bg-green-600 hover:bg-green-700' : 'bg-red-600 hover:bg-red-700'}
            >
              {loading ? <><Clock className="mr-2 h-4 w-4 animate-spin" />Processing…</> : 'Confirm'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default ServiceEntryApprovalScreen;
