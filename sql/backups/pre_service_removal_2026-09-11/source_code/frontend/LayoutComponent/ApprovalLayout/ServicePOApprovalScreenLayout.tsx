import { useMemo } from 'react';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Textarea } from '@/components/ui/textarea';
import {
  CheckCircle2, XCircle, Clock, ChevronRight, Layers,
} from 'lucide-react';
import type { FieldType } from '@/FieldDatas/fieldType/fieldType';
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { Separator } from "@/components/ui/separator";
import { usePermissions } from '@/globalState/hooks/usePermissions';
import { useAppState } from '@/imports';
import SidebarDetailLayout from '@/LayoutComponent/SidebarDetailLayout';

// ─── SP response mapping (sp_nt_GetServicePOsForApproval) ──────────────────
// po_basic_sno | po_no | pr_basic_sno | pr_no | vendor_sno | vendor_name |
// po_type | service_type_sno | service_type_code | service_type_name |
// validity_from | validity_to | ceiling_amount | variance_tolerance_pct |
// consumed_amount | is_retrospective | parent_blanket_po_sno | purpose |
// terms_conditions | delivery_address | com_sno | div_sno | brn_sno |
// dept_sno | workflow_types_id | current_approver_id | status |
// stage_order_json (JSON) | items (JSON array of po_item_details rows)
//
// Unlike Service Agreements, a Service PO has real line items — the detail
// panel renders an items table in addition to the fieldDatas key/value grid.

interface ServicePOApprovalScreenLayoutProps {
  approvalName: string;
  poList: any[];
  selectedPO: any;
  handlePOSelect: (po: any) => void;
  handleAction: (action: string) => void;
  showApprovalDialog: boolean;
  setShowApprovalDialog: (show: boolean) => void;
  comments: string;
  setComments: (comments: string) => void;
  handleSubmit: () => void;
  loading: boolean;
  actionType: 'approve' | 'reject';
  fieldDatas: FieldType[];
  toast?: { message: string; type: 'success' | 'error' } | null;
}

const STATUS_MAP: Record<string, string> = { D: 'Draft', P: 'Pending', A: 'Approved', R: 'Rejected' };

function getStatusLabel(s: any): string {
  return STATUS_MAP[String(s).toUpperCase()] ?? String(s ?? 'Pending');
}

function formatDate(d: string) {
  if (!d) return '—';
  try {
    return new Date(d).toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' });
  } catch { return d; }
}

function formatINR(n: number) {
  return new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 2 }).format(n || 0);
}

function parseStages(po: any): any[] {
  try {
    const raw = po.stage_order_json;
    if (!raw) return [];
    return typeof raw === 'string' ? JSON.parse(raw) : raw;
  } catch { return []; }
}

function parseItems(po: any): any[] {
  try {
    const raw = po.items;
    if (!raw) return [];
    return typeof raw === 'string' ? JSON.parse(raw) : raw;
  } catch { return []; }
}

function poTotal(po: any): number {
  return parseItems(po).reduce((sum, it) => sum + Number(it.net_cost ?? it.qty * it.agreed_unit_price), 0);
}

// ─── PO List Card ────────────────────────────────────────────────────────

function POListCard({ po, isSelected, onClick }: { po: any; isSelected: boolean; onClick: () => void }) {
  return (
    <Card
      className={`cursor-pointer transition-all hover:shadow-md border ${
        isSelected
          ? 'ring-2 ring-blue-500 bg-blue-50 dark:bg-blue-950/20 border-blue-200 dark:border-blue-800'
          : 'border-slate-200 dark:border-slate-800 hover:border-slate-300 dark:hover:border-slate-700'
      }`}
      onClick={onClick}
    >
      <CardContent className="p-3 sm:p-4 space-y-2.5">
        <div className="flex items-start justify-between gap-2">
          <div className="flex-1 min-w-0">
            <p className="font-semibold text-sm text-slate-900 dark:text-slate-50 truncate">{po.po_no}</p>
            {po.service_type_name && (
              <p className="text-xs text-slate-500 dark:text-slate-400 truncate mt-0.5">{po.service_type_name}</p>
            )}
          </div>
          <ChevronRight className={`h-4 w-4 flex-shrink-0 mt-0.5 ${isSelected ? 'text-blue-600' : 'text-slate-400'}`} />
        </div>

        <div className="flex flex-wrap gap-1.5">
          {po.status && <Badge variant="outline" className="text-xs">{getStatusLabel(po.status)}</Badge>}
          {po.po_type && <Badge variant="outline" className="text-xs">{po.po_type}</Badge>}
        </div>

        <div className="space-y-1 text-xs">
          {po.vendor_name && (
            <div className="flex justify-between gap-2">
              <span className="text-slate-500">Vendor</span>
              <span className="font-medium truncate text-right">{po.vendor_name}</span>
            </div>
          )}
        </div>

        <Separator />

        <div className="flex justify-between gap-2 text-xs">
          <span className="text-slate-500 font-medium">Amount</span>
          <span className="font-bold text-green-600 dark:text-green-400">{formatINR(poTotal(po))}</span>
        </div>
      </CardContent>
    </Card>
  );
}

// ─── Approval stages (same shape/rendering as PR's, entity-agnostic) ───────

function ApprovalStages({ stages, currentApproverId }: { stages: any[]; currentApproverId?: string }) {
  if (!stages.length) return null;
  return (
    <Card className="shadow-sm">
      <CardHeader className="p-4 sm:p-6 pb-2 sm:pb-3">
        <CardTitle className="text-base sm:text-lg">Approval Workflow</CardTitle>
      </CardHeader>
      <CardContent className="p-4 sm:p-6 pt-0">
        <div className="space-y-2">
          {stages.map((stage: any, idx: number) => {
            const isCurrent = stage.approver_ecno === currentApproverId;
            return (
              <div
                key={idx}
                className={`flex items-start gap-3 p-3 rounded-lg border ${
                  isCurrent
                    ? 'border-blue-300 bg-blue-50 dark:bg-blue-950/20 dark:border-blue-700'
                    : 'border-slate-200 dark:border-slate-800 bg-slate-50/50 dark:bg-slate-900/30'
                }`}
              >
                <div className={`flex-shrink-0 w-6 h-6 rounded-full text-xs font-bold flex items-center justify-center mt-0.5 ${
                  isCurrent ? 'bg-blue-600 text-white' : 'bg-slate-200 dark:bg-slate-700 text-slate-600 dark:text-slate-400'
                }`}>
                  {idx + 1}
                </div>
                <div className="flex-1 min-w-0 space-y-1">
                  <div className="flex items-center justify-between gap-2 flex-wrap">
                    <p className="text-sm font-semibold text-slate-900 dark:text-slate-50">{stage.stage ?? `Stage ${idx + 1}`}</p>
                    {isCurrent && (
                      <Badge className="text-xs bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-300 border-0">Current</Badge>
                    )}
                  </div>
                  <p className="text-xs text-slate-500 dark:text-slate-400">
                    Approver: <span className="font-medium text-slate-700 dark:text-slate-300">{stage.approver_ecno}</span>
                  </p>
                </div>
              </div>
            );
          })}
        </div>
      </CardContent>
    </Card>
  );
}

// ─── Items table ────────────────────────────────────────────────────────

function ItemsTable({ items }: { items: any[] }) {
  if (!items.length) return null;
  const total = items.reduce((sum, it) => sum + Number(it.net_cost ?? it.qty * it.agreed_unit_price), 0);
  return (
    <Card className="shadow-sm">
      <CardHeader className="p-4 sm:p-6 pb-2 sm:pb-3">
        <CardTitle className="text-base sm:text-lg">Items</CardTitle>
      </CardHeader>
      <CardContent className="p-4 sm:p-6 pt-0 overflow-x-auto">
        <table className="w-full text-xs sm:text-sm border-collapse">
          <thead>
            <tr className="border-b border-slate-200 dark:border-slate-800 text-left text-slate-500">
              <th className="py-2 pr-2">Service</th>
              <th className="py-2 pr-2 text-right">Qty</th>
              <th className="py-2 pr-2">Unit</th>
              <th className="py-2 pr-2 text-right">Rate</th>
              <th className="py-2 text-right">Amount</th>
            </tr>
          </thead>
          <tbody>
            {items.map((it, idx) => (
              <tr key={idx} className="border-b border-slate-100 dark:border-slate-900">
                <td className="py-2 pr-2">{it.service_name || '-'}</td>
                <td className="py-2 pr-2 text-right">{it.qty}</td>
                <td className="py-2 pr-2">{it.unit_name || '-'}</td>
                <td className="py-2 pr-2 text-right">{formatINR(it.agreed_unit_price)}</td>
                <td className="py-2 text-right font-medium">{formatINR(Number(it.net_cost ?? it.qty * it.agreed_unit_price))}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <div className="flex justify-end pt-3 text-sm font-semibold">
          <span className="text-slate-500 font-normal mr-2">Total</span>
          <span className="text-green-600 dark:text-green-400">{formatINR(total)}</span>
        </div>
      </CardContent>
    </Card>
  );
}

// ─── Detail panel ─────────────────────────────────────────────────────────

function PODetailPanel({ po, handleAction, fieldDatas }: { po: any; handleAction: (a: string) => void; fieldDatas: FieldType[] }) {
  const { canEdit } = usePermissions();
  const { userData } = useAppState();
  const userEcno = userData[0]?.ecno ?? userData[0]?.login_id;
  const isCurrentApprover = po.current_approver_id && userEcno && String(po.current_approver_id).trim() === String(userEcno).trim();
  const stages = useMemo(() => parseStages(po), [po]);
  const items = useMemo(() => parseItems(po), [po]);
  const statusLabel = getStatusLabel(po.status);

  return (
    <div className="p-3 sm:p-4 md:p-6 lg:p-8 space-y-4 sm:space-y-6">
      <div className="flex items-center justify-between flex-wrap gap-2">
        <h1 className="text-xl sm:text-2xl font-bold text-slate-900 dark:text-slate-50">Service Purchase Order</h1>
        <Badge variant="outline" className="text-xs sm:text-sm flex items-center gap-1">
          <Clock className="h-3 w-3" />{statusLabel}
        </Badge>
      </div>

      <div className="grid grid-cols-1 xl:grid-cols-3 gap-4 sm:gap-6">
        <div className="xl:col-span-2 space-y-4 sm:space-y-6">
          <Card className="shadow-sm">
            <CardHeader className="bg-gradient-to-r from-blue-50 to-indigo-50 dark:from-blue-950/20 dark:to-indigo-950/20 p-4 sm:p-6">
              <div className="flex flex-col gap-2">
                <CardTitle className="text-lg sm:text-xl">{po.po_no}</CardTitle>
                {po.purpose && <CardDescription className="text-sm sm:text-base">{po.purpose}</CardDescription>}
              </div>
            </CardHeader>

            <CardContent className="p-4 sm:p-6 space-y-4">
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                {fieldDatas.filter(f => f.view !== false).map(f => {
                  const rawVal = po[f.field];
                  if (rawVal == null || rawVal === '') return null;
                  const displayVal = f.type === 'date' ? formatDate(String(rawVal)) : String(rawVal);
                  return (
                    <div key={f.field} className="flex items-start gap-2 sm:gap-3 p-3 rounded-lg bg-slate-50 dark:bg-slate-900/50">
                      <div className="min-w-0 flex-1">
                        <p className="text-xs font-medium text-slate-500 dark:text-slate-400">{f.label}</p>
                        <p className="text-sm sm:text-base font-semibold truncate">{displayVal}</p>
                      </div>
                    </div>
                  );
                })}
              </div>
            </CardContent>
          </Card>

          <ItemsTable items={items} />

          <ApprovalStages stages={stages} currentApproverId={po.current_approver_id} />
        </div>

        <div className="xl:col-span-1">
          <Card className="shadow-sm xl:sticky xl:top-6">
            <CardHeader className="p-4 sm:p-6 pb-3">
              <CardTitle className="text-base sm:text-lg">Approval Actions</CardTitle>
              <CardDescription className="text-xs sm:text-sm">Review and take action on this Service PO</CardDescription>
            </CardHeader>

            <CardContent className="p-4 sm:p-6 pt-0 space-y-3 sm:space-y-4">
              {canEdit("ServicePOApprovalScreen") && isCurrentApprover ? (
                <>
                  <Button
                    onClick={() => handleAction('approve')}
                    className="w-full h-10 sm:h-11 text-sm bg-gradient-to-r from-green-600 to-green-700 hover:from-green-700 hover:to-green-800"
                    size="lg"
                  >
                    <CheckCircle2 className="mr-2 h-4 w-4 sm:h-5 sm:w-5" />Approve PO
                  </Button>
                  <Button onClick={() => handleAction('reject')} variant="destructive" className="w-full h-10 sm:h-11 text-sm" size="lg">
                    <XCircle className="mr-2 h-4 w-4 sm:h-5 sm:w-5" />Reject PO
                  </Button>
                </>
              ) : (
                <p className="text-xs text-muted-foreground text-center py-2">View only — no approval permission</p>
              )}

              <Separator />

              <div className="space-y-2 text-xs sm:text-sm">
                <div className="flex justify-between items-center">
                  <span className="text-slate-500">Status</span>
                  <Badge variant="outline" className="text-xs">{statusLabel}</Badge>
                </div>
                {po.current_approver_id && (
                  <div className="flex justify-between items-center gap-2">
                    <span className="text-slate-500 shrink-0">Approver</span>
                    <span className="font-semibold truncate text-right">{po.current_approver_id}</span>
                  </div>
                )}
              </div>
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  );
}

// ─── Empty state ──────────────────────────────────────────────────────────

function POEmptyState({ onOpenList }: { onOpenList: () => void }) {
  return (
    <div className="flex items-center justify-center h-full p-4">
      <div className="text-center space-y-3">
        <Layers className="h-12 w-12 sm:h-16 sm:w-16 text-slate-300 dark:text-slate-700 mx-auto" />
        <h3 className="text-lg sm:text-xl font-semibold text-slate-600 dark:text-slate-400">No Service PO Selected</h3>
        <p className="text-xs sm:text-sm text-slate-500 max-w-xs mx-auto">
          Select a Service PO from the list to view details and take action
        </p>
        <Button variant="outline" className="lg:hidden mt-2" onClick={onOpenList}>
          <Layers className="h-4 w-4 mr-2" />View List
        </Button>
      </div>
    </div>
  );
}

// ─── Root layout ──────────────────────────────────────────────────────────

export default function ServicePOApprovalScreenLayout({
  approvalName, poList, selectedPO, handlePOSelect, handleAction,
  showApprovalDialog, setShowApprovalDialog, comments, setComments,
  handleSubmit, loading, actionType, fieldDatas, toast,
}: ServicePOApprovalScreenLayoutProps) {
  return (
    <>
      <SidebarDetailLayout
        sidebarTitle={approvalName}
        sidebarCount={poList.length}
        sidebarCountLabel="PO"
        toast={toast}
        listItems={(closeSheet) =>
          poList.length === 0 ? (
            <p className="p-6 text-center text-sm text-slate-500">No pending Service POs</p>
          ) : (
            poList.map((po: any) => (
              <POListCard
                key={po.po_no}
                po={po}
                isSelected={selectedPO?.po_no === po.po_no}
                onClick={() => { handlePOSelect(po); closeSheet(); }}
              />
            ))
          )
        }
        hasSelection={!!selectedPO}
        detailContent={
          selectedPO
            ? <PODetailPanel po={selectedPO} handleAction={handleAction} fieldDatas={fieldDatas} />
            : null
        }
        emptyContent={<POEmptyState onOpenList={() => {}} />}
        mobileListLabel="Service PO List"
        mobileSelectionTitle={selectedPO?.po_no}
      />

      <Dialog open={showApprovalDialog} onOpenChange={setShowApprovalDialog}>
        <DialogContent className="sm:max-w-md max-h-[90vh] overflow-y-auto mx-4">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2 text-base sm:text-lg">
              {actionType === 'approve'
                ? <><CheckCircle2 className="h-5 w-5 text-green-600" /> Approve Service PO</>
                : <><XCircle className="h-5 w-5 text-red-600" /> Reject Service PO</>}
            </DialogTitle>
            <DialogDescription className="text-xs sm:text-sm">
              {actionType === 'approve'
                ? 'Optionally add a comment before approving.'
                : 'Please provide a reason for rejection.'}
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4 py-2">
            {actionType === 'approve' && (
              <div className="p-3 rounded-lg bg-green-50 dark:bg-green-950/20 border border-green-200 dark:border-green-800">
                <p className="text-xs sm:text-sm font-semibold text-green-900 dark:text-green-100">Confirming Approval</p>
                <p className="text-xs text-green-700 dark:text-green-300 mt-0.5">
                  If this is the final stage, the PO PDF is generated and emailed to the supplier immediately.
                </p>
              </div>
            )}

            <div className="space-y-1.5">
              <Label htmlFor="po-comments" className="text-xs sm:text-sm">
                Comments {actionType === 'reject' && <span className="text-red-500">*</span>}
              </Label>
              <Textarea
                id="po-comments"
                placeholder={actionType === 'approve' ? 'Any additional notes…' : 'Reason for rejection…'}
                value={comments}
                onChange={e => setComments(e.target.value)}
                rows={3}
                className="resize-none text-sm"
              />
            </div>

            {selectedPO && (
              <div className="p-3 rounded-lg bg-slate-50 dark:bg-slate-900 space-y-2 text-xs sm:text-sm">
                <div className="flex justify-between gap-2">
                  <span className="text-slate-500">PO No</span>
                  <span className="font-semibold">{selectedPO.po_no}</span>
                </div>
                <div className="flex justify-between gap-2">
                  <span className="text-slate-500">Amount</span>
                  <span className="font-semibold text-green-600 dark:text-green-400">{formatINR(poTotal(selectedPO))}</span>
                </div>
              </div>
            )}
          </div>

          <DialogFooter className="flex-col sm:flex-row gap-2">
            <Button variant="outline" onClick={() => setShowApprovalDialog(false)} disabled={loading} className="w-full sm:w-auto text-sm">
              Cancel
            </Button>
            <Button
              onClick={handleSubmit}
              disabled={loading || (actionType === 'reject' && !comments.trim())}
              className={`w-full sm:w-auto text-sm ${actionType === 'approve' ? 'bg-green-600 hover:bg-green-700' : 'bg-red-600 hover:bg-red-700'}`}
            >
              {loading ? (
                <><Clock className="mr-2 h-4 w-4 animate-spin" />Processing…</>
              ) : actionType === 'approve' ? (
                <><CheckCircle2 className="mr-2 h-4 w-4" />Confirm Approval</>
              ) : (
                <><XCircle className="mr-2 h-4 w-4" />Confirm Rejection</>
              )}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
