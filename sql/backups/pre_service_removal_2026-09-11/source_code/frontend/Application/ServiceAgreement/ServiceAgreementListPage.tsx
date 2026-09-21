import React, { useMemo, useState } from 'react';
import axios from 'axios';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from '@/components/ui/dialog';
import { ClipboardList, Pencil, RefreshCw, Send, Repeat, Wallet, Truck, Loader2, FileText, CalendarClock, Eye } from 'lucide-react';
import { PageHeader, FormSection } from '@/CustomComponent/PageComponents';
import { CustomInputField } from '@/CustomComponent/InputComponents/CustomInputField';
import { useServiceAgreementFields, type AgreementType } from '@/FieldDatas/ServiceAgreementData';
import { getServiceAgreements, getAllServicePOs, updateServiceAgreement } from '@/Services/Api';
import { usePermissions } from '@/globalState/hooks/usePermissions';
import useFetch from '@/hooks/useFetchHook';

interface AgreementRow {
  agreement_sno: number;
  agreement_no: string;
  com_sno: number; div_sno: number; brn_sno: number; dept_sno: number;
  service_sno: number; service_name: string; service_type_code: AgreementType;
  vendor_sno?: number; vendor_name?: string;
  rate_amount?: number; rate_uom_sno?: number; rate_uom_name?: string;
  ceiling_amount?: number; variance_tolerance_pct?: number;
  recurrence_cadence?: string; recurrence_cadence_sno?: number;
  po_generation_day?: number; notify_days_before?: number;
  period_start_date: string; period_end_date: string;
  agreement_doc_url: string; remarks?: string;
  status: 'P' | 'A' | 'R' | 'X';
  created_by?: string; created_at?: string;
}

interface PoItem {
  po_item_sno: number; service_sno?: number; service_name?: string;
  qty: number; unit_name?: string; agreed_unit_price: number; net_cost?: number;
}

interface VendorPoRow {
  po_basic_sno: number; po_no: string; pr_no?: string; vendor_sno?: number; vendor_name?: string;
  po_type: string; service_type_code: string; service_type_name: string;
  validity_from?: string; validity_to?: string; ceiling_amount?: number; consumed_amount?: number;
  status: string; po_pdf_url?: string; items?: string | PoItem[];
}

function parsePoItems(raw?: string | PoItem[]): PoItem[] {
  if (!raw) return [];
  try {
    return typeof raw === 'string' ? JSON.parse(raw) : raw;
  } catch { return []; }
}

function poAmount(po: VendorPoRow): number {
  return parsePoItems(po.items).reduce((sum, it) => sum + Number(it.net_cost ?? it.qty * it.agreed_unit_price), 0);
}

const STATUS_LABELS: Record<string, string> = { P: 'Pending', A: 'Approved', R: 'Rejected', X: 'Expired' };
const STATUS_COLORS: Record<string, string> = {
  P: 'bg-amber-100 text-amber-700', A: 'bg-emerald-100 text-emerald-700',
  R: 'bg-red-100 text-red-700', X: 'bg-slate-100 text-slate-600',
};

const NAME_FIELD_MAP: Record<string, string> = {
  com_sno: 'com_name', div_sno: 'div_name', brn_sno: 'brn_name', dept_sno: 'dept_name',
  service_sno: 'service_name', vendor_sno: 'vendor_name', rate_uom_sno: 'rate_uom_name',
  recurrence_cadence_sno: 'cadence_name',
};
const resolveNameField = (fieldName: string) => NAME_FIELD_MAP[fieldName] ?? fieldName.replace('_sno', '_name');

const dateOnly = (v?: string) => (v ? v.slice(0, 10) : '');

// ── Edit dialog — reuses the exact field set the create form uses
// (useServiceAgreementFields), pre-filled from the selected row, submitting
// to updateServiceAgreement (re-enters approval — see
// sql/51_service_agreement_edit_reapproval.sql). ─────────────────────────────
const EditAgreementDialog: React.FC<{ row: AgreementRow; onClose: () => void; onSaved: () => void }> = ({ row, onClose, onSaved }) => {
  const agreementType = row.service_type_code;
  const [selectedCompany, setSelectedCompany] = useState(String(row.com_sno));
  const [selectedDivision, setSelectedDivision] = useState(String(row.div_sno));
  const [selectedBranch, setSelectedBranch] = useState(String(row.brn_sno));
  const [submitting, setSubmitting] = useState(false);
  const [errors, setErrors] = useState<Record<string, string>>({});

  const baseFields = useServiceAgreementFields({ agreementType, selectedCompany, selectedDivision, selectedBranch });
  // Editing never forces a fresh document upload — the existing
  // agreement_doc_url carries forward unless the user picks a new file.
  const fields = useMemo(
    () => baseFields.map((f) => (f.field === 'agreement_document' ? { ...f, require: false, label: 'Replace Agreement Document (optional)' } : f)),
    [baseFields]
  );

  const [formData, setFormData] = useState<Record<string, any>>(() => ({
    com_sno: row.com_sno, div_sno: row.div_sno, brn_sno: row.brn_sno, dept_sno: row.dept_sno,
    service_sno: row.service_sno, service_name: row.service_name,
    vendor_sno: row.vendor_sno ?? '', vendor_name: row.vendor_name ?? '',
    rate_amount: row.rate_amount ?? '', rate_uom_sno: row.rate_uom_sno ?? '', rate_uom_name: row.rate_uom_name ?? '',
    ceiling_amount: row.ceiling_amount ?? '', variance_tolerance_pct: row.variance_tolerance_pct ?? '',
    recurrence_cadence_sno: row.recurrence_cadence_sno ?? '',
    po_generation_day: row.po_generation_day ?? '', notify_days_before: row.notify_days_before ?? 0,
    period_start_date: dateOnly(row.period_start_date), period_end_date: dateOnly(row.period_end_date),
    agreement_document: null, agreement_doc_url: row.agreement_doc_url,
    remarks: row.remarks ?? '',
  }));

  const handleFieldChange = (fieldName: string, value: any) => {
    setFormData((prev) => {
      const updated = { ...prev, [fieldName]: value };
      if (fieldName === 'com_sno') {
        updated.div_sno = ''; updated.div_name = ''; updated.brn_sno = ''; updated.brn_name = '';
        updated.dept_sno = ''; updated.dept_name = '';
        setSelectedCompany(String(value)); setSelectedDivision(''); setSelectedBranch('');
      } else if (fieldName === 'div_sno') {
        updated.brn_sno = ''; updated.brn_name = ''; updated.dept_sno = ''; updated.dept_name = '';
        setSelectedDivision(String(value)); setSelectedBranch('');
      } else if (fieldName === 'brn_sno') {
        updated.dept_sno = ''; updated.dept_name = '';
        setSelectedBranch(String(value));
      }
      const field = fields.find((f) => f.field === fieldName);
      if (field?.options && Array.isArray(field.options)) {
        const opt = (field.options as any[]).find((o) => String(o.value) === String(value));
        if (opt) updated[resolveNameField(fieldName)] = opt.label;
      }
      return updated;
    });
    if (errors[fieldName]) setErrors((prev) => { const e = { ...prev }; delete e[fieldName]; return e; });
  };

  const inputFields = useMemo(() => fields.filter((f) => f.input), [fields]);
  const gridFields = useMemo(() => inputFields.filter((f) => f.type !== 'textarea' && f.type !== 'file'), [inputFields]);
  const textareaFields = useMemo(() => inputFields.filter((f) => f.type === 'textarea'), [inputFields]);
  const fileField = useMemo(() => inputFields.find((f) => f.type === 'file') ?? null, [inputFields]);

  const validate = (): boolean => {
    const errs: Record<string, string> = {};
    inputFields.forEach((f) => { if (f.require && !formData[f.field]) errs[f.field] = `${f.label} is required`; });
    setErrors(errs);
    return Object.keys(errs).length === 0;
  };

  const handleSubmit = async () => {
    if (!validate()) return;
    setSubmitting(true);
    try {
      const fd = new FormData();
      fd.append('agreement_sno', String(row.agreement_sno));
      Object.entries(formData).forEach(([key, value]) => {
        if (key === 'agreement_document') return;
        if (value === null || value === undefined || value === '') return;
        fd.append(key, String(value));
      });
      if (formData.agreement_document instanceof File) fd.append('agreement_document', formData.agreement_document);

      await axios.post(updateServiceAgreement, fd, { headers: { 'Content-Type': 'multipart/form-data' } });
      toast.success(`${row.agreement_no} updated and resubmitted for approval`);
      onSaved();
    } catch (error: any) {
      toast.error(error?.response?.data?.error ?? 'Failed to update agreement');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Dialog open onOpenChange={(open) => { if (!open) onClose(); }}>
      <DialogContent className="max-w-3xl max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Edit {row.agreement_no}</DialogTitle>
          <DialogDescription>
            Saving resubmits this agreement for approval — the current Approved values stay in effect until it's approved again.
          </DialogDescription>
        </DialogHeader>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-5">
          {gridFields.map((field) => (
            <div key={field.field} data-error={!!errors[field.field]} className="flex flex-col">
              <CustomInputField
                field={field.field}
                label={field.label}
                require={field.require}
                type={field.type}
                options={field.options}
                value={formData[field.field] ?? ''}
                onChange={(value) => handleFieldChange(field.field, value)}
                error={errors[field.field]}
                placeholder={field.placeholder}
                className="h-10"
              />
            </div>
          ))}
        </div>

        {textareaFields.map((field) => (
          <div key={field.field} data-error={!!errors[field.field]}>
            <CustomInputField
              field={field.field} label={field.label} require={field.require} type={field.type}
              value={formData[field.field] ?? ''} onChange={(value) => handleFieldChange(field.field, value)}
              error={errors[field.field]} rows={2} className="resize-none"
            />
          </div>
        ))}

        {fileField && (
          <div data-error={!!errors[fileField.field]} className="max-w-xs">
            <CustomInputField
              field={fileField.field} label={fileField.label} require={fileField.require} type={fileField.type}
              value={formData[fileField.field] ?? null} onChange={(file) => handleFieldChange(fileField.field, file)}
              error={errors[fileField.field]}
            />
          </div>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={submitting}>Cancel</Button>
          <Button onClick={handleSubmit} disabled={submitting}>
            {submitting ? <><Loader2 size={15} className="animate-spin mr-1" /> Saving…</> : <><Send size={15} className="mr-1" /> Save & Resubmit</>}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

// Full item-level breakdown for one recurring PO — the summary row only
// shows concatenated service names, not qty/rate/tax, which "view the
// details" needs.
const RecurringPoDetailDialog: React.FC<{ po: VendorPoRow; onClose: () => void }> = ({ po, onClose }) => {
  const items = parsePoItems(po.items);
  const total = poAmount(po);
  return (
    <Dialog open onOpenChange={(open) => { if (!open) onClose(); }}>
      <DialogContent className="max-w-2xl max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{po.po_no}</DialogTitle>
          <DialogDescription>
            {po.vendor_name ?? 'No vendor'} · {po.service_type_name ?? po.service_type_code}
            {po.pr_no ? ` · Source PR ${po.pr_no}` : ''}
          </DialogDescription>
        </DialogHeader>

        <div className="grid grid-cols-2 gap-3 text-sm">
          <div><span className="text-muted-foreground">Status</span><br />
            <Badge className={STATUS_COLORS[po.status] ?? ''} variant="secondary">{STATUS_LABELS[po.status] ?? po.status}</Badge>
          </div>
          <div><span className="text-muted-foreground">Validity</span><br />
            {dateOnly(po.validity_from)} – {dateOnly(po.validity_to)}
          </div>
        </div>

        <div className="border rounded-lg overflow-x-auto mt-2">
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
              {items.length === 0 ? (
                <TableRow><TableCell colSpan={5} className="text-center py-6 text-muted-foreground">No items</TableCell></TableRow>
              ) : items.map((it) => (
                <TableRow key={it.po_item_sno}>
                  <TableCell>{it.service_name ?? '-'}</TableCell>
                  <TableCell className="text-right">{it.qty}</TableCell>
                  <TableCell>{it.unit_name ?? '-'}</TableCell>
                  <TableCell className="text-right">₹{Number(it.agreed_unit_price).toLocaleString('en-IN')}</TableCell>
                  <TableCell className="text-right font-medium">
                    ₹{Number(it.net_cost ?? it.qty * it.agreed_unit_price).toLocaleString('en-IN')}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>

        <div className="flex justify-end pt-1 text-sm font-semibold">
          <span className="text-muted-foreground font-normal mr-2">Total</span>₹{total.toLocaleString('en-IN')}
        </div>

        <DialogFooter className="flex-row justify-between sm:justify-between items-center">
          {po.po_pdf_url ? (
            <Button variant="outline" size="sm" asChild>
              <a href={po.po_pdf_url} target="_blank" rel="noreferrer"><FileText size={14} className="mr-1" />View PO PDF</a>
            </Button>
          ) : <span className="text-xs text-muted-foreground">No PDF generated for this PO yet</span>}
          <Button variant="outline" onClick={onClose}>Close</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

const ServiceAgreementListPage: React.FC = () => {
  const { canEdit } = usePermissions();
  const canEditAgreements = canEdit('ServiceAgreementListPage');

  const [activeTab, setActiveTab] = useState<'fixed' | 'variable' | 'vendor' | 'recurring'>('fixed');
  const [refreshKey, setRefreshKey] = useState(0);
  const [editingRow, setEditingRow] = useState<AgreementRow | null>(null);
  const [viewingPo, setViewingPo] = useState<VendorPoRow | null>(null);

  const { data: agreementsRes, loading: loadingAgreements } = useFetch<{ success: boolean; data: AgreementRow[] }>(
    getServiceAgreements, '', null, refreshKey
  );
  const { data: posRes, loading: loadingPos } = useFetch<{ success: boolean; data: VendorPoRow[] }>(
    getAllServicePOs, '', null, refreshKey
  );

  const agreements = agreementsRes?.data ?? [];
  const fixedRows = useMemo(() => agreements.filter((a) => a.service_type_code === 'FIXED_RECURRING'), [agreements]);
  const variableRows = useMemo(() => agreements.filter((a) => a.service_type_code === 'VARIABLE_RECURRING'), [agreements]);
  const vendorPos = useMemo(() => (posRes?.data ?? []).filter((p) => p.service_type_code === 'VENDOR_BILL'), [posRes]);
  // Recurring POs — auto-issued off an approved Fixed/Variable Recurring
  // Service Agreement (sp_nt_IssueRecurringServicePOCycle / manual approval
  // via ServicePOApprovalScreen). Previously not shown on any screen at all.
  const recurringPos = useMemo(
    () => (posRes?.data ?? []).filter((p) => p.service_type_code === 'FIXED_RECURRING' || p.service_type_code === 'VARIABLE_RECURRING'),
    [posRes]
  );

  const refresh = () => setRefreshKey((k) => k + 1);

  const renderAgreementTable = (rows: AgreementRow[], amountLabel: string, amountKey: 'rate_amount' | 'ceiling_amount') => (
    <div className="border rounded-lg overflow-x-auto">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Agreement No</TableHead>
            <TableHead>Service</TableHead>
            <TableHead>Supplier</TableHead>
            <TableHead className="text-right">{amountLabel}</TableHead>
            <TableHead>Period</TableHead>
            <TableHead>Status</TableHead>
            <TableHead className="w-20" />
          </TableRow>
        </TableHeader>
        <TableBody>
          {loadingAgreements ? (
            <TableRow><TableCell colSpan={7} className="text-center py-8 text-muted-foreground">
              <Loader2 size={16} className="inline animate-spin mr-2" />Loading…
            </TableCell></TableRow>
          ) : rows.length === 0 ? (
            <TableRow><TableCell colSpan={7} className="text-center py-8 text-muted-foreground">No agreements</TableCell></TableRow>
          ) : rows.map((row) => (
            <TableRow key={row.agreement_sno}>
              <TableCell className="font-medium">{row.agreement_no}</TableCell>
              <TableCell>{row.service_name}</TableCell>
              <TableCell>{row.vendor_name ?? '—'}</TableCell>
              <TableCell className="text-right">{row[amountKey] != null ? Number(row[amountKey]).toLocaleString('en-IN') : '—'}</TableCell>
              <TableCell className="text-xs text-muted-foreground">{dateOnly(row.period_start_date)} – {dateOnly(row.period_end_date)}</TableCell>
              <TableCell><Badge className={STATUS_COLORS[row.status]} variant="secondary">{STATUS_LABELS[row.status] ?? row.status}</Badge></TableCell>
              <TableCell>
                {canEditAgreements && row.status !== 'P' && (
                  <Button size="sm" variant="ghost" onClick={() => setEditingRow(row)}>
                    <Pencil size={14} className="mr-1" /> Edit
                  </Button>
                )}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );

  return (
    <div className="flex flex-col min-h-full bg-muted/20">
      <PageHeader icon={ClipboardList} title="Service Agreements" description="Browse existing recurring services and edit Fixed / Variable agreements">
        <Button variant="outline" size="sm" className="bg-primary-foreground/10 border-primary-foreground/20 text-primary-foreground hover:bg-primary-foreground/20" onClick={refresh}>
          <RefreshCw size={15} className="mr-1" /> Refresh
        </Button>
      </PageHeader>

      <div className="p-4 sm:p-6 space-y-4">
        <Tabs value={activeTab} onValueChange={(v) => setActiveTab(v as any)}>
          <TabsList>
            <TabsTrigger value="fixed"><Repeat size={14} className="mr-1" /> Fixed Recurring ({fixedRows.length})</TabsTrigger>
            <TabsTrigger value="variable"><Wallet size={14} className="mr-1" /> Unfixed Recurring ({variableRows.length})</TabsTrigger>
            <TabsTrigger value="vendor"><Truck size={14} className="mr-1" /> Vendor Driven ({vendorPos.length})</TabsTrigger>
            <TabsTrigger value="recurring"><CalendarClock size={14} className="mr-1" /> Recurring POs ({recurringPos.length})</TabsTrigger>
          </TabsList>

          <TabsContent value="fixed" className="mt-4">{renderAgreementTable(fixedRows, 'Rate', 'rate_amount')}</TabsContent>
          <TabsContent value="variable" className="mt-4">{renderAgreementTable(variableRows, 'Ceiling', 'ceiling_amount')}</TabsContent>
          <TabsContent value="vendor" className="mt-4">
            <Card><CardContent className="p-0">
              <div className="border rounded-lg overflow-x-auto">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>PO No</TableHead>
                      <TableHead>Supplier</TableHead>
                      <TableHead>Type</TableHead>
                      <TableHead className="text-right">Ceiling</TableHead>
                      <TableHead className="text-right">Consumed</TableHead>
                      <TableHead>Status</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {loadingPos ? (
                      <TableRow><TableCell colSpan={6} className="text-center py-8 text-muted-foreground">
                        <Loader2 size={16} className="inline animate-spin mr-2" />Loading…
                      </TableCell></TableRow>
                    ) : vendorPos.length === 0 ? (
                      <TableRow><TableCell colSpan={6} className="text-center py-8 text-muted-foreground">No Vendor Driven POs</TableCell></TableRow>
                    ) : vendorPos.map((po) => (
                      <TableRow key={po.po_basic_sno}>
                        <TableCell className="font-medium">{po.po_no}</TableCell>
                        <TableCell>{po.vendor_name ?? '—'}</TableCell>
                        <TableCell className="text-xs">{po.po_type}</TableCell>
                        <TableCell className="text-right">{po.ceiling_amount != null ? Number(po.ceiling_amount).toLocaleString('en-IN') : '—'}</TableCell>
                        <TableCell className="text-right">{po.consumed_amount != null ? Number(po.consumed_amount).toLocaleString('en-IN') : '—'}</TableCell>
                        <TableCell><Badge variant="secondary">{po.status}</Badge></TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
              <p className="text-xs text-muted-foreground p-3">
                Vendor Driven services are one-shot retrospective POs, not recurring agreements — read-only here, no edit action.
              </p>
            </CardContent></Card>
          </TabsContent>

          <TabsContent value="recurring" className="mt-4">
            <Card><CardContent className="p-0">
              <div className="border rounded-lg overflow-x-auto">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>PO No</TableHead>
                      <TableHead>Vendor</TableHead>
                      <TableHead>Service</TableHead>
                      <TableHead>Billing Pattern</TableHead>
                      <TableHead className="text-right">Amount</TableHead>
                      <TableHead>Validity</TableHead>
                      <TableHead>Status</TableHead>
                      <TableHead className="w-16" />
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {loadingPos ? (
                      <TableRow><TableCell colSpan={8} className="text-center py-8 text-muted-foreground">
                        <Loader2 size={16} className="inline animate-spin mr-2" />Loading…
                      </TableCell></TableRow>
                    ) : recurringPos.length === 0 ? (
                      <TableRow><TableCell colSpan={8} className="text-center py-8 text-muted-foreground">No recurring Service POs yet</TableCell></TableRow>
                    ) : recurringPos.map((po) => {
                      const items = parsePoItems(po.items);
                      return (
                        <TableRow key={po.po_basic_sno}>
                          <TableCell className="font-medium">{po.po_no}</TableCell>
                          <TableCell>{po.vendor_name ?? '—'}</TableCell>
                          <TableCell className="text-xs">{items.map((it) => it.service_name).filter(Boolean).join(', ') || '—'}</TableCell>
                          <TableCell className="text-xs">{po.service_type_name ?? po.service_type_code}</TableCell>
                          <TableCell className="text-right font-medium">₹{poAmount(po).toLocaleString('en-IN')}</TableCell>
                          <TableCell className="text-xs text-muted-foreground">{dateOnly(po.validity_from)} – {dateOnly(po.validity_to)}</TableCell>
                          <TableCell><Badge className={STATUS_COLORS[po.status] ?? ''} variant="secondary">{STATUS_LABELS[po.status] ?? po.status}</Badge></TableCell>
                          <TableCell>
                            <Button size="sm" variant="ghost" onClick={() => setViewingPo(po)} title="View details">
                              <Eye size={14} />
                            </Button>
                          </TableCell>
                        </TableRow>
                      );
                    })}
                  </TableBody>
                </Table>
              </div>
              <p className="text-xs text-muted-foreground p-3">
                Auto-issued off an approved recurring Service Agreement (or manually approved via Service PO Approvals) — each row is one billing cycle's PO. A PDF only appears once that cycle's PO has actually been emailed to a supplier via Service PO Approvals; agreement-driven auto-issue doesn't generate one on its own.
              </p>
            </CardContent></Card>
          </TabsContent>
        </Tabs>
      </div>

      {editingRow && (
        <EditAgreementDialog
          row={editingRow}
          onClose={() => setEditingRow(null)}
          onSaved={() => { setEditingRow(null); refresh(); }}
        />
      )}

      {viewingPo && (
        <RecurringPoDetailDialog po={viewingPo} onClose={() => setViewingPo(null)} />
      )}
    </div>
  );
};

export default ServiceAgreementListPage;
