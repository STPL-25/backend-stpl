import React, { useState, useMemo, useCallback, useEffect } from 'react';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import {
  FileText, Building2, RefreshCw, Send, Package,
  Repeat, Wallet, Truck, CalendarClock, Bell, ClipboardCheck,
} from 'lucide-react';
import { FormSection, PageHeader } from '@/CustomComponent/PageComponents';
import { CustomInputField } from '@/CustomComponent/InputComponents/CustomInputField';
import {
  useServiceAgreementFields,
  type AgreementType,
} from '@/FieldDatas/ServiceAgreementData';
import { useServiceVendorDailyEntryFields } from '@/FieldDatas/ServiceVendorEntryData';
import axios from 'axios';
import { createServiceAgreement, createServiceVendorEntry, getServiceVendorEntries, getApprovedSuppliersForService } from '@/Services/Api';
import { toast } from 'sonner';
import { usePermissions } from '@/globalState/hooks/usePermissions';
import type { FieldType } from '@/FieldDatas/fieldType/fieldType';
import { cn } from '@/lib/utils';
import useFetch from '@/hooks/useFetchHook';

interface FormErrors {
  [key: string]: string;
}

const NAME_FIELD_MAP: Record<string, string> = {
  com_sno: 'com_name',
  div_sno: 'div_name',
  brn_sno: 'brn_name',
  dept_sno: 'dept_name',
  service_sno: 'service_name',
  vendor_sno: 'vendor_name',
  rate_uom_sno: 'rate_uom_name',
  recurrence_cadence_sno: 'cadence_name',
  unit: 'unit_name',
};

function resolveNameField(fieldName: string): string {
  return NAME_FIELD_MAP[fieldName] ?? fieldName.replace('_sno', '_name');
}

const AGREEMENT_TYPES: { value: AgreementType; label: string; description: string; Icon: React.ElementType }[] = [
  { value: 'FIXED_RECURRING', label: 'Fixed Recurring', description: 'Same amount, auto-generated on a schedule', Icon: Repeat },
  { value: 'VARIABLE_RECURRING', label: 'Unfixed Recurring', description: 'Ceiling-capped, invoice submitted each cycle', Icon: Wallet },
  { value: 'VENDOR_BILL', label: 'Vendor Driven', description: 'Daily entries (e.g. milk) — consolidate later to raise one PO', Icon: Truck },
];

const ServiceAgreementPage: React.FC = () => {
  const { canCreate, canEdit } = usePermissions();
  const permissionComponent = 'ServiceAgreementPage';
  const canSubmit = canCreate(permissionComponent) || canEdit(permissionComponent);

  const [agreementType, setAgreementType] = useState<AgreementType>('FIXED_RECURRING');
  const isVendorDriven = agreementType === 'VENDOR_BILL';

  // Cascade tracking — shared across all three types
  const [selectedCompany, setSelectedCompany] = useState('');
  const [selectedDivision, setSelectedDivision] = useState('');
  const [selectedBranch, setSelectedBranch] = useState('');

  const agreementFields = useServiceAgreementFields({
    agreementType,
    selectedCompany, selectedDivision, selectedBranch,
  });
  const vendorEntryFields = useServiceVendorDailyEntryFields({ selectedCompany, selectedDivision, selectedBranch });

  const activeFields = isVendorDriven ? vendorEntryFields : agreementFields;

  const [formData, setFormData] = useState<Record<string, any>>({});
  const [errors, setErrors] = useState<FormErrors>({});
  const [submitting, setSubmitting] = useState(false);

  // Vendor Driven: entries logged for the currently selected vendor+service —
  // pure visibility, showing whatever status each one is really in
  // (PENDING_APPROVAL until a supervisor reviews it, PENDING once approved
  // and eligible for consolidation, REJECTED, etc).
  const [recentEntries, setRecentEntries] = useState<Record<string, any>[]>([]);
  const [loadingEntries, setLoadingEntries] = useState(false);

  // Predefined-supplier picker (sql/45_service_master_supplier_and_product.sql)
  // — reactive fetch scoped to whichever suppliers are mapped to the
  // currently-selected service, replacing the old globally-scoped VendorMaster
  // list for the vendor_sno field on both the agreement form and the Vendor
  // Driven daily-entry form (same field name in both).
  const { data: supplierData } = useFetch<{ success: boolean; data: any[] }>(
    formData.service_sno ? getApprovedSuppliersForService : null,
    '',
    formData.service_sno ? { service_sno: formData.service_sno } : null
  );
  const approvedSuppliers = useMemo(
    () => (supplierData?.data ?? []).map((v: any) => ({
      value: v.kyc_basic_info_sno, label: v.company_name,
      supp_code: v.supp_code, email: v.email, mobile_number: v.mobile_number,
    })),
    [supplierData]
  );

  // Auto-select the sole predefined supplier — no dropdown interaction
  // needed when there's only one to choose from.
  useEffect(() => {
    if (!formData.service_sno || approvedSuppliers.length !== 1) return;
    const only = approvedSuppliers[0];
    if (formData.vendor_sno === only.value) return;
    setFormData((prev) => ({ ...prev, vendor_sno: only.value, vendor_name: only.label }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [approvedSuppliers, formData.service_sno]);

  // The FieldType arrays above are built from the globally-scoped VendorMaster
  // master; override just the vendor_sno field's options here with the
  // service-scoped list so the dropdown only ever shows valid suppliers.
  const displayFields = useMemo(
    () => activeFields.map((f) => (f.field === 'vendor_sno' ? { ...f, options: approvedSuppliers } : f)),
    [activeFields, approvedSuppliers]
  );

  // Vendor Driven: product details for the selected service (joined server-side
  // in sp_nt_GetServiceRecords v2, riding along on the same ServiceMaster
  // options fetch the service_sno field already uses — no second lookup).
  const selectedVendorDrivenProduct = useMemo(() => {
    if (!isVendorDriven) return null;
    const serviceField = vendorEntryFields.find((f) => f.field === 'service_sno');
    const opt = (serviceField?.options as any[] | undefined)?.find(
      (o) => String(o.value) === String(formData.service_sno)
    );
    return opt?.product_name ? opt : null;
  }, [isVendorDriven, vendorEntryFields, formData.service_sno]);

  const buildInitialFormData = useCallback((fields: FieldType[]) => {
    const d: Record<string, any> = {};
    fields.forEach((field) => {
      if (!field.input) return;
      if (field.defaultValue !== undefined) d[field.field] = field.defaultValue;
      else if (field.type === 'date') d[field.field] = '';
      else if (field.type === 'number') d[field.field] = '';
      else if (field.type === 'file') d[field.field] = null;
      else d[field.field] = '';
    });
    return d;
  }, []);

  // Reset the form whenever the type changes — the three types share no
  // required fields whose values would still be valid across the switch.
  useEffect(() => {
    setFormData(buildInitialFormData(activeFields));
    setErrors({});
    setRecentEntries([]);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [agreementType]);

  const fetchRecentEntries = useCallback(async (vendor_sno: any, service_sno: any) => {
    if (!vendor_sno || !service_sno) {
      setRecentEntries([]);
      return;
    }
    setLoadingEntries(true);
    try {
      // No status filter — shows the entry's real state (PENDING_APPROVAL,
      // PENDING once approved, REJECTED, etc.) so the submitter can see
      // whether their purchase is still awaiting a supervisor's review.
      const res = await axios.get(getServiceVendorEntries, { params: { vendor_sno, service_sno } });
      setRecentEntries(res?.data?.data ?? []);
    } catch {
      // non-fatal — the entry list is a convenience view, not required for logging
    } finally {
      setLoadingEntries(false);
    }
  }, []);

  // Refresh the pending-entries list whenever vendor or service changes
  // while on the Vendor Driven tab.
  useEffect(() => {
    if (!isVendorDriven) return;
    fetchRecentEntries(formData.vendor_sno, formData.service_sno);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isVendorDriven, formData.vendor_sno, formData.service_sno]);

  const handleFieldChange = (fieldName: string, value: any) => {
    setFormData((prev) => {
      const updated = { ...prev, [fieldName]: value };

      if (fieldName === 'com_sno') {
        updated.div_sno = ''; updated.div_name = '';
        updated.brn_sno = ''; updated.brn_name = '';
        updated.dept_sno = ''; updated.dept_name = '';
        setSelectedCompany(String(value));
        setSelectedDivision('');
        setSelectedBranch('');
      } else if (fieldName === 'div_sno') {
        updated.brn_sno = ''; updated.brn_name = '';
        updated.dept_sno = ''; updated.dept_name = '';
        setSelectedDivision(String(value));
        setSelectedBranch('');
      } else if (fieldName === 'brn_sno') {
        updated.dept_sno = ''; updated.dept_name = '';
        setSelectedBranch(String(value));
      } else if (fieldName === 'service_sno') {
        // The predefined-supplier list is scoped to the service — a vendor
        // valid for the old service selection may not be valid for the new
        // one, so clear it (the auto-select effect re-fills it if the new
        // service has exactly one supplier).
        updated.vendor_sno = ''; updated.vendor_name = '';
      }

      const field = activeFields.find((f) => f.field === fieldName);
      if (field?.options && Array.isArray(field.options)) {
        const selectedOption = (field.options as any[]).find((opt) => String(opt.value) === String(value));
        if (selectedOption) updated[resolveNameField(fieldName)] = selectedOption.label;
      }

      return updated;
    });

    if (errors[fieldName]) {
      setErrors((prev) => {
        const e = { ...prev };
        delete e[fieldName];
        return e;
      });
    }
  };

  // ── Validation ──────────────────────────────────────────────────────────

  const inputFields = useMemo(() => displayFields.filter((f) => f.input), [displayFields]);

  const validateForm = (): boolean => {
    const errs: FormErrors = {};
    inputFields.forEach((field) => {
      if (field.require && !formData[field.field]) errs[field.field] = `${field.label} is required`;
    });
    if (isVendorDriven && formData.qty && Number(formData.qty) <= 0) errs.qty = 'Quantity must be greater than 0';
    setErrors(errs);
    return Object.keys(errs).length === 0;
  };

  // ── Submit ──────────────────────────────────────────────────────────────

  const buildAgreementFormData = (): FormData => {
    const fd = new FormData();
    Object.entries(formData).forEach(([key, value]) => {
      if (key === 'agreement_document') return;
      if (value === null || value === undefined || value === '') return;
      fd.append(key, String(value));
    });
    if (formData.agreement_document instanceof File) {
      fd.append('agreement_document', formData.agreement_document);
    }
    return fd;
  };

  const buildVendorEntryFormData = (): FormData => {
    const fd = new FormData();
    fd.append('com_sno', String(formData.com_sno));
    fd.append('div_sno', String(formData.div_sno));
    fd.append('brn_sno', String(formData.brn_sno));
    fd.append('dept_sno', String(formData.dept_sno));
    fd.append('vendor_sno', String(formData.vendor_sno));
    fd.append('service_sno', String(formData.service_sno));
    fd.append('entry_date', String(formData.entry_date));
    fd.append('qty', String(formData.qty));
    if (formData.unit) fd.append('unit', String(formData.unit));
    fd.append('unit_price', String(formData.unit_price));
    if (formData.specification) fd.append('specification', String(formData.specification));
    if (formData.remarks) fd.append('remarks', String(formData.remarks));
    if (formData.receipt_document instanceof File) {
      fd.append('receipt_document', formData.receipt_document);
    }
    return fd;
  };

  const handleReset = () => {
    setFormData(buildInitialFormData(activeFields));
    setErrors({});
    setSelectedCompany(''); setSelectedDivision(''); setSelectedBranch('');
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!validateForm()) return;

    if (!isVendorDriven && !(formData.agreement_document instanceof File)) {
      setErrors((prev) => ({ ...prev, agreement_document: 'Agreement document is required' }));
      return;
    }
    if (isVendorDriven && !(formData.receipt_document instanceof File)) {
      setErrors((prev) => ({ ...prev, receipt_document: "Today's receipt/bill is required" }));
      return;
    }

    setSubmitting(true);
    try {
      if (isVendorDriven) {
        const res = await axios.post(createServiceVendorEntry, buildVendorEntryFormData(), {
          headers: { 'Content-Type': 'multipart/form-data' },
        });
        const entry = res?.data?.data;
        toast.success(`Entry logged for ${formData.entry_date}${entry?.total_amount != null ? ` — total ₹${entry.total_amount}` : ''}. Consolidate accumulated entries on "Vendor Entry Consolidation" when ready to raise the PO.`);

        // Soft reset: keep org/vendor/service selected (the common case is
        // logging several days in a row for the same vendor+service),
        // clear only what's specific to today's entry.
        setFormData((prev) => ({ ...prev, qty: '', unit_price: '', specification: '', remarks: '', receipt_document: null }));
        await fetchRecentEntries(formData.vendor_sno, formData.service_sno);
      } else {
        const res = await axios.post(createServiceAgreement, buildAgreementFormData(), {
          headers: { 'Content-Type': 'multipart/form-data' },
        });
        const data = res?.data?.data;
        toast.success(`Service Agreement ${data?.agreement_no ?? ''} submitted for approval`);
        handleReset();
      }
    } catch (error: any) {
      const errMsg = error?.response?.data?.error || 'Submission failed. Please try again.';
      toast.error(errMsg);
    } finally {
      setSubmitting(false);
    }
  };

  // ── Render field grouping ──────────────────────────────────────────────

  const gridFields = useMemo(
    () => inputFields.filter((f) => f.type !== 'textarea' && f.type !== 'file'),
    [inputFields]
  );
  const textareaFields = useMemo(() => inputFields.filter((f) => f.type === 'textarea'), [inputFields]);
  const fileField = useMemo(() => inputFields.find((f) => f.type === 'file') ?? null, [inputFields]);

  return (
    <div className="flex flex-col h-full bg-muted/30 min-h-full">
      <PageHeader icon={FileText} title="Service PO / Agreement" description="Fixed Recurring, Unfixed Recurring, or Vendor Driven" />

      <div className="container mx-auto py-6 px-4">
        <Card className="shadow-md">
          <CardContent className="pt-6">
            <form onSubmit={handleSubmit} className="space-y-6">

              {/* ── Type selector ──────────────────────────────────── */}
              <FormSection icon={Building2} title="Service PO Type">
                <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
                  {AGREEMENT_TYPES.map(({ value, label, description, Icon }) => (
                    <button
                      key={value}
                      type="button"
                      onClick={() => setAgreementType(value)}
                      className={cn(
                        'flex flex-col items-start gap-1.5 p-4 rounded-xl border text-left transition-colors',
                        agreementType === value
                          ? 'bg-primary text-primary-foreground border-primary'
                          : 'bg-background border-border hover:border-primary/50'
                      )}
                    >
                      <div className="flex items-center gap-2">
                        <Icon className="h-4 w-4" />
                        <span className="font-semibold text-sm">{label}</span>
                      </div>
                      <span className={cn('text-xs', agreementType === value ? 'text-primary-foreground/80' : 'text-muted-foreground')}>
                        {description}
                      </span>
                    </button>
                  ))}
                </div>
              </FormSection>

              {/* ── Dynamic fields ──────────────────────────────────── */}
              <FormSection icon={isVendorDriven ? Truck : CalendarClock} title={isVendorDriven ? "Log Today's Entry" : 'Details'}>
                <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-x-4 gap-y-5">
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
                        placeholder={field.placeholder ?? (field.type === 'select' || field.type === 'search-select' ? `Select ${field.label.toLowerCase()}` : undefined)}
                        className="h-10"
                      />
                      {field.field === 'vendor_sno' && !!formData.service_sno && approvedSuppliers.length === 0 && (
                        <p className="text-xs text-amber-600 mt-1">
                          No suppliers are mapped to this service yet — add one via Masters → Service Supplier Mapping.
                        </p>
                      )}
                    </div>
                  ))}
                </div>

                {textareaFields.map((field) => (
                  <div key={field.field} data-error={!!errors[field.field]}>
                    <CustomInputField
                      field={field.field}
                      label={field.label}
                      require={field.require}
                      type={field.type}
                      value={formData[field.field] ?? ''}
                      onChange={(value) => handleFieldChange(field.field, value)}
                      error={errors[field.field]}
                      placeholder={`Enter ${field.label.toLowerCase()}...`}
                      rows={2}
                      className="resize-none"
                    />
                  </div>
                ))}

                {fileField && (
                  <div data-error={!!errors[fileField.field]} className="max-w-xs">
                    <CustomInputField
                      field={fileField.field}
                      label={fileField.label}
                      require={fileField.require}
                      type={fileField.type}
                      value={formData[fileField.field] ?? null}
                      onChange={(file) => handleFieldChange(fileField.field, file)}
                      error={errors[fileField.field]}
                    />
                  </div>
                )}

                {isVendorDriven && selectedVendorDrivenProduct && (
                  <div className="rounded-md border p-3 bg-muted/30 grid grid-cols-2 sm:grid-cols-4 gap-3">
                    <div>
                      <p className="text-xs text-muted-foreground">Product</p>
                      <p className="text-sm font-medium">{selectedVendorDrivenProduct.product_name}</p>
                    </div>
                    {selectedVendorDrivenProduct.product_description && (
                      <div>
                        <p className="text-xs text-muted-foreground">Description</p>
                        <p className="text-sm font-medium">{selectedVendorDrivenProduct.product_description}</p>
                      </div>
                    )}
                    {selectedVendorDrivenProduct.product_hsn_code && (
                      <div>
                        <p className="text-xs text-muted-foreground">HSN Code</p>
                        <p className="text-sm font-medium">{selectedVendorDrivenProduct.product_hsn_code}</p>
                      </div>
                    )}
                    {selectedVendorDrivenProduct.product_uom_name && (
                      <div>
                        <p className="text-xs text-muted-foreground">Product UOM</p>
                        <p className="text-sm font-medium">{selectedVendorDrivenProduct.product_uom_name}</p>
                      </div>
                    )}
                  </div>
                )}

                {!isVendorDriven && (agreementType === 'FIXED_RECURRING' || agreementType === 'VARIABLE_RECURRING') && (
                  <div className="rounded-md border border-blue-200 bg-blue-50 dark:bg-blue-950/20 dark:border-blue-800 px-3 py-2 text-xs text-blue-800 dark:text-blue-300 flex items-start gap-2">
                    <Bell className="h-3.5 w-3.5 mt-0.5 flex-shrink-0" />
                    <span>
                      {agreementType === 'FIXED_RECURRING'
                        ? '"PO Generation Day" is required for monthly/quarterly/annual cadences (e.g. 5 = generate on the 5th of every eligible month). '
                        : ''}
                      "Notify Before" sends an in-app reminder that many days before {agreementType === 'FIXED_RECURRING' ? 'each auto-generation' : 'each expected billing cycle, as a reminder to submit a Service Bill Request'}.
                    </span>
                  </div>
                )}

                {isVendorDriven && (
                  <div className="rounded-md border border-blue-200 bg-blue-50 dark:bg-blue-950/20 dark:border-blue-800 px-3 py-2 text-xs text-blue-800 dark:text-blue-300 flex items-start gap-2">
                    <ClipboardCheck className="h-3.5 w-3.5 mt-0.5 flex-shrink-0" />
                    <span>
                      Log one entry per delivery day (e.g. milk quantity/price). Entries accumulate below, unbilled.
                      When ready, go to <strong>Vendor Entry Consolidation</strong> in the sidebar, select the entries to bill, and raise the PO.
                    </span>
                  </div>
                )}

                {Object.keys(errors).length > 0 && (
                  <div className="bg-destructive/10 border border-destructive/20 rounded-md p-3">
                    <ul className="list-disc list-inside text-destructive text-xs space-y-0.5">
                      {Object.values(errors).map((err, i) => <li key={i}>{err}</li>)}
                    </ul>
                  </div>
                )}
              </FormSection>

              {/* ── Vendor Driven: recent entries for this vendor+service ── */}
              {isVendorDriven && (
                <section className="space-y-3">
                  <h3 className="text-sm font-semibold text-foreground flex items-center gap-2">
                    Recent Entries{recentEntries.length > 0 && <Badge variant="secondary">{recentEntries.length}</Badge>}
                  </h3>
                  {recentEntries.length > 0 ? (
                    <div className="border rounded-xl overflow-hidden">
                      <Table>
                        <TableHeader>
                          <TableRow className="bg-muted/50 hover:bg-muted/50">
                            <TableHead className="text-xs">Date</TableHead>
                            <TableHead className="text-xs">Qty</TableHead>
                            <TableHead className="text-xs">Unit</TableHead>
                            <TableHead className="text-xs">Unit Price</TableHead>
                            <TableHead className="text-xs">Total</TableHead>
                            <TableHead className="text-xs">Status</TableHead>
                          </TableRow>
                        </TableHeader>
                        <TableBody>
                          {recentEntries.map((entry) => (
                            <TableRow key={entry.entry_sno}>
                              <TableCell className="text-xs">{String(entry.entry_date).slice(0, 10)}</TableCell>
                              <TableCell className="text-xs">{entry.qty}</TableCell>
                              <TableCell className="text-xs">{entry.unit_name ?? '—'}</TableCell>
                              <TableCell className="text-xs">{entry.unit_price}</TableCell>
                              <TableCell className="text-xs font-medium">{entry.total_amount}</TableCell>
                              <TableCell className="text-xs">
                                <Badge
                                  variant={
                                    entry.status === 'REJECTED' ? 'destructive'
                                      : entry.status === 'PENDING_APPROVAL' ? 'outline'
                                      : 'secondary'
                                  }
                                  className="whitespace-nowrap"
                                >
                                  {entry.status === 'PENDING_APPROVAL' ? 'Awaiting Approval'
                                    : entry.status === 'PENDING' ? 'Approved'
                                    : entry.status}
                                </Badge>
                              </TableCell>
                            </TableRow>
                          ))}
                        </TableBody>
                      </Table>
                    </div>
                  ) : (
                    <div className="text-center py-8 text-muted-foreground border rounded-xl bg-muted/10">
                      <Package className="h-8 w-8 mx-auto mb-2 opacity-20" />
                      <p className="text-sm">{loadingEntries ? 'Loading…' : 'No entries yet for this vendor + service.'}</p>
                    </div>
                  )}
                </section>
              )}

              {/* ── Actions ───────────────────────────────────────────── */}
              <div className="flex items-center justify-between gap-3 pt-4 border-t flex-wrap">
                <Button type="button" variant="outline" onClick={handleReset} disabled={submitting} className="h-9">
                  <RefreshCw className="h-4 w-4 mr-2" />Reset
                </Button>

                {canSubmit && (
                  <Button
                    type="submit"
                    className="bg-blue-600 hover:bg-blue-700 h-9"
                    disabled={submitting}
                  >
                    {submitting ? <RefreshCw className="h-4 w-4 mr-2 animate-spin" /> : <Send className="h-4 w-4 mr-2" />}
                    {isVendorDriven ? 'Log Entry' : 'Submit for Approval'}
                  </Button>
                )}
              </div>
            </form>
          </CardContent>
        </Card>
      </div>
    </div>
  );
};

export default ServiceAgreementPage;
