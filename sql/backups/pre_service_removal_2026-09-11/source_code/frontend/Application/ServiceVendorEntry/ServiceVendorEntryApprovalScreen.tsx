import React, { useEffect, useState } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from '@/components/ui/dialog';
import { AlertCircle, CheckCircle2, XCircle, Clock, Loader2, RefreshCw, Receipt, ShoppingBasket } from 'lucide-react';
import { PageHeader } from '@/CustomComponent/PageComponents';
import { getServiceVendorEntries, approveServiceVendorEntry } from '@/Services/Api';
import { useAppState } from '@/imports';
import useFetch from '@/hooks/useFetchHook';
import usePost from '@/hooks/usePostHook';

interface EntryRow {
  entry_sno: number;
  vendor_name?: string;
  service_name?: string;
  entry_date: string;
  qty: number;
  unit_name?: string;
  unit_price: number;
  total_amount: number;
  specification?: string;
  remarks?: string;
  receipt_doc_url?: string;
  status: string;
  created_by?: string;
  created_date?: string;
}

const dateOnly = (v?: string) => (v ? v.slice(0, 10) : '');
const inr = (n?: number) => `₹${Number(n ?? 0).toLocaleString('en-IN')}`;

/**
 * Per-purchase approval queue for Vendor Driven daily entries (e.g. canteen
 * groceries logged day by day before periodic consolidation into one PO).
 * This is retrospective verification — the purchase already happened, the
 * approver is confirming qty/price/receipt look right, not authorizing a
 * future spend. Deliberately mirrors ServiceEntryApprovalScreen's simple
 * single-stage shape (one approver, no approval_stages chain) rather than
 * the fuller multi-stage layout used for Service PO/Agreement.
 */
const ServiceVendorEntryApprovalScreen: React.FC = () => {
  const [entries, setEntries] = useState<EntryRow[]>([]);
  const [selected, setSelected] = useState<EntryRow | null>(null);
  const [actionType, setActionType] = useState<'Approve' | 'Reject'>('Approve');
  const [showDialog, setShowDialog] = useState(false);
  const [comments, setComments] = useState('');
  const [refreshKey, setRefreshKey] = useState(0);

  const { userData } = useAppState();
  const ecno = userData?.[0]?.ecno;
  const { postData, loading } = usePost();

  const { data, loading: fetchLoading, error } = useFetch<{ success: boolean; data: EntryRow[] }>(
    getServiceVendorEntries, '', { status: 'PENDING_APPROVAL', approver_ecno: ecno }, refreshKey
  );

  useEffect(() => {
    if (data && !fetchLoading) setEntries(data.data ?? []);
  }, [data, fetchLoading]);

  const handleAction = (entry: EntryRow, action: 'Approve' | 'Reject') => {
    setSelected(entry);
    setActionType(action);
    setComments('');
    setShowDialog(true);
  };

  const handleSubmit = async () => {
    if (!selected) return;
    try {
      await postData(approveServiceVendorEntry, {
        entry_sno: selected.entry_sno,
        action: actionType,
        comments: comments.trim(),
      });
      setEntries((prev) => prev.filter((e) => e.entry_sno !== selected.entry_sno));
      setShowDialog(false);
      setSelected(null);
      setComments('');
      toast.success(`Entry ${actionType === 'Approve' ? 'approved' : 'rejected'}`);
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
      <PageHeader icon={ShoppingBasket} title="Vendor Entry Approvals" description="Daily Vendor Driven purchases awaiting your review, before they're eligible for consolidation">
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
          <Card><CardContent className="text-center py-16 text-muted-foreground">No entries pending your approval</CardContent></Card>
        ) : (
          <div className="grid gap-4">
            {entries.map((entry) => (
              <Card key={entry.entry_sno} className="shadow-sm">
                <CardHeader className="pb-3">
                  <div className="flex items-start justify-between flex-wrap gap-2">
                    <div>
                      <CardTitle className="text-base">{entry.service_name ?? 'Service'} · {entry.vendor_name ?? 'No vendor'}</CardTitle>
                      <CardDescription>
                        {dateOnly(entry.entry_date)} · logged by {entry.created_by ?? '—'}
                      </CardDescription>
                    </div>
                    <Badge variant="secondary">{inr(entry.total_amount)}</Badge>
                  </div>
                </CardHeader>
                <CardContent className="space-y-3">
                  <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 text-sm">
                    <div><span className="text-muted-foreground">Qty</span><div className="font-medium">{entry.qty} {entry.unit_name ?? ''}</div></div>
                    <div><span className="text-muted-foreground">Unit Price</span><div className="font-medium">{inr(entry.unit_price)}</div></div>
                    <div><span className="text-muted-foreground">Total</span><div className="font-medium">{inr(entry.total_amount)}</div></div>
                    {entry.receipt_doc_url && (
                      <div>
                        <span className="text-muted-foreground">Receipt</span>
                        <div>
                          <a href={entry.receipt_doc_url} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 text-primary hover:underline font-medium">
                            <Receipt size={14} />View
                          </a>
                        </div>
                      </div>
                    )}
                  </div>
                  {(entry.specification || entry.remarks) && (
                    <div className="text-sm text-muted-foreground">
                      {entry.specification && <span>{entry.specification}</span>}
                      {entry.specification && entry.remarks && <span> · </span>}
                      {entry.remarks && <span>{entry.remarks}</span>}
                    </div>
                  )}
                  <div className="flex justify-end gap-2">
                    <Button size="sm" variant="destructive" onClick={() => handleAction(entry, 'Reject')}>
                      <XCircle size={14} className="mr-1" />Reject
                    </Button>
                    <Button size="sm" className="bg-green-600 hover:bg-green-700" onClick={() => handleAction(entry, 'Approve')}>
                      <CheckCircle2 size={14} className="mr-1" />Approve
                    </Button>
                  </div>
                </CardContent>
              </Card>
            ))}
          </div>
        )}
      </div>

      <Dialog open={showDialog} onOpenChange={setShowDialog}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              {actionType === 'Approve'
                ? <><CheckCircle2 className="h-5 w-5 text-green-600" />Approve Entry</>
                : <><XCircle className="h-5 w-5 text-red-600" />Reject Entry</>}
            </DialogTitle>
            <DialogDescription>
              {selected && `${selected.service_name ?? 'Service'} · ${selected.vendor_name ?? ''} · ${inr(selected.total_amount)}`}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-1.5">
            <Label htmlFor="sve-comments">Comments {actionType === 'Reject' && <span className="text-red-500">*</span>}</Label>
            <Textarea id="sve-comments" rows={3} value={comments} onChange={(e) => setComments(e.target.value)}
              placeholder={actionType === 'Approve' ? 'Optional notes…' : 'Reason for rejection…'} className="resize-none" />
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setShowDialog(false)} disabled={loading}>Cancel</Button>
            <Button
              onClick={handleSubmit}
              disabled={loading || (actionType === 'Reject' && !comments.trim())}
              className={actionType === 'Approve' ? 'bg-green-600 hover:bg-green-700' : 'bg-red-600 hover:bg-red-700'}
            >
              {loading ? <><Clock className="mr-2 h-4 w-4 animate-spin" />Processing…</> : 'Confirm'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default ServiceVendorEntryApprovalScreen;
