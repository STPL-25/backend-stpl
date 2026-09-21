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
import { AlertCircle, CheckCircle2, XCircle, Clock, Loader2, RefreshCw, FileText, ClipboardCheck } from 'lucide-react';
import { PageHeader } from '@/CustomComponent/PageComponents';
import { getServiceBillRequestsForApproval, approveServiceBillRequest } from '@/Services/Api';
import { useAppState } from '@/imports';
import useFetch from '@/hooks/useFetchHook';
import usePost from '@/hooks/usePostHook';
import {
  socket, SOCKET_JOIN_SERVICE_BILL_REQUEST_APPROVAL, SOCKET_LEAVE_SERVICE_BILL_REQUEST_APPROVAL,
  SOCKET_SERVICE_BILL_REQUEST_APPROVAL_UPDATED,
} from '@/Services/Socket';

interface BillItem {
  bill_request_item_sno: number; service_name?: string; qty: number; uom_name?: string; unit_price: number; amount: number;
}

interface BillRow {
  bill_request_sno: number; request_no: string; agreement_no?: string; service_name?: string;
  vendor_name?: string; billing_period_start?: string; billing_period_end?: string;
  invoice_no?: string; invoice_date?: string; invoice_amount: number; invoice_doc_url?: string;
  ceiling_amount?: number; variance_tolerance_pct?: number;
  remarks?: string; current_approver_id?: string; status: string;
  created_by?: string; created_at?: string;
  stage_order_json?: string; items?: string | BillItem[];
}

function parseJson<T>(raw: string | T[] | undefined): T[] {
  if (!raw) return [];
  try { return typeof raw === 'string' ? JSON.parse(raw) : raw; } catch { return []; }
}

const dateOnly = (v?: string) => (v ? v.slice(0, 10) : '');
const inr = (n?: number) => `₹${Number(n ?? 0).toLocaleString('en-IN')}`;

const ServiceBillRequestApprovalScreen: React.FC = () => {
  const [bills, setBills] = useState<BillRow[]>([]);
  const [selected, setSelected] = useState<BillRow | null>(null);
  const [actionType, setActionType] = useState<'approve' | 'reject'>('approve');
  const [showDialog, setShowDialog] = useState(false);
  const [comments, setComments] = useState('');
  const [refreshKey, setRefreshKey] = useState(0);

  const { userData } = useAppState();
  const { postData, loading } = usePost();

  const { data, loading: fetchLoading, error } = useFetch<{ success: boolean; data: BillRow[] }>(
    getServiceBillRequestsForApproval, '', null, refreshKey
  );

  useEffect(() => {
    if (data && !fetchLoading) setBills(data.data ?? []);
  }, [data, fetchLoading]);

  useEffect(() => {
    socket.emit(SOCKET_JOIN_SERVICE_BILL_REQUEST_APPROVAL);
    const onUpdated = (payload: { approved_by?: string }) => {
      if (payload?.approved_by === userData[0]?.ecno) return;
      setRefreshKey((k) => k + 1);
      toast.info('A Service Bill Request was actioned — refreshing list…');
    };
    socket.on(SOCKET_SERVICE_BILL_REQUEST_APPROVAL_UPDATED, onUpdated);
    return () => {
      socket.emit(SOCKET_LEAVE_SERVICE_BILL_REQUEST_APPROVAL);
      socket.off(SOCKET_SERVICE_BILL_REQUEST_APPROVAL_UPDATED, onUpdated);
    };
  }, [userData]);

  const handleAction = (bill: BillRow, action: 'approve' | 'reject') => {
    setSelected(bill);
    setActionType(action);
    setComments('');
    setShowDialog(true);
  };

  const handleSubmit = async () => {
    if (!selected) return;
    const approval_stages = parseJson<any>(selected.stage_order_json);
    try {
      await postData(approveServiceBillRequest, {
        bill_request_sno: selected.bill_request_sno,
        comments: comments.trim(),
        approval_stages,
        action: actionType,
      });
      setBills((prev) => prev.filter((b) => b.bill_request_sno !== selected.bill_request_sno));
      setShowDialog(false);
      setSelected(null);
      setComments('');
      toast.success(`Service Bill Request ${actionType === 'approve' ? 'approved' : 'rejected'}`);
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
      <PageHeader icon={ClipboardCheck} title="Service Bill Request Approvals" description="Review submitted invoices against their ceiling agreement before the PO auto-issues">
        <Button variant="outline" size="sm" className="bg-primary-foreground/10 border-primary-foreground/20 text-primary-foreground hover:bg-primary-foreground/20" onClick={() => setRefreshKey((k) => k + 1)}>
          <RefreshCw size={15} className="mr-1" /> Refresh
        </Button>
      </PageHeader>

      <div className="p-4 sm:p-6 space-y-4">
        {fetchLoading && bills.length === 0 ? (
          <div className="text-center py-16 text-muted-foreground"><Loader2 size={20} className="inline animate-spin mr-2" />Loading…</div>
        ) : bills.length === 0 ? (
          <Card><CardContent className="text-center py-16 text-muted-foreground">No Service Bill Requests pending your approval</CardContent></Card>
        ) : (
          <div className="grid gap-4">
            {bills.map((bill) => {
              const items = parseJson<BillItem>(bill.items);
              const ceilingWithTolerance = bill.ceiling_amount != null
                ? bill.ceiling_amount * (1 + (bill.variance_tolerance_pct ?? 0) / 100)
                : null;
              return (
                <Card key={bill.bill_request_sno} className="shadow-sm">
                  <CardHeader className="pb-3">
                    <div className="flex items-start justify-between flex-wrap gap-2">
                      <div>
                        <CardTitle className="text-base">{bill.request_no} · {bill.agreement_no}</CardTitle>
                        <CardDescription>
                          {bill.vendor_name ?? 'No vendor'} · {dateOnly(bill.billing_period_start)} – {dateOnly(bill.billing_period_end)}
                          {bill.invoice_no ? ` · Invoice ${bill.invoice_no}` : ''}
                        </CardDescription>
                      </div>
                      {bill.invoice_doc_url && (
                        <Button size="sm" variant="outline" asChild>
                          <a href={bill.invoice_doc_url} target="_blank" rel="noreferrer"><FileText size={14} className="mr-1" />Invoice Doc</a>
                        </Button>
                      )}
                    </div>
                  </CardHeader>
                  <CardContent className="space-y-3">
                    <div className="border rounded-lg overflow-x-auto">
                      <Table>
                        <TableHeader>
                          <TableRow>
                            <TableHead>Service</TableHead>
                            <TableHead className="text-right">Qty</TableHead>
                            <TableHead>Unit</TableHead>
                            <TableHead className="text-right">Rate</TableHead>
                            <TableHead className="text-right">Amount</TableHead>
                          </TableRow>
                        </TableHeader>
                        <TableBody>
                          {items.map((it) => (
                            <TableRow key={it.bill_request_item_sno}>
                              <TableCell>{it.service_name ?? '-'}</TableCell>
                              <TableCell className="text-right">{it.qty}</TableCell>
                              <TableCell>{it.uom_name ?? '-'}</TableCell>
                              <TableCell className="text-right">{inr(it.unit_price)}</TableCell>
                              <TableCell className="text-right font-medium">{inr(it.amount)}</TableCell>
                            </TableRow>
                          ))}
                        </TableBody>
                      </Table>
                    </div>
                    <div className="flex justify-between items-center flex-wrap gap-2">
                      <div className="text-sm">
                        <span className="font-semibold">Total: {inr(bill.invoice_amount)}</span>
                        {ceilingWithTolerance != null && (
                          <span className="text-xs text-muted-foreground ml-2">
                            (Ceiling {inr(bill.ceiling_amount)}{bill.variance_tolerance_pct ? ` +${bill.variance_tolerance_pct}%` : ''} = {inr(ceilingWithTolerance)} max)
                          </span>
                        )}
                      </div>
                      <div className="flex gap-2">
                        <Button size="sm" variant="destructive" onClick={() => handleAction(bill, 'reject')}>
                          <XCircle size={14} className="mr-1" />Reject
                        </Button>
                        <Button size="sm" className="bg-green-600 hover:bg-green-700" onClick={() => handleAction(bill, 'approve')}>
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
                ? <><CheckCircle2 className="h-5 w-5 text-green-600" />Approve Bill Request</>
                : <><XCircle className="h-5 w-5 text-red-600" />Reject Bill Request</>}
            </DialogTitle>
            <DialogDescription>
              {actionType === 'approve'
                ? 'If this is the final stage, the Service PO is auto-issued immediately with these items.'
                : 'Please provide a reason for rejection.'}
              {selected && <><br />{selected.request_no}</>}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-1.5">
            <Label htmlFor="sbr-comments">Comments {actionType === 'reject' && <span className="text-red-500">*</span>}</Label>
            <Textarea id="sbr-comments" rows={3} value={comments} onChange={(e) => setComments(e.target.value)}
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

export default ServiceBillRequestApprovalScreen;
